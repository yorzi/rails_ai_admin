# frozen_string_literal: true

module RailsAiAdmin
  module Authorization
    # Default-deny policy interface. Hosts explicitly implement every permission.
    class Adapter
      def scope(context:, resource:, relation:)
        relation.none
      end

      def allowed?(context:, action:, resource:, record: nil)
        false
      end

      # action is :read, :write, :search or :sort; no implicit grants.
      def fields(context:, resource:, action:, record: nil)
        []
      end
    end
  end
end
