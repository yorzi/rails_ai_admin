# frozen_string_literal: true

require "fileutils"
FileUtils.mkdir_p(File.expand_path("../../tmp", __dir__))
ActiveRecord::Base.establish_connection(ENV.fetch("RAA_TEST_DATABASE_URL") { { adapter: "sqlite3", database: File.expand_path("../../tmp/test.sqlite3", __dir__), pool: 10, timeout: 1000 } })

class Customer < ActiveRecord::Base
  validates :name, presence: true
end

class TestPolicy < RailsAiAdmin::Authorization::Adapter
  class_attribute :denied, default: false
  class_attribute :hide_name, default: false
  class_attribute :deny_show, default: false
  class_attribute :limit_create, default: false
  class_attribute :limited_scope, default: false
  class_attribute :new_only_create, default: false

  def scope(context:, resource:, relation:)
    scoped = denied ? relation.none : relation.where(account_id: context.tenant.id)
    limited_scope ? scoped.limit(1) : scoped
  end

  def allowed?(context:, action:, resource:, record: nil)
    return false if action.to_sym == :create && new_only_create && record && !record.new_record?
    return false if action == :show && deny_show
    return false if action.to_sym == :create && limit_create && record && record.points.to_i > 10
    !denied && (context.actor.id == 1 || %i[index show].include?(action))
  end

  def fields(context:, resource:, action:, record: nil)
    return [] if denied
    return %i[id name points active] - (hide_name ? [ :name ] : []) if action == :read
    return %i[name points active] if action == :write && context.actor.id == 1
    return [ :name ] if %i[search sort].include?(action) && !hide_name
    []
  end
end

class UuidCustomer < ActiveRecord::Base
  validates :name, presence: true
  before_create { self.id ||= SecureRandom.uuid }
end

class UuidCustomerAdmin < RailsAiAdmin::Resource
  model "UuidCustomer"
  key :uuid_customers
  title :name
  fields do
    id :id
    text :name, nullable: false, required: true
    integer :points
  end
end

RailsAiAdmin.configure do |config|
  config.authorization_adapter = "TestPolicy"
  config.resources = [ "TestResource", "UuidCustomerAdmin" ]
end
RailsAiAdmin.prepare!

# Framework models are loaded by the Engine in real hosts.
Dir[File.expand_path("../../app/models/rails_ai_admin/*.rb", __dir__)].sort.each { |path| require path }

module DatabaseHelpers
  def reset_database
    ActiveRecord::Migration.verbose = false
    unless Customer.table_exists?
      ActiveRecord::Schema.define do
        create_table :customers do |t|
          t.integer :account_id, null: false
          t.string :name, null: false
          t.string :secret
          t.integer :points, default: 0
          t.boolean :active, default: true
          t.integer :lock_version, null: false, default: 0
          t.timestamps
        end
      end
    end
    unless UuidCustomer.table_exists?
      uuid_type = ActiveRecord::Base.connection.adapter_name == "PostgreSQL" ? :uuid : :string
      ActiveRecord::Schema.define do
        create_table :uuid_customers, id: uuid_type do |t|
          t.integer :account_id, null: false
          t.string :name, null: false
          t.integer :points, default: 0
          t.integer :lock_version, null: false, default: 0
          t.timestamps
        end
      end
    end
    UuidCustomer.delete_all
    ActiveRecord::MigrationContext.new(File.expand_path("../../db/migrate", __dir__)).migrate
    RailsAiAdmin::BatchItem.delete_all
    Customer.delete_all
    RailsAiAdmin::WorkItem.delete_all
    RailsAiAdmin::OperationRun.delete_all
    RailsAiAdmin::SelectionItem.delete_all
    RailsAiAdmin::Selection.delete_all
    RailsAiAdmin::AuditEvent.delete_all
    TestPolicy.denied = false
    TestPolicy.hide_name = false
    TestPolicy.deny_show = false
    TestPolicy.limit_create = false
    TestPolicy.limited_scope = false
    TestPolicy.new_only_create = false
    @customer = Customer.create!(account_id: 1, name: "Alice", secret: "never show")
    @other = Customer.create!(account_id: 2, name: "Other tenant")
  end
end
