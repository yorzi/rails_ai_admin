# frozen_string_literal: true

module RailsAiAdmin
  module FieldsHelper
    # Only receives the already-authorized scalar projection. Host partials are
    # trusted Rails code, not a sandbox or an authorization mechanism.
    # record_id names the record a file field links to; pages that show one
    # record use @record.
    def admin_field_value(field, value, view:, record_id: @record&.id)
      value = String.new(value) if value.is_a?(String)
      return admin_file_value(field, value, view: view, record_id: record_id) if field.scalar_type == :file && !field.plugin?
      return admin_files_value(field, value, view: view, record_id: record_id) if field.scalar_type == :files
      return admin_references_value(field, value) if field.scalar_type == :references
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
        elsif field.scalar_type == :rich_text
          # The stored HTML through Rails' safe list; lists show plain text.
          text = view == :index ? text.squish.truncate(80) : tag.div(sanitize(value.to_s), class: "raa-rich-text")
        end
      end
      partial = field.display_partial(view) || "rails_ai_admin/fields/#{view == :index ? 'index' : 'show'}"
      render(partial: partial, locals: { field: field, value: value, text: text })
    end

    # Labels through each target's own grants; unavailable targets stay keys.
    REFERENCES_SHOWN = 50
    def admin_references_value(field, value)
      ids = Array(value)
      return "—" if ids.empty?
      admin_associations.prime(field, ids.first(REFERENCES_SHOWN))
      items = ids.first(REFERENCES_SHOWN).map do |id|
        reference = admin_associations.reference(field, id)
        reference.visible ? link_to(reference.label, resource_path(resource: reference.resource_key, id: reference.id)) : reference.label
      end
      items << t("rails_ai_admin.references.more", count: ids.size - REFERENCES_SHOWN) if ids.size > REFERENCES_SHOWN
      safe_join(items, ", ")
    end

    # Checkboxes for the visible targets (up to 100). With more targets, the
    # current ones stay as checkboxes and one key input, with the search
    # picker, adds another. The empty hidden value lets "none" be submitted.
    def admin_references_input(form, field, value, input_options)
      selected = Array(value)
      id = form.field_id(field.name)
      name = "#{form.field_name(field.name)}[]"
      choices = admin_associations.choices(field)
      admin_associations.prime(field, selected)
      options = if choices.complete
        choices.options
      else
        selected.filter_map { |key| (reference = admin_associations.reference(field, key)).visible ? [ reference.label, key ] : nil }
      end
      boxes = options.map do |label, key|
        box_id = "#{id}--#{key}"
        tag.div(safe_join([ check_box_tag(name, key, selected.include?(key), id: box_id), " ", label_tag(box_id, label) ]), class: "raa-check")
      end
      parts = [ hidden_field_tag(name, "", id: nil), *boxes ]
      parts << tag.p(t("rails_ai_admin.fields.none"), class: "raa-field-help") if options.empty? && choices.complete
      unless choices.complete
        target = Fields::Association.target(field)
        key_input = text_field_tag(name, "", id: "#{id}--add", maxlength: 100, autocomplete: "off", spellcheck: false,
          placeholder: t("rails_ai_admin.references.key_placeholder", target: target.label.singularize))
        parts << admin_reference_picker(target, key_input, "#{id}--add", field, nil)
      end
      tag.div(safe_join(parts), id: id, class: "raa-references", role: "group", aria: { labelledby: "#{id}--label", describedby: input_options.dig(:aria, :describedby), invalid: input_options.dig(:aria, :invalid) })
    end

    # A file links to the admin's own download route, which checks the record
    # and field grants again. Raster images also show a small inline preview.
    def admin_file_value(field, value, view:, record_id:)
      return "—" unless value.is_a?(Fields::FileValue)
      text = field.format(value, time_zone: @context.time_zone)
      return text unless record_id && @resource
      path = resource_file_path(resource: @resource.key, id: record_id, field: field.name)
      link = link_to(text, path)
      return link unless view != :index && value.image?
      safe_join([ tag.img(src: resource_file_path(resource: @resource.key, id: record_id, field: field.name, disposition: "inline"),
        alt: value.filename, class: "raa-file-preview", loading: "lazy"), link ])
    end

    # Trix, from the host's Action Text assets, edits a hidden input. The
    # label and descriptions point at the editor; file attachments are refused.
    def admin_rich_text_input(form, field, value, input_options)
      id = form.field_id(field.name)
      editor = content_tag("trix-editor", "", id: id, input: "#{id}--value", class: "raa-rich-text-editor",
        aria: input_options[:aria].merge(required: input_options[:required], labelledby: "#{id}--label"), data: { controller: "raa-rich-text",
        action: "trix-file-accept->raa-rich-text#refuse trix-change->raa-rich-text#change" })
      safe_join([ stylesheet_link_tag("trix"), javascript_include_tag("trix", defer: true),
        hidden_field_tag(form.field_name(field.name), value, id: "#{id}--value"), editor ])
    end

    # Several files: a count in lists, a gallery of previews and links on
    # show pages. Each link names its attachment.
    def admin_files_value(field, value, view:, record_id:)
      files = Array(value).grep(Fields::FileValue)
      return field.format(files, time_zone: @context.time_zone) if view == :index || files.empty? || !(record_id && @resource)
      items = files.map do |file|
        path = resource_file_path(resource: @resource.key, id: record_id, field: field.name, attachment: file.id)
        text = "#{file.filename} (#{number_to_human_size(file.byte_size)})"
        preview = file.image? ? tag.img(src: resource_file_path(resource: @resource.key, id: record_id, field: field.name, attachment: file.id, disposition: "inline"), alt: file.filename, class: "raa-file-preview", loading: "lazy") : nil
        tag.li(safe_join([ preview, link_to(text, path) ].compact))
      end
      tag.ul(safe_join(items), class: "raa-file-list")
    end

    # Current files with remove boxes, then a multiple file chooser.
    def admin_files_input(form, field, value, input_options)
      id = form.field_id(field.name)
      current = Array(value).grep(Fields::FileValue)
      boxes = current.map do |file|
        box_id = "#{id}--remove-#{file.id}"
        tag.li(safe_join([ check_box_tag("remove_attachments[#{field.name}][]", file.id, false, id: box_id), " ",
          label_tag(box_id, t("rails_ai_admin.files.remove_named", file: file.filename)) ]), class: "raa-check")
      end
      options = input_options.merge(multiple: true, required: nil)
      options[:accept] = field.options[:accept].join(",") if field.options[:accept]
      safe_join([ (tag.ul(safe_join(boxes), class: "raa-file-list") if boxes.any?), form.file_field(field.name, **options),
        tag.p(t("rails_ai_admin.files.list_limit", size: number_to_human_size(field.options[:max_size]), count: field.options[:max_files]), class: "raa-field-help") ].compact)
    end

    # Current file, a file chooser and (when the field may be empty) a remove box.
    def admin_file_input(form, field, value, input_options)
      current = value.is_a?(Fields::FileValue) ? value : nil
      parts = []
      if current
        parts << tag.p(t("rails_ai_admin.files.current", file: field.format(current, time_zone: @context.time_zone)), class: "raa-file-current")
      end
      options = input_options.merge(required: current ? nil : input_options[:required])
      options[:accept] = field.options[:accept].join(",") if field.options[:accept]
      parts << form.file_field(field.name, **options)
      parts << tag.p(t("rails_ai_admin.files.limit", size: number_to_human_size(field.options[:max_size])), class: "raa-field-help")
      if current && !admin_field_required?(field)
        id = "#{form.field_id(field.name)}--remove"
        parts << tag.p(safe_join([ check_box_tag("remove_files[]", field.name.to_s, false, id: id), " ", label_tag(id, t("rails_ai_admin.files.remove")) ]), class: "raa-file-remove")
      end
      safe_join(parts)
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
