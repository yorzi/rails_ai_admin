# frozen_string_literal: true

require "support/database"

# Everyday admin features on a model with timestamps and no lock_version.
# Registered only inside with_essential_resources.
class Article < ActiveRecord::Base
  validates :title, presence: true
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
      datetime :updated_at, readonly: true
    end
  end

  class Policy < RailsAiAdmin::Authorization::Adapter
    class_attribute :read, default: %i[id title views updated_at]
    class_attribute :write, default: %i[title views]

    def self.reset!
      self.read = %i[id title views updated_at]
      self.write = %i[title views]
    end

    def scope(context:, resource:, relation:) = relation.where(account_id: context.tenant.id)

    def allowed?(context:, action:, resource:, record: nil)
      context.actor.id == 1 || %i[index show].include?(action)
    end

    def fields(context:, resource:, action:, record: nil)
      case action
      when :read then read
      when :write then context.actor.id == 1 ? write : []
      when :search, :sort then %i[title]
      when :filter then %i[views]
      else []
      end
    end
  end

  RESOURCES = %w[EssentialFixtures::ArticleAdmin].freeze

  def self.prepare_schema
    return if Article.table_exists?
    ActiveRecord::Schema.define do
      create_table :articles do |t|
        t.integer :account_id, null: false
        t.string :title, null: false
        t.integer :views, default: 0
        t.timestamps
      end
    end
  end

  def with_essential_resources(resources: RESOURCES, policy: "EssentialFixtures::Policy")
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = policy
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
