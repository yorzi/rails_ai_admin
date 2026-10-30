# frozen_string_literal: true

module RailsAiAdmin
  module Navigation
    # Presentation only: never changes resource/action/field authority.
    class Settings < Data.define(:group, :label, :icon, :order, :hidden)
      ICONS = %w[users shopping-bag life-buoy document grid].freeze

      def initialize(group: nil, label: nil, icon: nil, order: 0, hidden: false)
        unless icon.nil? || icon.is_a?(String) && ICONS.include?(icon)
          raise ConfigurationError, "Navigation icon must be a registered icon name"
        end
        raise ConfigurationError, "Navigation order must be an integer from -1000 to 1000" unless order.is_a?(Integer) && (-1000..1000).cover?(order)
        raise ConfigurationError, "Navigation hidden must be boolean" unless [ true, false ].include?(hidden)
        super(group: self.class.caption(group), label: self.class.caption(label), icon: icon && String.new(icon).freeze, order: order, hidden: hidden)
      end

      def self.caption(value)
        return if value.nil?
        unless value.is_a?(String) && value.valid_encoding? && (value.encoding == Encoding::UTF_8 || value.ascii_only?) &&
            (1..80).cover?(value.length) && value.strip.present? && !value.match?(/[\x00-\x1f\x7f]/)
          raise ConfigurationError, "Navigation text must be plain UTF-8 text of 1 to 80 characters without controls"
        end
        String.new(value).encode(Encoding::UTF_8).freeze
      end
    end
  end
end
