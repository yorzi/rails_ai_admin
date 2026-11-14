# frozen_string_literal: true

module RailsAiAdmin
  # Native inputs for already-granted typed filters. Values are the normalized
  # list hint strings; the server coerces them again before querying.
  module FiltersHelper
    def admin_filter_label(field, operator)
      case operator.to_sym
      when :gte then t("rails_ai_admin.filters.from", label: field.label)
      when :lte then t("rails_ai_admin.filters.to", label: field.label)
      when :contains then t("rails_ai_admin.filters.contains", label: field.label)
      when :in then t("rails_ai_admin.filters.any_of", label: field.label)
      when :blank then t("rails_ai_admin.filters.blank", label: field.label)
      else Field::RANGE_TYPES.include?(field.scalar_type) ? t("rails_ai_admin.filters.equals", label: field.label) : field.label
      end
    end

    # "Any of" is a group of checkboxes, one per declared choice, each its
    # own labelled control inside a fieldset whose legend names the field.
    def admin_filter_choices(field, values, id:)
      values = Array(values)
      tag.fieldset(class: "raa-filter raa-filter-choices") do
        legend = tag.legend(admin_filter_label(field, :in))
        boxes = field.choice_options.each_with_index.map do |(label, value), index|
          box_id = "#{id}-#{index}"
          tag.span(class: "raa-choice") do
            check_box_tag("filter[#{field.name}][in][]", value, values.include?(value), id: box_id) + label_tag(box_id, label)
          end
        end
        legend + safe_join(boxes)
      end
    end

    def admin_filter_input(field, operator, value, id:)
      name = "filter[#{field.name}][#{operator}]"
      value = value && String.new(value)
      if operator.to_sym == :blank
        return select_tag(name, options_for_select([ [ t("rails_ai_admin.filters.any"), "" ], [ t("rails_ai_admin.filters.empty"), "true" ], [ t("rails_ai_admin.filters.present"), "false" ] ], value), id: id)
      end
      return text_field_tag(name, value, id: id, maxlength: 200) if operator.to_sym == :contains
      case field.scalar_type
      when :belongs_to
        choices = admin_associations.choices(field)
        unless choices.complete
          key_input = text_field_tag(name, value, id: id, maxlength: 100, autocomplete: "off", spellcheck: false)
          return admin_reference_picker(Fields::Association.target(field), key_input, id, field, value)
        end
        options = [ [ t("rails_ai_admin.filters.any"), "" ] ] + choices.options.map(&:dup)
        options << [ admin_associations.reference(field, value).label, value ] if value.present? && options.none? { |_, key| key == value }
        select_tag(name, options_for_select(options, value), id: id)
      when :enum, :select
        select_tag(name, options_for_select([ [ t("rails_ai_admin.filters.any"), "" ] ] + field.choice_options.map(&:dup), value), id: id)
      when :boolean
        select_tag(name, options_for_select([ [ t("rails_ai_admin.filters.any"), "" ], [ t("rails_ai_admin.fields.yes"), "true" ], [ t("rails_ai_admin.fields.no"), "false" ] ], value), id: id)
      when :integer then number_field_tag(name, value, id: id, step: 1)
      when :decimal then text_field_tag(name, value, id: id, inputmode: "decimal", maxlength: 200)
      when :date then date_field_tag(name, value, id: id)
      when :datetime then datetime_local_field_tag(name, value, id: id)
      else text_field_tag(name, value, id: id, maxlength: 200)
      end
    end
  end
end
