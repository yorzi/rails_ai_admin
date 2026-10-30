# frozen_string_literal: true

module RailsAiAdmin
  module Collections
    # A server-created lease token. Public HTTP execution cannot supply one.
    class Claim
      attr_reader :item_ref, :parent_ref, :operation_run_id, :owner, :generation
      def initialize(item)
        @item_ref, @parent_ref, @operation_run_id = item.id, item.parent_run_id, item.operation_run_id
        @owner, @generation = item.lease_owner, item.generation
      end

      def context
        run = OperationRun.find(parent_ref)
        @parent_snapshot = run
        ActiveRecord::Base.while_preventing_writes do
          adapter = RailsAiAdmin.configuration.context_adapter&.constantize&.new
          raise AccessDenied, "APPROVAL_INVALIDATED" unless adapter&.respond_to?(:resolve_job)
          current = adapter.resolve_job(actor_ref: run.actor_ref, tenant_ref: run.tenant_ref, security_version: run.security_version)
          unless current.is_a?(Context) && current.actor_ref == run.actor_ref && current.tenant_ref == run.tenant_ref && current.security_version == run.security_version
            raise AccessDenied, "APPROVAL_INVALIDATED"
          end
          current
        end
      rescue AccessDenied
        raise AccessDenied, "APPROVAL_INVALIDATED", cause: nil
      rescue ActiveRecord::ReadOnlyError
        raise ConfigurationError, "Job context resolution must be read-only", cause: nil
      end

      def payload = @parent_snapshot.input_payload
      def origin = @parent_snapshot.origin

      def lock!(context)
        @parent = Contract.owned(context, parent_ref, lock: true)
        @item = BatchItem.lock.find_by(id: item_ref, parent_run_id: parent_ref, operation_run_id: operation_run_id)
        verify_live!
        @resource, @definition = Contract.definition(@parent)
        Contract.verify_approved!(@parent, @definition, context)
        begin
          ActiveRecord::Base.while_preventing_writes do
            access = Authorization::Access.new(context, @resource)
            access.authorize!(@parent.operation)
            current = InputSchema.new(@definition.fields(access, nil)).coerce(@parent.input_payload, time_zone: context.time_zone)
            raise AccessDenied unless current.valid? && InputSchema.digest(current.values) == @parent.input_digest
          end
        rescue AccessDenied
          raise AccessDenied, "AUTHORIZATION_REVOKED", cause: nil
        end
        unless @parent.manifest_payload[@item.position] == [ @item.target_id, @item.expected_version ]
          raise AccessDenied, "APPROVAL_INVALIDATED"
        end
      end

      def validate_child!(run, resource, definition)
        unless resource.equal?(@resource) && definition.scope == :collection && run.parent_run_id == parent_ref &&
            run.selection_id.nil? && run.target_id == @item.target_id && run.expected_version == @item.expected_version &&
            run.actor_ref == @parent.actor_ref && run.tenant_ref == @parent.tenant_ref && run.security_version == @parent.security_version &&
            run.resource_key == @parent.resource_key && run.operation == @parent.operation && run.operation_version == @parent.operation_version &&
            run.input_digest == @parent.input_digest && run.origin == @parent.origin && run.expires_at == @parent.execution_deadline &&
            run.approved_by_ref.nil? && run.confirmed_at.nil? && run.approved_digest.nil?
          raise AccessDenied, "APPROVAL_INVALIDATED"
        end
      end

      def complete!(run)
        verify_live!
        raise ConfigurationError, "Child receipt did not commit success" unless run.status == "succeeded"
        @item.update!(status: "succeeded", last_code: "OK", completed_at: Time.current)
        Contract.refresh!(@parent)
        # Projection and all metadata writes must finish within the lease.
        # Parent/item locks remain held through the encompassing business commit.
        unless @item.lease_owner == owner && @item.generation == generation && @item.lease_expires_at > Time.current
          raise AccessDenied, "FENCED"
        end
        raise AccessDenied, "EXECUTION_EXPIRED" unless @parent.execution_deadline > Time.current
      end

      private

      def verify_live!
        unless @item && @item.status == "running" && @item.lease_owner == owner && @item.generation == generation && @item.lease_expires_at && @item.lease_expires_at > Time.current
          raise AccessDenied, "FENCED"
        end
        raise AccessDenied, "CANCELLED" if @parent.cancellation_requested_at
        raise AccessDenied, "EXECUTION_EXPIRED" unless @parent.execution_deadline && @parent.execution_deadline > Time.current
        raise AccessDenied, "FENCED" unless Contract::ACTIVE.include?(@parent.status)
      end
    end
  end
end
