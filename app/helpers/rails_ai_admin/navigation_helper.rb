# frozen_string_literal: true

module RailsAiAdmin
  # Original project-owned outline glyphs, with fixed SVG attributes and paths.
  module NavigationHelper
    # Page title parts, most specific first (RAA-024). The first call wins, so
    # a page rendered inside another keeps the outer page's title.
    def admin_title(*parts)
      @raa_title_parts ||= parts.compact.map { |part| part.to_s.squish.truncate(80) }.reject(&:empty?)
      nil
    end

    # A result code as a sentence, with the code kept as secondary text for
    # support (RAA-027).
    def admin_outcome(code)
      return "" if code.blank?
      safe_join([ Presentation::Outcomes.sentence(code), " ", tag.span("(#{code})", class: "raa-code") ])
    end

    # A stored run, item or work status ("succeeded") as display text.
    def admin_state_name(status)
      status = status.to_s
      return status.humanize unless status.match?(/\A[a-z][a-z_]{0,63}\z/)
      t(status, scope: %i[rails_ai_admin states], default: status.humanize)
    end

    # { "succeeded" => 2, "failed" => 1 } as "Succeeded: 2 · Failed: 1".
    def admin_state_counts(counts)
      counts.map { |status, count| t("rails_ai_admin.states.count", state: admin_state_name(status), count: count) }.join(" · ")
    end

    # "Edit ORD-0001 · Orders · Administration".
    def admin_page_title
      [ *Array(@raa_title_parts), RailsAiAdmin.configuration.title ].join(" · ")
    end

    ICON_PATHS = {
      "users" => [ "M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8Z", "M2 21v-3a6 6 0 0 1 12 0v3M17 4a4 4 0 0 1 0 8M18 15a5 5 0 0 1 4 5v1" ],
      "shopping-bag" => [ "M4 7h16l1 14H3L4 7ZM8 8V6a4 4 0 0 1 8 0v2" ],
      "life-buoy" => [ "M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0ZM16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0Z", "m5 5 4 4m6 6 4 4M5 19l4-4m6-6 4-4" ],
      "document" => [ "M5 2h9l5 5v15H5V2ZM14 2v6h5M8 12h8M8 16h8" ],
      "grid" => [ "M3 3h7v7H3V3Zm11 0h7v7h-7V3ZM3 14h7v7H3v-7Zm11 0h7v7h-7v-7Z" ]
    }.transform_values { |paths| paths.each(&:freeze).freeze }.freeze

    def navigation_icon(name)
      return unless name
      paths = ICON_PATHS.fetch(name) { raise ConfigurationError, "Unknown navigation icon" }
      tag.svg(class: "raa-nav-icon", viewBox: "0 0 24 24", fill: "none", stroke: "currentColor",
        "stroke-width": "1.7", "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true", focusable: "false") do
        safe_join(paths.map { |path| tag.path(d: path) })
      end
    end
  end
end
