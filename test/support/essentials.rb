# frozen_string_literal: true

require "support/database"
require "bcrypt"
require "minitest/mock"

# Everyday admin features on a model with timestamps and no lock_version.
# Registered only inside with_essential_resources.
class Article < ActiveRecord::Base
  has_secure_password :password, validations: false
  validates :title, presence: true
  validates :password, length: { minimum: 8 }, allow_nil: true
  before_destroy do
    next unless title == "Locked"
    errors.add(:base, "Locked articles are kept")
    throw :abort
  end
end

module EssentialFixtures
  class ArticleAdmin < RailsAiAdmin::Resource
    model "Article"
    key :articles
    title :title
    fields do
      id :id
      text :title, required: true, nullable: false, searchable: :contains, sortable: true
      integer :views, filterable: true
      email :contact, searchable: true
      url :website
      time :opens_at, sortable: true
      json :settings
      password :password
      datetime :updated_at, readonly: true
    end
  end

  class ReadonlyArticleAdmin < RailsAiAdmin::Resource
    model "Article"
    key :articles
    title :title
    readonly
    fields do
      id :id
      text :title
    end
  end

  class Policy < RailsAiAdmin::Authorization::Adapter
    READ = %i[id title views contact website opens_at settings password updated_at].freeze
    WRITE = %i[title views contact website opens_at settings password].freeze
    class_attribute :read, default: READ
    class_attribute :write, default: WRITE
    class_attribute :history, default: true
    class_attribute :export, default: true
    class_attribute :select, default: true
    class_attribute :undeletable, default: []

    def self.reset!
      self.read = READ
      self.write = WRITE
      self.history = true
      self.export = true
      self.select = true
      self.undeletable = []
    end

    def select_records?(context:, resource:) = select

    def view_history?(context:, resource:, record:) = history
    def export_records?(context:, resource:) = export

    def scope(context:, resource:, relation:) = relation.where(account_id: context.tenant.id)

    def allowed?(context:, action:, resource:, record: nil)
      return false if action == :destroy && record && undeletable.include?(record.title)
      context.actor.id == 1 || %i[index show].include?(action)
    end

    def fields(context:, resource:, action:, record: nil)
      case action
      when :read then read
      when :write then context.actor.id == 1 ? write : []
      when :search then %i[title contact]
      when :sort then %i[title opens_at]
      when :filter then %i[views]
      else []
      end
    end
  end

  RESOURCES = %w[EssentialFixtures::ArticleAdmin].freeze

  COLUMNS = %w[contact website opens_at settings password_digest].freeze

  def self.prepare_schema
    connection = ActiveRecord::Base.connection
    if Article.table_exists?
      return if (COLUMNS - Article.column_names).empty?
      connection.drop_table(:articles)
    end
    ActiveRecord::Schema.define do
      create_table :articles do |t|
        t.integer :account_id, null: false
        t.string :title, null: false
        t.integer :views, default: 0
        t.string :contact
        t.string :website
        t.time :opens_at
        t.json :settings
        t.string :password_digest
        t.timestamps
      end
    end
    Article.reset_column_information
  end

  def with_essential_resources(resources: RESOURCES, policy: "EssentialFixtures::Policy", **settings)
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = policy
    settings.each { |name, value| config.public_send("#{name}=", value) }
    registry = RailsAiAdmin::Registry.new(resources)
    operations = RailsAiAdmin::Operations::Registry.new(registry.resources)
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, operations) { yield registry }
      end
    end
  end

  def reset_essentials
    Policy.reset!
    Article.delete_all
    @article = Article.create!(account_id: 1, title: "First", views: 1)
  end
end

EssentialFixtures.prepare_schema
