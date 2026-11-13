# frozen_string_literal: true

module RailsAiAdmin
  # Describes explicit exposure of a host model. No attributes are auto-published.
  class Resource
    class << self
      def inherited(child)
        super
        child.instance_variable_set(:@fields, {})
        child.instance_variable_set(:@scopes, {})
        child.instance_variable_set(:@index, Presentation::IndexSettings.new)
        child.instance_variable_set(:@disabled_actions, [])
        child.instance_variable_set(:@operations, {})
        child.instance_variable_set(:@operation_scopes, {})
        child.instance_variable_set(:@surface_operations, [])
        child.instance_variable_set(:@assistant_operations, [])
        child.instance_variable_set(:@navigation, Navigation::Settings.new)
        child.instance_variable_set(:@has_many, {})
        child.instance_variable_set(:@dashboard, [])
      end

      def model(name = nil)
        @model_name = name if name
        @model_name
      end

      def key(value = nil)
        @key = value.to_sym if value
        @key
      end

      def label(value = nil)
        @label = value if value
        @label || key.to_s.humanize
      end

      def title(value = nil)
        @title = value.to_sym if value
        @title
      end

      # Names an explicit optional policy for this resource, independent of aliases.
      def policy(name = nil)
        @policy_name = name if name
        @policy_name
      end

      # Cosmetic configuration never grants or revokes direct resource access.
      def navigation(value = :read, **options)
        return @navigation if value == :read && options.empty?
        unless value == :read || value == false && options.empty?
          raise ConfigurationError, "Use navigation options or navigation false"
        end
        @navigation = Navigation::Settings.new(**(value == false ? { hidden: true } : options))
      rescue ArgumentError
        raise ConfigurationError, "Unknown navigation option", cause: nil
      end

      def readonly(value = true)
        @readonly = value
      end

      def readonly? = @readonly == true

      def disable(*actions)
        @disabled_actions.concat(actions.map(&:to_sym))
      end

      def action_enabled?(action)
        action = action.to_sym
        known = %i[index show create update destroy].include?(action) || @operations.key?(action)
        known && !@disabled_actions.include?(action) && !(readonly? && (%i[create update destroy].include?(action) || @operations.key?(action)))
      end

      # surface: true also allows reviewing a native member intent in an
      # admin-owned rails_tool_views Surface; assistant: true further lets an
      # assistant propose (never execute) it through that Surface. Neither adds
      # authority: the current policy and a human confirmation still decide.
      def operation(key, handler:, scope: :member, confirmation: :required, surface: false, assistant: false)
        unless key.to_s.match?(/\A[a-z][a-z0-9_]*\z/) && !%w[index show create update destroy new edit].include?(key.to_s)
          raise ConfigurationError, "Custom operation needs a distinct stable key"
        end
        unless handler.is_a?(String) && handler.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/) && %i[member collection].include?(scope) && confirmation == :required
          raise ConfigurationError, "Use a handler class-name string, member/collection scope and required confirmation"
        end
        raise ConfigurationError, "Duplicate operation #{key}" if @operations.key?(key.to_sym)
        raise ConfigurationError, "Operation surface must be boolean and is only for member operations" unless [ true, false ].include?(surface) && (!surface || scope == :member)
        raise ConfigurationError, "Operation assistant must be boolean and requires surface: true" unless [ true, false ].include?(assistant) && (!assistant || surface)
        @operations[key.to_sym] = handler.freeze
        @operation_scopes[key.to_sym] = scope
        @surface_operations << key.to_sym if surface
        @assistant_operations << key.to_sym if assistant
      end

      # A readonly child list on the show page. The child resource's own policy,
      # index grant and a readable belongs_to field (via) decide what appears;
      # declaring it grants nothing and adds no write path.
      def has_many(name, resource: name, via: nil, label: nil, limit: 10)
        definition = Presentation::AssociationPanel::Definition.build(name, resource: resource, via: via, label: label, limit: limit)
        raise ConfigurationError, "Duplicate has_many #{definition.name}" if @has_many.key?(definition.name)
        raise ConfigurationError, "A resource declares at most #{Presentation::AssociationPanel::MAX_PANELS} has_many panels" if @has_many.size >= Presentation::AssociationPanel::MAX_PANELS
        @has_many[definition.name] = definition
      end

      # A readonly panel for the one child record that points back here (a
      # model has_one). The same grants as has_many apply.
      def has_one(name, resource: name.to_s.pluralize, via: nil, label: nil)
        definition = Presentation::AssociationPanel::Definition.build(name, resource: resource, via: via, label: label, limit: 1, single: true)
        raise ConfigurationError, "Duplicate association panel #{definition.name}" if @has_many.key?(definition.name)
        raise ConfigurationError, "A resource declares at most #{Presentation::AssociationPanel::MAX_PANELS} association panels" if @has_many.size >= Presentation::AssociationPanel::MAX_PANELS
        @has_many[definition.name] = definition
      end

      def has_many_declarations = @has_many.values

      def operation_declarations = @operations
      def surface_operation?(key) = @surface_operations.include?(key.to_sym)
      def assistant_operation?(key) = @assistant_operations.include?(key.to_sym)
      def assistant_operations = @assistant_operations
      def operation_scopes = @operation_scopes

      def fields(&block)
        FieldBuilder.new(@fields, source: self).instance_eval(&block) if block
        @fields.values
      end

      # Overview widgets: metric counts over a list tab and daily trends over
      # a date field. They read through the same grants as the list.
      def dashboard(&block)
        return @dashboard unless block
        builder = Presentation::Dashboard::Builder.new
        begin
          builder.instance_eval(&block)
        rescue NoMethodError => error
          raise ConfigurationError, "Unknown dashboard option #{error.name}", cause: nil
        end
        @dashboard = builder.widgets.freeze
      end

      # Static index table presentation: column order, default sort, page size
      # and count strategy. It is not part of operation or Selection identity.
      def index(&block)
        return @index unless block
        raise ConfigurationError, "Index settings are declared twice" if @index_declared
        builder = Presentation::IndexBuilder.new
        begin
          builder.instance_eval(&block)
        rescue NoMethodError => error
          raise ConfigurationError, "Unknown index option #{error.name}", cause: nil
        end
        @index = Presentation::IndexSettings.new(**builder.options)
        @index_declared = true
        @index
      end

      # Named list tabs narrow the policy relation; they never grant or widen it.
      def scopes(&block)
        ScopeBuilder.new(@scopes).instance_eval(&block) if block
        @scopes.values
      end

      def model_class
        raise ConfigurationError, "model must be a constant name string" unless model.is_a?(String)
        klass = model.constantize
        raise ConfigurationError, "model must inherit ActiveRecord::Base" unless klass < ActiveRecord::Base
        klass
      end

      def validate!
        raise ConfigurationError, "model must be a constant name string" unless model.is_a?(String)
        if policy && (!policy.is_a?(String) || !policy.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/))
          raise ConfigurationError, "policy must be a constant name string"
        end
        raise ConfigurationError, "A resource must declare fields and a title" if fields.empty? || !title || !@fields.key?(title)
        raise ConfigurationError, "A resource cannot declare lock_version as a field" if @fields.key?(:lock_version)
        raise ConfigurationError, "A password field cannot be the title" if @fields[title].scalar_type == :password
        Fields::DependencyGraph.validate!(fields)
        index.validate!(fields)
        Presentation::Dashboard.validate!(self)
        # Fail at registration rather than on every menu render; explicit labels
        # were already bounded when declared.
        Navigation::Settings.caption(label) unless navigation.hidden || navigation.label
        @policy_name&.freeze
        @fields.freeze
        @scopes.freeze
        @disabled_actions.freeze
        @operations.freeze
        @operation_scopes.freeze
        @surface_operations.freeze
        @has_many.freeze
        @assistant_operations.freeze
        self
      end
    end

    # Collects named list scopes. Bodies are not evaluated at declaration time.
    class ScopeBuilder
      def initialize(scopes)
        @scopes = scopes
      end

      def scope(name, body = nil, label: nil, default: false)
        definition = Queries::NamedScope.new(name, body, label: label, default: default)
        raise ConfigurationError, "Duplicate named scope #{definition.name}" if @scopes.key?(definition.name)
        raise ConfigurationError, "A resource declares at most #{Queries::NamedScope::MAX_SCOPES} named scopes" if @scopes.size >= Queries::NamedScope::MAX_SCOPES
        raise ConfigurationError, "A resource declares at most one default named scope" if definition.default? && @scopes.values.any?(&:default?)
        @scopes[definition.name] = definition
      end
    end

    # Collects field declarations without consulting the database at boot.
    class FieldBuilder
      # source is the declaring Resource, consulted lazily for column limits.
      def initialize(fields, source: nil)
        @fields = fields
        @source = source
      end

      def field(name, type:, **options)
        raise ConfigurationError, "Duplicate field #{name}" if @fields.key?(name.to_sym)
        @fields[name.to_sym] = RailsAiAdmin.field_registry.build(name, type: type, source: @source, **options)
      end

      def virtual(name, type:, depends_on:, compute:, **options)
        field(name, type: type, compute: compute, depends_on: depends_on, **options)
      end

      def readonly(name, type: :text, **options)
        field(name, type: type, **options.merge(readonly: true))
      end

      Field::TYPES.each do |type|
        define_method(type) { |name, **options| field(name, type: type, **options) }
      end
    end
  end
end
