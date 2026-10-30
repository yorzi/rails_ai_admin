# frozen_string_literal: true

module RailsAiAdmin
  module FieldsHelper
    # Only receives the already-authorized scalar projection. Host partials are
    # trusted Rails code, not a sandbox or an authorization mechanism.
    def admin_field_value(field, value, view:)
      value = String.new(value) if value.is_a?(String)
      text = field.format(value, time_zone: @context.time_zone)
      partial = field.display_partial(view)
      partial ? render(partial: partial, locals: { field: field, value: value, text: text }) : text
    end

    def admin_field_choices(field, value)
      choices = field.choice_options.map(&:dup)
      if value.present? && !field.choice_values.include?(value)
        choices.unshift([ "Unavailable value — select a current option", String.new(value.to_s), { disabled: true } ])
      end
      choices
    end
  end
end
