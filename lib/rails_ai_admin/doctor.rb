# frozen_string_literal: true

module RailsAiAdmin
  # Reports support boundaries without probing credentials or calling providers.
  class Doctor
    Check = Data.define(:name, :status, :message)

    def checks
      config = RailsAiAdmin.configuration
      result = [
        Check.new("context", config.context_adapter ? :review : :closed, "Context adapter must authenticate; generated stubs return nil. Verify using TestKit."),
        Check.new("policy", config.authorization_adapter == "RailsAiAdmin::Authorization::Adapter" ? :closed : :review, "Every scope, action and field grant is explicit; missing grants deny."),
        Check.new("assistant", :unsupported, "Assistant routes/tables are not installed; no provider call is made."),
        Check.new("files", :unsupported, "Private attachment management is not implemented."),
        Check.new("queue", :unsupported, "Only synchronous database CRUD is implemented; no durable job promise."),
        Check.new("coexistence", :review, "No rails_tool_views global configuration is changed; shared Surface integration is unresolved.")
      ]
      RailsAiAdmin.registry.resources.each do |resource|
        begin
          model = resource.model_class
          same_pool = model.connection_pool.equal?(OperationRun.connection_pool) && model.connection_pool.equal?(AuditEvent.connection_pool)
          locking = model.locking_enabled? && model.locking_column == "lock_version"
          writable = !resource.readonly?
          status = writable && (!same_pool || !locking || model.composite_primary_key?) ? :error : :ok
          message = "same_pool=#{same_pool}; lock_version=#{locking}; readonly=#{resource.readonly?}. Host callbacks must be database-only."
          result << Check.new("resource:#{resource.key}", status, message)
        rescue ActiveRecord::ActiveRecordError, NameError => error
          result << Check.new("resource:#{resource.key}", :error, "Inspect model/migrations (#{error.class.name}); no record content was printed.")
        end
      end
      result
    end
  end
end
