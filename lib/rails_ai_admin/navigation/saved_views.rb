# frozen_string_literal: true

module RailsAiAdmin
  module Navigation
    # Named list settings that belong to one actor in one tenant. Saving one
    # grants nothing: each view is read back through ListState, so a revoked
    # search, sort, tab or filter grant drops out of the link.
    class SavedViews
      MAX_PER_RESOURCE = 20
      MAX_NAME = 80
      View = Data.define(:id, :name, :state)
      # A save the person can fix: reason is :name or :limit.
      class Rejected < StandardError
        attr_reader :reason

        def initialize(reason)
          @reason = reason
          super(reason.to_s)
        end
      end

      def self.available?
        SavedView.table_exists?
      rescue ActiveRecord::ActiveRecordError
        false
      end

      def initialize(access)
        @access = access
        @context = access.context
        @resource = access.resource
      end

      # The actor's views for this resource, by name, each with its current
      # canonical state (without a page).
      def list
        @access.authorize!(:index)
        owned.order(:name).limit(MAX_PER_RESOURCE).map do |row|
          state = ListState.new(@access, parse(row.state)).state.except("page")
          View.new(row.id, row.name, state)
        end
      end

      # Saves state under name, replacing a view of the same name.
      def save(name, state)
        @access.authorize!(:index)
        name = normalize_name(name)
        state = ListState.new(@access, state).state.except("page")
        SavedView.transaction(requires_new: true) do
          row = owned.lock.find_by(name: name)
          if row
            row.update!(state: JSON.generate(state))
          else
            raise Rejected, :limit if owned.count >= MAX_PER_RESOURCE
            row = SavedView.create!(actor_ref: @context.actor_ref, tenant_ref: @context.tenant_ref,
              resource_key: @resource.key.to_s, name: name, state: JSON.generate(state))
          end
          View.new(row.id, row.name, state)
        end
      rescue ActiveRecord::RecordNotUnique
        # Two saves of a new name raced; the other one won.
        retry_save ||= 0
        retry if (retry_save += 1) < 2
        raise
      end

      def delete(id)
        @access.authorize!(:index)
        raise AccessDenied unless id.is_a?(String) && id.match?(/\A[1-9]\d{0,18}\z/)
        owned.where(id: id).delete_all.positive? || raise(AccessDenied)
      end

      private

      def owned
        SavedView.where(actor_ref: @context.actor_ref, tenant_ref: @context.tenant_ref, resource_key: @resource.key.to_s)
      end

      def normalize_name(name)
        name = name.squish if name.is_a?(String) && name.valid_encoding?
        unless name.is_a?(String) && name.valid_encoding? && (name.encoding == Encoding::UTF_8 || name.ascii_only?) &&
            name.length.between?(1, MAX_NAME) && !name.match?(/[[:cntrl:]]/)
          raise Rejected, :name
        end
        name
      end

      def parse(text)
        value = JSON.parse(text)
        value.is_a?(Hash) ? value : {}
      rescue JSON::ParserError
        {}
      end
    end
  end
end
