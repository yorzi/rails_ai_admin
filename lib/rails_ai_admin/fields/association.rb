# frozen_string_literal: true

module RailsAiAdmin
  module Fields
    # Resolves belongs_to references only through the target resource's current
    # policy relation, record show grant and title. A target that is missing, in
    # another tenant or not shown to this actor is indistinguishable: pages show
    # only the already-readable key, and writes reject it with one message.
    #
    # One instance is a request-local cache. It never survives authentication.
    class Association
      MAX_CHOICES = 100
      MAX_BATCH = 500
      UNAVAILABLE = "is not an available choice"
      INTEGER_KEY = /\A[1-9]\d{0,18}\z/
      # visible is true only for a target in the current relation with a show grant.
      Reference = Data.define(:id, :label, :resource_key, :visible)
      # complete is false when the picker would exceed MAX_CHOICES or the actor
      # cannot list the target resource; forms then accept a typed key instead.
      Choices = Data.define(:options, :complete)

      class << self
        def target(field, registry: RailsAiAdmin.registry)
          raise ConfigurationError, "Expected a belongs_to field" unless field.is_a?(Field) && field.scalar_type == :belongs_to
          key = field.options.fetch(:resource).to_s
          registry.resources.find { |resource| resource.key.to_s == key } ||
            raise(ConfigurationError, "belongs_to #{field.name} names an unregistered resource")
        end

        # The declaration must match a non-polymorphic model belongs_to whose
        # foreign key is the declared column and whose primary key is the target
        # resource's single primary key. Nothing here queries domain rows.
        def validate!(resource, field, registry: RailsAiAdmin.registry)
          target = target(field, registry: registry)
          target_model = target.model_class
          reflection = resource.model_class.reflect_on_association(field.name)
          valid = reflection && reflection.macro == :belongs_to && !reflection.polymorphic? &&
            reflection.foreign_key.to_s == field.column && target_model.primary_key.is_a?(String) &&
            reflection.klass == target_model && reflection.association_primary_key.to_s == target_model.primary_key
          unless valid
            raise ConfigurationError, "belongs_to #{field.name} must match a non-polymorphic model association on #{field.column} to the #{target.key} primary key"
          end
          target
        rescue NameError, ArgumentError
          raise ConfigurationError, "belongs_to #{field.name} could not resolve its model association", cause: nil
        end
      end

      # resource: the declaring resource. Its own fields are checked against the
      # model reflection; operation input fields only need a registered target.
      def initialize(context, resource = nil)
        raise AccessDenied, "UNAUTHENTICATED" unless context.is_a?(Context)
        @context, @resource = context, resource
        @accesses = {}
        @references = Hash.new { |hash, key| hash[key] = {} }
      end

      # Loads every unresolved key for field with one bounded target query, so
      # an index page costs one query per association column, not per row.
      def prime(field, ids)
        cache = @references[cache_key(field)]
        pending = ids.compact.map(&:to_s).uniq.reject { |id| cache.key?(id) }
        return self if pending.empty?
        raise ConfigurationError, "Too many references to resolve at once" if pending.size > MAX_BATCH
        access = target_access(field)
        model = access.resource.model_class
        keys = pending.select { |id| key_shape?(model, id) }
        found = keys.empty? ? {} : access.relation.where(model.primary_key => keys).to_a.index_by { |record| record.id.to_s }
        pending.each { |id| cache[id] = build(field, access, found[id], id) }
        self
      end

      def reference(field, id)
        return if id.nil?
        prime(field, [ id ])
        @references[cache_key(field)].fetch(id.to_s)
      end

      def admissible?(field, id) = reference(field, id)&.visible == true

      # Current picker options as [label, key] pairs. Order follows the target
      # title only while that title is a granted sort field, then the key.
      def choices(field)
        access = target_access(field)
        begin
          access.authorize!(:index)
        rescue AccessDenied
          return Choices.new([].freeze, false)
        end
        model = access.resource.model_class
        table = model.arel_table
        title = access.fields(:sort).find { |candidate| candidate.name == access.resource.title }
        relation = access.relation.reorder(nil)
        relation = relation.order(table[title.column].asc) if title
        records = relation.order(table[model.primary_key].asc).limit(MAX_CHOICES + 1).to_a
        cache = @references[cache_key(field)]
        options = records.first(MAX_CHOICES).filter_map do |record|
          reference = cache[record.id.to_s] ||= build(field, access, record, record.id.to_s)
          [ reference.label, reference.id ] if reference.visible
        end
        Choices.new(options.freeze, records.size <= MAX_CHOICES)
      end

      private

      def cache_key(field) = field.options.fetch(:resource).to_s

      def target_access(field)
        @accesses[cache_key(field)] ||= begin
          own = @resource&.fields&.any? { |candidate| candidate.equal?(field) }
          target = own ? self.class.validate!(@resource, field) : self.class.target(field)
          Authorization::Access.new(@context, target)
        end
      end

      # Integer keys are checked before the query so malformed text never reaches
      # an integer comparison; other key types rely on the column's own cast.
      def key_shape?(model, id)
        return false unless id.match?(Field::REFERENCE)
        column = model.columns_hash[model.primary_key]
        column&.type == :integer ? id.match?(INTEGER_KEY) && Integer(id, 10) <= 2**63 - 1 : true
      end

      def build(field, access, record, id)
        if record
          access.authorize!(:show, record)
          return Reference.new(id.dup.freeze, access.record_label(record).freeze, access.resource.key, true)
        end
        unavailable(field, id)
      rescue AccessDenied
        unavailable(field, id)
      end

      def unavailable(field, id)
        Reference.new(id.dup.freeze, "#{self.class.target(field).label.singularize} ##{id}".freeze, nil, false)
      end
    end
  end
end
