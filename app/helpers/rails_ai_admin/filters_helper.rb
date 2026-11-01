# frozen_string_literal: true

module RailsAiAdmin
  # Native inputs for already-granted typed filters. Values are the normalized
  # list hint strings; the server coerces them again before querying.
  module FiltersHelper
    def admin_filter_label(field, operator)
      case operator.to_sym
      when :gte then "#{field.label} from"
      when :lte then "#{field.label} to"
      else Field::RANGE_TYPES.include?(field.scalar_type) ? "#{field.label} equals" : field.label
      end
    end

    def admin_filter_input(field, operator, value, id:)
      name = "filter[#{field.name}][#{operator}]"
      value = value && String.new(value)
      case field.scalar_type
      when :enum, :select
        select_tag(name, options_for_select([ [ "Any", "" ] ] + field.choice_options.map(&:dup), value), id: id)
      when :boolean
        select_tag(name, options_for_select([ [ "Any", "" ], [ "Yes", "true" ], [ "No", "false" ] ], value), id: id)
      when :integer then number_field_tag(name, value, id: id, step: 1)
      when :decimal then text_field_tag(name, value, id: id, inputmode: "decimal", maxlength: 200)
      when :date then date_field_tag(name, value, id: id)
      when :datetime then datetime_local_field_tag(name, value, id: id)
      else text_field_tag(name, value, id: id, maxlength: 200)
      end
    end
  end
end
