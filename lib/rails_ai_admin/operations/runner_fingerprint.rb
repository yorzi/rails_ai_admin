# frozen_string_literal: true

module RailsAiAdmin
  module Operations
    module RunnerFingerprint
      def self.call(resource, definition)
        # soft_delete changes what a delete does, so it invalidates open intents.
        extra = resource.soft_delete? ? { soft_delete: resource.soft_delete } : {}
        "operation:1:#{InputSchema.digest(identity: ResourceIdentity.call(resource), policy: resource.policy,
          fields: resource.fields.map(&:contract), operation: definition.key, definition: definition.signature, **extra)}"
      end
    end
  end
end
