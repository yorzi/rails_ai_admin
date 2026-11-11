# frozen_string_literal: true

require "rails_ai_admin/schema_suggestions"
require "rails_ai_admin/templates/inspector"

module RailsAiAdmin
  # Reports support boundaries without probing credentials or calling providers.
  class Doctor
    Check = Data.define(:name, :status, :message)

    def initialize(configuration: RailsAiAdmin.configuration, registry: RailsAiAdmin.registry, application: Rails.application,
      operation_registry: RailsAiAdmin.operation_registry, work_registry: RailsAiAdmin.work_registry)
      @configuration, @registry, @application = configuration, registry, application
      @operation_registry, @work_registry = operation_registry, work_registry
    end

    # Admin Surfaces never change the host-owned rails_tool_views runtime; this
    # reports whether the opt-in can work, not whether it is authorized.
    def surface_check
      surfaces = @configuration.respond_to?(:surfaces) && @configuration.surfaces
      unless surfaces
        return Check.new("surfaces", :closed, "Admin review Surfaces are off. The host owns any rails_tool_views runtime; the admin does not configure it.")
      end
      require "rails_ai_admin/integrations/tool_views"
      return Check.new("surfaces", :error, "surfaces is enabled but rails_tool_views is not loaded.") unless Integrations::ToolViews.available?
      if @configuration.respond_to?(:surfaces_parent_controller_problem) && (problem = @configuration.surfaces_parent_controller_problem)
        return Check.new("surfaces", :error, problem)
      end
      unless ::RailsToolViews::Surface.table_exists? && ::RailsToolViews::ActionExecution.table_exists?
        return Check.new("surfaces", :error, "Run the rails_tool_views installer migrations before enabling admin Surfaces.")
      end
      Integrations::ToolViews.ensure_registered!
      operations = @registry.resources.sum { |resource| resource.operation_declarations.keys.count { |key| resource.surface_operation?(key) } }
      assistant = @configuration.respond_to?(:assistant) && @configuration.assistant
      Check.new("surfaces", :review, "#{Integrations::ToolViews::KEY} is registered for #{operations} member operations through admin-owned endpoints. " \
        "#{assistant ? 'Assistant proposals present it and confirmed outcomes continue their chat once.' : 'Assistant presentation is off.'}")
    rescue ConfigurationError => error
      Check.new("surfaces", :error, error.message)
    end

    # Reports whether opt-in admin Chat can run. It never calls the adapter or
    # a provider, so it cannot prove credentials, model access or grants.
    def assistant_check
      unless @configuration.respond_to?(:assistant) && @configuration.assistant
        return Check.new("assistant", :closed, "Admin Chat is off. No RubyLLM code, tables or provider calls are used.")
      end
      require "rails_ai_admin/assistant"
      missing = [ Assistant::Chat, Assistant::Message, Assistant::Turn, ::RubyLLM::ActiveRecord::ToolCall, ::RubyLLM::ActiveRecord::Usage ]
        .reject(&:table_exists?).map(&:table_name)
      return Check.new("assistant", :error, "Run rails_ai_admin:assistant and db:migrate; missing tables: #{missing.join(', ')}.") if missing.any?
      adapter = @configuration.assistant_adapter.safe_constantize
      unless adapter.is_a?(Class) && adapter.method_defined?(:llm_context) && adapter.instance_method(:llm_context).parameters.include?([ :keyreq, :context ])
        return Check.new("assistant", :error, "#{@configuration.assistant_adapter} must define llm_context(context:) returning a RubyLLM::Context or nil.")
      end
      job = @configuration.context_adapter&.safe_constantize
      unless job.is_a?(Class) && job.method_defined?(:resolve_job)
        return Check.new("assistant", :error, "Assistant turns run in jobs; the context adapter must define resolve_job.")
      end
      Check.new("assistant", :review, "Model #{@configuration.assistant_model}; tools apply each actor's current grants and the independent assistant? grant. " \
        "Schedule rails_ai_admin:assistant:scan, keep provider credentials in the adapter's own RubyLLM::Context, and verify real-provider behavior separately.")
    rescue NameError, ConfigurationError => error
      Check.new("assistant", :error, "Assistant configuration failed (#{error.class.name}).")
    end

    def checks
      config = @configuration
      collections = @registry.resources.sum { |resource| @operation_registry.custom(resource).count { |definition| definition.scope == :collection } }
      result = [
        adapter_check("context", config.context_adapter, { resolve: [ 1, [] ] }),
        adapter_check("policy", config.authorization_adapter, { scope: [ 0, %i[context resource relation] ], allowed?: [ 0, %i[context action resource record] ], fields: [ 0, %i[context resource action record] ] }),
        autoload_check,
        assistant_check,
        Check.new("files", :unsupported, "Private attachment management is not implemented."),
        selection_check,
        Check.new("queue", @work_registry.definitions.empty? && collections.zero? ? :closed : :review,
          "#{@work_registry.definitions.size} outbox handlers; #{collections} collection handlers; auto_dispatch=#{config.outbox_auto_dispatch}/#{config.collection_auto_dispatch}; " \
          "jobs use the #{queue_name(config).inspect} queue. Schedule the pending scans, make sure a worker processes that queue, and verify persistent queues/downstream idempotency."),
        backlog_check,
        surface_check
      ]
      result.concat(override_checks)
      if @work_registry.definitions.any? || collections > 0
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
          message = "same_pool=#{same_pool}; lock_version=#{locking}; readonly=#{resource.readonly?}. Host callbacks must be database-only. " \
            "List pages omit in-scope records that deny show; check scope/show agreement with TestKit.assert_scope_matches_show."
          result << Check.new("resource:#{resource.key}", status, message)
          result.concat(schema_checks(resource, model))
          @operation_registry.custom(resource).each do |definition|
            models = definition.handler_class.atomic_models.map(&:constantize)
            valid = models.all? { |related| related.is_a?(Class) && related < ActiveRecord::Base && related.connection_pool.equal?(model.connection_pool) }
            result << Check.new("operation:#{resource.key}:#{definition.key}", valid ? :review : :error,
              "Scope=#{definition.scope}; declared atomic models share pool=#{valid}; handler/input metadata validated. Trusted Ruby is not a sandbox: test callbacks, preflight purity and external-effect boundaries. Duration checks are cooperative, not a hard SQL/Ruby interrupt. Collection inputs persist once: minimize payloads, never submit credentials, and review retention.")
          end
        rescue ActiveRecord::ActiveRecordError, NameError, ConfigurationError => error
          result << Check.new("resource:#{resource.key}", :error, "Inspect model/migrations (#{error.class.name}); no record content was printed.")
        end
      end
      result
    end

    private

    BACKLOG_AGE = 15.minutes

    def count_of(fields, noun) = "#{fields.size} #{fields.size == 1 ? noun : noun.pluralize}"
    def named(fields) = fields.empty? ? "" : " (#{fields.first(10).map(&:name).join(', ')}#{fields.size > 10 ? ', …' : ''})"

    def queue_name(config) = config.respond_to?(:queue_name) ? config.queue_name.to_s : "rails_ai_admin"

    # Work that has been due for a while means no worker or scan is running it
    # (RAA-020). Counts only; no record content or payload is read.
    def backlog_check(now: Time.current)
      cutoff = now - BACKLOG_AGE
      due = ->(relation, table) { relation.where(table[:next_attempt_at].eq(nil).or(table[:next_attempt_at].lteq(now))).where(table[:created_at].lt(cutoff)) }
      collection = due.call(BatchItem.where(status: "queued"), BatchItem.arel_table).count
      outbox = due.call(WorkItem.where(status: "pending"), WorkItem.arel_table).count
      turns = 0
      if @configuration.respond_to?(:assistant) && @configuration.assistant
        require "rails_ai_admin/assistant"
        turns = due.call(Assistant::Turn.where(status: "queued"), Assistant::Turn.arel_table).count if Assistant::Turn.table_exists?
      end
      total = collection + outbox + turns
      return Check.new("backlog", :ok, "No admin work has waited longer than #{BACKLOG_AGE.inspect}.") if total.zero?
      Check.new("backlog", :review, "#{collection} collection items, #{outbox} outbox items and #{turns} assistant turns have waited longer than #{BACKLOG_AGE.inspect}. " \
        "Check that a worker processes the #{queue_name(@configuration).inspect} queue and that the rails_ai_admin scans are scheduled.")
    rescue ActiveRecord::ActiveRecordError, NameError
      Check.new("backlog", :review, "Cannot inspect queued admin work. Check database connectivity and pending engine migrations.")
    end

    def override_checks
      return [ Check.new("overrides", :review, "Run doctor inside the host to inspect standard app/views override metadata.") ] unless @application
      findings = Templates::Inspector.new(root: @application.root).checks
      return [ Check.new("overrides", :ok, "No standard-path admin template overrides found; custom view paths require host review.") ] if findings.empty?
      findings.map do |finding|
        Check.new("override:#{finding.key.gsub(/[^a-zA-Z0-9_\/.-]/, '_')[0, 200]}", finding.status,
          "#{finding.code}: #{finding.path.inspect}; source version=#{finding.source_version || 'untracked'}. Source/context metadata only; review host edits for authority, CSRF and escaping. Custom view paths are not inspected.")
      end
    rescue ConfigurationError, SystemCallError
      [ Check.new("overrides", :error, "Cannot inspect standard host override paths; no template was evaluated.") ]
    end

    def selection_check
      installed = [ Selection, SelectionItem, BatchItem ].all?(&:table_exists?)
      Check.new("selections", installed ? :review : :error,
        "Fixed selection tables installed=#{installed}; at most 100 targets with lock_version in one pool. Separate select_records? grant, current scope/show/fields and expiry apply. Selection alone is not approval; collection admission/leases require current host policies and persistent queue scans.")
    rescue ActiveRecord::ActiveRecordError
      Check.new("selections", :error, "Cannot inspect selection tables. Check database connectivity and pending engine migrations.")
    end

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
      Fields::DependencyGraph.validate!(resource.fields)
      physical_fields = resource.fields.reject(&:virtual?)
      invalid = physical_fields.reject do |field|
        column = columns[field.column]
        column && (SchemaSuggestions::TYPES.key?(column.type) || column.type == :uuid) && !SchemaSuggestions.array?(column) ||
          (field.scalar_type == :id && field.name == :id && model.primary_key.is_a?(String) && columns.key?(model.primary_key))
      end
      result = [ Check.new("schema:#{resource.key}", invalid.empty? ? :ok : :error,
        "#{invalid.size} declared fields lack supported scalar columns. Check field names/types; computed fields use declared dependency graphs. No records were sampled.") ]
      mismatches = physical_fields.count do |field|
        column = columns[field.column]
        next false unless column
        case field.scalar_type
        when :belongs_to then !%i[integer string uuid].include?(column.type)
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
      # Each line names the declarations it counts (RAA-026); names are schema
      # metadata, never record content.
      sensitive = resource.fields.select { |field| SchemaSuggestions.sensitive?(model, field.name) }
      result << Check.new("sensitivity:#{resource.key}", sensitive.empty? ? :ok : :review,
        "Declarations matching sensitive names or encrypted attributes: #{count_of(sensitive, 'field')}#{named(sensitive)}. Review explicit grants, including the assistant? grant; naming heuristics cannot establish safety.")
      indexes = model.connection.indexes(model.table_name)
      missing = resource.fields.select do |field|
        field.options[:sortable] && field.column != model.primary_key && !indexes.any? { |index| index.columns.is_a?(Array) && index.columns.first == field.column }
      end
      result << Check.new("sort_indexes:#{resource.key}", missing.empty? ? :ok : :review,
        "Sortable declarations without a leading-column index: #{count_of(missing, 'field')}#{named(missing)}. Review query plans and tenant-composite indexes; this hint is not a performance verdict.")
      unindexed_filters = resource.fields.select do |field|
        !field.hidden? && field.filter_operators.any? && field.column != model.primary_key && !indexes.any? { |index| index.columns.is_a?(Array) && index.columns.include?(field.column) }
      end
      result << Check.new("filter_indexes:#{resource.key}", unindexed_filters.empty? ? :ok : :review,
        "Filterable declarations in no index: #{count_of(unindexed_filters, 'field')}#{named(unindexed_filters)}. Review query plans with the tenant scope; low-cardinality filters may not need one.")
      searchable = resource.fields.select { |field| field.options[:searchable] && !field.hidden? && !field.virtual? }
      if searchable.any?
        modes = searchable.map { |field| "#{field.name} (#{field.options[:searchable] == true ? :prefix : field.options[:searchable]})" }.join(", ")
        result << Check.new("search:#{resource.key}", :review,
          "Search uses case-insensitive LIKE on SQLite and ILIKE on PostgreSQL over #{modes}. A plain B-tree index cannot serve ILIKE or contains search; " \
          "on PostgreSQL use a pg_trgm GIN index, or lower(column) text_pattern_ops for prefix search. SQLite folds ASCII case only, so non-ASCII case differs by database.")
      end
      references = resource.fields.select { |field| field.scalar_type == :belongs_to }
      if references.any?
        failures = references.filter_map do |field|
          Fields::Association.validate!(resource, field, registry: @registry)
          nil
        rescue ConfigurationError => error
          error.message
        end
        result << Check.new("associations:#{resource.key}", failures.empty? ? :review : :error,
          failures.empty? ? "#{references.size} belongs_to declarations match model reflections. A changed reference must be visible in its target resource; verify target policies and foreign-key constraints." : failures.join("; "))
      end
      result
    end
  end
end
