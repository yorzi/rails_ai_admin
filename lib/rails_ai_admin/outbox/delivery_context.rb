# frozen_string_literal: true

module RailsAiAdmin
  module Outbox
    class DeliveryContext
      attr_reader :record, :generation

      def initialize(item, context, resource, record, authorization:)
        @item, @context, @resource, @record, @authorization = item, context, resource, record, authorization
        @generation, @used, @completed = item.generation, false, false
        @effect_mutex = Mutex.new
      end

      %i[actor tenant actor_ref tenant_ref security_version time_zone].each do |method|
        define_method(method) { @context.public_send(method) }
      end

      def delivery_key = "raa:work:#{@item.id}"
      def effect_completed? = @completed

      def assert_current!
        current = WorkItem.where(id: @item.id, status: "running", lease_owner: @item.lease_owner, generation: generation)
          .where("lease_expires_at > ?", Time.current).exists?
        raise Dispatcher::LeaseLost unless current
        true
      end

      def effect(request:)
        @effect_mutex.synchronize do
          raise ConfigurationError, "Each Work item permits exactly one effect" if @used
          @used = true
        end
        raise ConfigurationError, "External effects cannot run in a database transaction" if WorkItem.connection.transaction_open?
        digest = RequestDigest.call(request)
        @context, @resource, @record = @authorization.call
        owned = WorkItem.where(id: @item.id, status: "running", lease_owner: @item.lease_owner, generation: generation)
          .where("lease_expires_at > ?", Time.current)
        previous = owned.pick(:effect_digest)
        raise Dispatcher::Blocked, "REQUEST_CHANGED" if previous && previous != digest
        changed = ActiveRecord::Base.while_preventing_writes(false) do
          owned.where("(effect_generation IS NULL OR effect_generation < ?) AND (effect_digest IS NULL OR effect_digest = ?)", generation, digest)
            .update_all(effect_started_at: Time.current, effect_digest: digest, effect_generation: generation, updated_at: Time.current)
        end
        raise Dispatcher::LeaseLost if changed.zero?
        result = yield self
        @completed = true
        result
      end
    end
  end
end
