# frozen_string_literal: true

# Registered only inside with_association_resources; the global test registry
# keeps its existing resources.
module AssociationFixtures
  class CustomerAdmin < RailsAiAdmin::Resource
    model "Customer"
    key :customers
    title :name
    fields do
      id :id
      text :name, sortable: true, searchable: :contains
    end
    has_many :invoices, limit: 2
  end

  class InvoiceAdmin < RailsAiAdmin::Resource
    model "Invoice"
    key :invoices
    title :number
    fields do
      id :id
      text :number, required: true, nullable: false
      belongs_to :customer, filterable: true
    end
  end

  # Invoices that sort and search by their customer's name.
  class ReferenceQueryInvoiceAdmin < RailsAiAdmin::Resource
    model "Invoice"
    key :invoices
    title :number
    fields do
      id :id
      text :number, required: true, nullable: false, sortable: true, searchable: :exact
      belongs_to :customer, sortable: true, searchable: :contains, filterable: true
    end
  end

  class Policy < RailsAiAdmin::Authorization::Adapter
    class_attribute :hidden_customers, default: []
    class_attribute :join_customer_invoices, default: false
    class_attribute :deny_customer_show, default: false
    class_attribute :deny_customer_index, default: false
    class_attribute :customer_sort, default: %i[name]
    class_attribute :customer_search, default: %i[name]
    class_attribute :invoice_read, default: %i[id number customer]
    class_attribute :invoice_filters, default: %i[customer]
    class_attribute :invoice_sort, default: []
    class_attribute :invoice_search, default: []

    def self.reset!
      self.hidden_customers = []
      self.join_customer_invoices = false
      self.deny_customer_show = false
      self.deny_customer_index = false
      self.customer_sort = %i[name]
      self.customer_search = %i[name]
      self.invoice_read = %i[id number customer]
      self.invoice_filters = %i[customer]
      self.invoice_sort = []
      self.invoice_search = []
    end

    def scope(context:, resource:, relation:)
      scoped = relation.where(account_id: context.tenant.id)
      return scoped unless resource.key == :customers

      scoped = scoped.joins("INNER JOIN invoices ON invoices.customer_id = customers.id") if join_customer_invoices
      hidden_customers.any? ? scoped.where.not(name: hidden_customers) : scoped
    end

    def allowed?(context:, action:, resource:, record: nil)
      if resource.key == :customers
        return false if action == :show && deny_customer_show
        return false if action == :index && deny_customer_index
      end
      context.actor.id == 1 || %i[index show].include?(action)
    end

    def fields(context:, resource:, action:, record: nil)
      if resource.key == :customers
        return %i[id name] if action == :read
        return customer_sort if action == :sort
        return customer_search if action == :search
        return []
      end
      case action
      when :read then invoice_read
      when :write then context.actor.id == 1 ? %i[number customer] : []
      when :filter then invoice_filters
      when :sort then invoice_sort
      when :search then invoice_search
      else []
      end
    end
  end

  RESOURCES = %w[AssociationFixtures::CustomerAdmin AssociationFixtures::InvoiceAdmin].freeze

  def with_association_resources(resources = RESOURCES)
    config = RailsAiAdmin.configuration.dup
    config.authorization_adapter = "AssociationFixtures::Policy"
    registry = RailsAiAdmin::Registry.new(resources)
    operations = RailsAiAdmin::Operations::Registry.new(registry.resources)
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, operations) { yield registry }
      end
    end
  end

  def invoice_admin(registry) = registry.fetch(:invoices)
  def customer_field(registry) = invoice_admin(registry).fields.find { |field| field.name == :customer }

  # Counts domain queries, ignoring schema and transaction bookkeeping.
  def count_queries(pattern = /\A\s*SELECT/i)
    count = 0
    listener = ->(*, payload) { count += 1 if payload[:sql].match?(pattern) && payload[:name] != "SCHEMA" }
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") { yield }
    count
  end
end
