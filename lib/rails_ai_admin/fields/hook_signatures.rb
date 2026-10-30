# frozen_string_literal: true

module RailsAiAdmin
  module Fields
    module HookSignatures
      private

      def accepts?(method, count, keywords)
        params = method.parameters
        minimum = params.count { |kind, _| kind == :req }
        maximum = params.any? { |kind, _| kind == :rest } ? Float::INFINITY : minimum + params.count { |kind, _| kind == :opt }
        (minimum..maximum).cover?(count) && (params.filter_map { |kind, key| key if kind == :keyreq } - keywords).empty? &&
          !params.any? { |kind, _| kind == :nokey } &&
          (params.any? { |kind, _| kind == :keyrest } || (keywords - params.filter_map { |kind, key| key if %i[key keyreq].include?(kind) }).empty?)
      end
    end
  end
end
