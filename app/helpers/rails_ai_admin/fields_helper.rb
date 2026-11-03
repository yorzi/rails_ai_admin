# frozen_string_literal: true

module RailsAiAdmin
  module FieldsHelper
    # Only receives the already-authorized scalar projection. Host partials are
    # trusted Rails code, not a sandbox or an authorization mechanism.
    def admin_field_value(field, value, view:)
      value = String.new(value) if value.is_a?(String)
      if field.scalar_type == :belongs_to
        reference = value.nil? ? nil : admin_associations.reference(field, value)
        return render(partial: "rails_ai_admin/fields/reference", locals: { field: field, value: value, reference: reference })
      end
      text = field.format(value, time_zone: @context.time_zone)
      partial = field.display_partial(view) || "rails_ai_admin/fields/#{view == :index ? 'index' : 'show'}"
      render(partial: partial, locals: { field: field, value: value, text: text })
    end

    # A bounded picker of currently visible targets. A stored key the actor
    # cannot see stays selected so saving other fields never clears it; past
    # MAX_CHOICES (or without a target list grant) the form takes a typed key.
    def admin_reference_input(form, field, value, input_options)
      value = value.nil? ? nil : String.new(value.to_s)
      choices = admin_associations.choices(field)
      unless choices.complete
        return form.text_field(field.name, value: value, maxlength: 100, autocomplete: "off", spellcheck: false,
          placeholder: "#{Fields::Association.target(field).label.singularize} ID", **input_options)
      end
      options = choices.options.map(&:dup)
      if value.present? && options.none? { |_, key| key == value }
        options.unshift([ "#{admin_associations.reference(field, value).label} (not available)", value ])
      end
      form.select(field.name, options, { selected: value, include_blank: field.options[:nullable] ? "None" : "Choose a record" }, input_options)
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
