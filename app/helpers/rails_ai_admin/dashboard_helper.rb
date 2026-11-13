# frozen_string_literal: true

module RailsAiAdmin
  # Inline SVG bars: no script and no inline style, so the admin CSP holds.
  # The chart is decorative for assistive technology; the caption and the data
  # table beside it carry the numbers.
  module DashboardHelper
    CHART_WIDTH = 600
    CHART_HEIGHT = 120

    def admin_trend_chart(trend)
      count = trend.days.size
      gap = 2.0
      bar = (CHART_WIDTH - gap * (count - 1)) / count
      bars = trend.days.each_with_index.map do |(_day, value), index|
        height = value.zero? ? 0 : [ (value.fdiv(trend.max) * (CHART_HEIGHT - 4)).round(1), 2 ].max
        tag.rect(x: (index * (bar + gap)).round(2), y: (CHART_HEIGHT - height).round(2), width: bar.round(2), height: height, rx: 1, class: "raa-bar")
      end
      baseline = tag.line(x1: 0, y1: CHART_HEIGHT - 0.5, x2: CHART_WIDTH, y2: CHART_HEIGHT - 0.5, class: "raa-axis")
      content_tag(:svg, safe_join(bars + [ baseline ]), viewBox: "0 0 #{CHART_WIDTH} #{CHART_HEIGHT}", class: "raa-chart",
        preserveAspectRatio: "none", focusable: "false", aria: { hidden: true })
    end

    def admin_number(value, capped)
      capped ? t("rails_ai_admin.dashboard.more_than", number: number_with_delimiter(value)) : number_with_delimiter(value)
    end
  end
end
