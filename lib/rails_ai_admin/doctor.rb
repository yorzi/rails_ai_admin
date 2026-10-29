# frozen_string_literal: true

require "rails_ai_admin/schema_suggestions"

module RailsAiAdmin
  # Reports support boundaries without probing credentials or calling providers.
  class Doctor
    Check = Data.define(:name, :status, :message)

    def initialize(configuration: RailsAiAdmin.configuration, registry: RailsAiAdmin.registry, application: Rails.application,
      operation_registry: RailsAiAdmin.operation_registry, work_registry: RailsAiAdmin.work_registry)
      @configuration, @registry, @application = configuration, registry, application
      @operation_registry, @work_registry = operation_registry, work_registry
    end

    def checks
      config = @configuration
      result = [
        adapter_check("context", config.context_adapter, { resolve: [ 1, [] ] }),
        adapter_check("policy", config.authorization_adapter, { scope: [ 0, %i[context resource relation] ], allowed?: [ 0, %i[context action resource record] ], fields: [ 0, %i[context resource action record] ] }),
        autoload_check,
        Check.new("assistant", :unsupported, "Assistant routes/tables are not installed; no provider call is made."),
        Check.new("files", :unsupported, "Private attachment management is not implemented."),
        Check.new("queue", @work_registry.definitions.empty? ? :closed : :review,
          "Durable post-commit outbox; #{ @work_registry.definitions.size } work handlers; auto_dispatch=#{config.outbox_auto_dispatch}. Schedule pending scans and verify downstream idempotency. Async business execution is not implemented."),
        Check.new("coexistence", :review, "No rails_tool_views global configuration is changed; shared Surface integration is unresolved.")
      ]
      if @work_registry.definitions.any?
        result << adapter_check("job_context", config.context_adapter, { resolve_job: [ 0, %i[actor_ref tenant_ref security_version] ] })
        result << Check.new("work_delivery_policy", :review, "Delivery and receipt grants are independent of command preconditions; default denies. Verify fresh tenant/epoch, record-version policy and one effect per item in host tests.")
      end
      @registry.resources.each do |resource|
        begin
          if config.authorization_adapter == "RailsAiAdmin::Authorization::PunditAdapter"
            configured = Authorization::PunditAdapter.new.configured?(resource)
            policy_status = resource.policy.nil? ? :closed : (configured ? :review : :error)
            result << Check.new("policy:#{resource.key}", policy_status,
              "Explicit Pundit policy and policy-owned Scope required; field grants are independent. Mapping complete=#{configured}; authorization still needs host tests.")
          end
          model = resource.model_class
          same_pool = model.connection_pool.equal?(OperationRun.connection_pool) && model.connection_pool.equal?(AuditEvent.connection_pool) && model.connection_pool.equal?(WorkItem.connection_pool)
          locking = model.locking_enabled? && model.locking_column == "lock_version"
          writable = !resource.readonly?
          status = writable && (!same_pool || !locking || model.composite_primary_key?) ? :error : :ok
          status = :error if writable && !%w[SQLite PostgreSQL].include?(model.connection.adapter_name)
          message = "same_pool=#{same_pool}; lock_version=#{locking}; readonly=#{resource.readonly?}. Host callbacks must be database-only."
          result << Check.new("resource:#{resource.key}", status, message)
          result.concat(schema_checks(resource, model))
          @operation_registry.custom(resource).each do |definition|
            models = definition.handler_class.atomic_models.map(&:constantize)
            valid = models.all? { |related| related.is_a?(Class) && related < ActiveRecord::Base && related.connection_pool.equal?(model.connection_pool) }
            result << Check.new("operation:#{resource.key}:#{definition.key}", valid ? :review : :error,
              "Declared atomic models share pool=#{valid}; handler/input metadata validated. Trusted Ruby is not a sandbox: test callbacks, preflight purity and external-effect boundaries. Duration checks are cooperative, not a hard SQL/Ruby interrupt.")
          end
        rescue ActiveRecord::ActiveRecordError, NameError, ConfigurationError => error
          result << Check.new("resource:#{resource.key}", :error, "Inspect model/migrations (#{error.class.name}); no record content was printed.")
        end
      end
      result
    end

    private

    def adapter_check(kind, name, methods)
      if name.nil? || name == "RailsAiAdmin::Authorization::Adapter"
        return Check.new(kind, :closed, "Default denies access. Implement and test the host context, scopes, actions and independent field grants.")
      end
      klass = name.safe_constantize
      complete = klass.is_a?(Class) && (methods.keys - klass.public_instance_methods).empty? &&
        klass.respond_to?(:new) && accepts_arguments?(klass.method(:new), 0, []) &&
        accepts_arguments?(klass.instance_method(:initialize), 0, []) &&
        methods.all? { |method, (positional, keywords)| accepts_arguments?(klass.instance_method(method), positional, keywords) }
      Check.new(kind, complete ? :review : :error,
        "Adapter public interface complete=#{complete}. Metadata does not prove anonymous denial or authorization; run host TestKit and HTTP tests.")
    rescue NameError, LoadError
      Check.new(kind, :error, "Adapter could not be loaded. Inspect its constant name and autoload path; no exception content was printed.")
    end

    def accepts_arguments?(method, positional, keywords)
      parameters = method.parameters
      keyword_parameters = parameters.any? { |kind, _| %i[key keyreq keyrest].include?(kind) }
      return false if keywords.any? && parameters.any? { |kind, _| kind == :nokey }
      positional += 1 if keywords.any? && !keyword_parameters
      required = parameters.count { |kind, _| kind == :req }
      maximum = parameters.any? { |kind, _| kind == :rest } ? Float::INFINITY : required + parameters.count { |kind, _| kind == :opt }
      return false unless (required..maximum).cover?(positional)
      return false unless (parameters.filter_map { |kind, name| name if kind == :keyreq } - keywords).empty?
      parameters.any? { |kind, _| kind == :keyrest } || !keyword_parameters ||
        (keywords - parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }).empty?
    end

    def autoload_check
      unless @application
        return Check.new("autoload", :review, "Run doctor inside the host Rails application to check app/rails_ai_admin loading.")
      end
      path = @application.root.join("app/rails_ai_admin").to_s
      registered = @application.autoloaders.main.dirs.include?(path)
      conventional = "rails_ai_admin".camelize == "RailsAiAdmin"
      Check.new("autoload", conventional ? :review : :error,
        "Default app/rails_ai_admin is an autoload root=#{registered}; RailsAiAdmin inflection preserved=#{conventional}. If the directory exists but is ignored, restore loading or verify explicit host loading. Custom host_paths configuration is not implemented.")
    end

    def schema_checks(resource, model)
      columns = model.columns_hash
      invalid = resource.fields.reject do |field|
        column = columns[field.name.to_s]
        column && (SchemaSuggestions::TYPES.key?(column.type) || column.type == :uuid) && !SchemaSuggestions.array?(column) ||
          (field.type == :id && field.name == :id && model.primary_key.is_a?(String) && columns.key?(model.primary_key))
      end
      result = [ Check.new("schema:#{resource.key}", invalid.empty? ? :ok : :error,
        "#{invalid.size} declared fields lack supported scalar columns. Check field names/types; virtual fields are not implemented. No records were sampled.") ]
      mismatches = resource.fields.count do |field|
        column = columns[field.name.to_s]
        next false unless column
        case field.type
        when :datetime then !%i[datetime timestamp].include?(column.type)
        when :date then column.type != :date
        when :boolean then column.type != :boolean
        when :integer then column.type != :integer || model.defined_enums.key?(field.name.to_s)
        when :decimal then column.type != :decimal
        else false
        end
      end
      result << Check.new("field_types:#{resource.key}", mismatches.zero? ? :ok : :review,
        "#{mismatches} declarations need scalar type compatibility review. Validate coercion and presentation with host data; metadata alone cannot prove them.")
      sensitive = resource.fields.count { |field| SchemaSuggestions.sensitive?(model, field.name) }
      result << Check.new("sensitivity:#{resource.key}", sensitive.zero? ? :ok : :review,
        "#{sensitive} declarations match sensitive names/encrypted attributes. Review explicit grants; naming heuristics cannot establish safety. Assistant/export are not implemented.")
      indexes = model.connection.indexes(model.table_name)
      missing = resource.fields.count do |field|
        field.options[:sortable] && field.name.to_s != model.primary_key && !indexes.any? { |index| index.columns.is_a?(Array) && index.columns.first == field.name.to_s }
      end
      result << Check.new("sort_indexes:#{resource.key}", missing.zero? ? :ok : :review,
        "#{missing} sortable declarations lack a leading-column index. Review query plans and tenant-composite indexes; this hint is not a performance verdict.")
      result
    end
  end
end
