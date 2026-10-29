# frozen_string_literal: true

module RailsAiAdmin
  module Generators
    # Uses Rails' loaded routes, including drawn files and namespace prefixes.
    module EngineMounts # :nodoc:
      def self.names(routes)
        routes.routes.filter_map do |route|
          endpoint = route.app
          while endpoint.is_a?(ActionDispatch::Routing::Mapper::Constraints)
            endpoint = endpoint.app
          end
          next unless endpoint.equal?(RailsAiAdmin::Engine) || endpoint.is_a?(RailsAiAdmin::Engine)
          route.parts.empty? && route.verb.empty? ? route.name.to_s : :unsupported
        end
      end
    end
  end
end
