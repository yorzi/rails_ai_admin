class TrimmedTextField < RailsAiAdmin::Fields::Type
  scalar :text
  version "1"
  form_partial "admin_fields/trimmed_text_input"
  index_partial "admin_fields/trimmed_text"
  show_partial "admin_fields/trimmed_text"

  def normalize(value, field:, time_zone:) = value.unicode_normalize(:nfc).strip
  def valid?(value, field:, time_zone:) = !value.match?(/[[:cntrl:]]/)
  def schema(field:) = { minLength: 1, maxLength: 120 }
end
