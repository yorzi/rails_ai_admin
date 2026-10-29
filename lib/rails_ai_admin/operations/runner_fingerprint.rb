# frozen_string_literal: true

module RailsAiAdmin
  module Operations
    module RunnerFingerprint
      def self.call(resource, definition)
        "operation:1:#{InputSchema.digest(identity: ResourceIdentity.call(resource), policy: resource.policy,
          fields: resource.fields.map { |field| [ field.name, field.type, field.options ] }, operation: definition.key, definition: definition.signature)}"
      end
    end
  end
end
