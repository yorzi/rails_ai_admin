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
      unless field.plugin? || value.nil?
        # The readable text stays visible; the exact value is machine-readable,
        # and long text keeps its line breaks (RAA-015).
        if field.scalar_type == :datetime
          text = tag.time(text, datetime: value.in_time_zone(@context.time_zone).iso8601)
        elsif field.scalar_type == :date
          text = tag.time(text, datetime: value.iso8601)
        elsif field.scalar_type == :textarea && view != :index
          text = tag.span(text, class: "raa-multiline")
        elsif field.scalar_type == :email
          text = mail_to(value.to_s, text)
        elsif field.scalar_type == :url && field.web_address?(value.to_s)
          # Only an absolute http(s) address becomes a link (never javascript:).
          text = link_to(text, value.to_s, rel: "noopener noreferrer nofollow", target: "_blank")
        elsif field.scalar_type == :json
          text = view == :index ? text.squish.truncate(80) : tag.pre(text, class: "raa-json")
        end
      end
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
        target = Fields::Association.target(field)
        key_input = form.text_field(field.name, value: value, maxlength: 100, autocomplete: "off", spellcheck: false,
          placeholder: t("rails_ai_admin.references.key_placeholder", target: target.label.singularize), **input_options)
        return admin_reference_picker(target, key_input, form.field_id(field.name), field, value)
      end
      options = choices.options.map(&:dup)
      if value.present? && options.none? { |_, key| key == value }
        options.unshift([ t("rails_ai_admin.references.not_available", label: admin_associations.reference(field, value).label), value ])
      end
      form.select(field.name, options, { selected: value, include_blank: field.options[:nullable] ? t("rails_ai_admin.fields.none") : t("rails_ai_admin.fields.choose_record") }, input_options)
    end

    # The typed key input, plus a search box when the actor can list the
    # target (the search endpoint applies the same grants again).
    def admin_reference_picker(target, key_input, key_id, field, value)
      return key_input unless allowed_action?(target, :index)
      current = value.present? ? admin_associations.reference(field, value) : nil
      render(partial: "rails_ai_admin/fields/reference_picker",
        locals: { target: target, key_input: key_input, key_id: key_id, current: current&.visible ? current : nil })
    end

    # Untranslated templates for the picker script; it fills %{count} and %{label}.
    def admin_reference_messages
      results = t("rails_ai_admin.references.results")
      { searching: t("rails_ai_admin.references.searching"), none: t("rails_ai_admin.references.none"),
        failed: t("rails_ai_admin.references.failed"), one: results[:one], other: results[:other],
        chosen: t("rails_ai_admin.references.chosen") }
    end

    # Says how the box matches, so "Love" not finding "Ada Lovelace" under
    # prefix search is not a surprise (RAA-021).
    def admin_search_placeholder(fields)
      modes = fields.map { |field| field.options[:searchable] == true ? :prefix : field.options[:searchable] }.uniq
      case modes
      when [ :prefix ] then t("rails_ai_admin.search.prefix")
      when [ :contains ] then t("rails_ai_admin.search.contains")
      when [ :exact ] then t("rails_ai_admin.search.exact")
      else t("rails_ai_admin.search.any")
      end
    end

    # The same rule as blank-input coercion: required or not nullable (RAA-023).
    # An edit form's empty password box keeps the current password.
    def admin_field_required?(field)
      return field.options[:required] == true && @operation != :update if field.scalar_type == :password
      field.options[:required] == true || field.options[:nullable] == false
    end

    def admin_time_input_value(field, value)
      return value if value.nil? || value.is_a?(String) && !value.match?(Field::TIME_OF_DAY)
      field.format_time_of_day(value)
    end

    # Submitted text comes back as typed; a stored value is indented.
    def admin_json_input_value(value)
      return value if value.nil? || value.is_a?(String)
      JSON.pretty_generate(value)
    rescue JSON::GeneratorError
      nil
    end

    # datetime-local value in the context zone. Seconds are kept when set so
    # an unchanged form submits the stored second back.
    def admin_datetime_input_value(value)
      return value unless value.respond_to?(:in_time_zone)
      local = value.in_time_zone(@context.time_zone)
      local.strftime(local.sec.zero? ? "%Y-%m-%dT%H:%M" : "%Y-%m-%dT%H:%M:%S")
    end

    def admin_field_choices(field, value)
      choices = field.choice_options.map(&:dup)
      if value.present? && !field.choice_values.include?(value)
        choices.unshift([ t("rails_ai_admin.fields.unavailable_value"), String.new(value.to_s), { disabled: true } ])
      end
      choices
    end
  end
end
