# frozen_string_literal: true

module RailsAiAdmin
  module Quality
    # The host defines the domain merge. The runner supplies exactly the
    # authorized, version-checked source records in its transaction.
    class MergeOperation < Operation
      def self.inherited(child)
        super
        child.input { text :merge_review, required: true, nullable: false, max_length: 12_000 }
      end

      def self.validate!
        super
        unless instance_method(:perform).owner == MergeOperation && instance_method(:preflight).owner == MergeOperation
          raise ConfigurationError, "Override merge or preview_merge to retain merge checks"
        end
        unless public_method_defined?(:merge) && accepts_arguments?(instance_method(:merge), 3) && input.map(&:name) == [ :merge_review ]
          raise ConfigurationError, "A merge operation needs merge(context, target, sources) and the built-in merge_review input"
        end
        unless public_method_defined?(:preview_merge) && accepts_arguments?(instance_method(:preview_merge), 3)
          raise ConfigurationError, "A merge preview must accept (context, target, sources)"
        end
        self
      end

      def preflight(context, target, input)
        sources = context.reviewed_merge_sources(input.fetch("merge_review"))
        preview_merge(context, target, sources)
      end

      def preview_merge(_context, _target, _sources) = {}

      def perform(context, target, input)
        merge(context, target, context.reviewed_merge_sources(input.fetch("merge_review")))
      end
    end
  end
end
