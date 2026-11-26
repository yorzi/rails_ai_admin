# frozen_string_literal: true

module RailsAiAdmin
  # Inline SVG bars: no script and no inline style, so the admin CSP holds.
  # The chart is decorative for assistive technology; the caption and the data
  # table beside it carry the numbers.
  module DashboardHelper
    CHART_WIDTH = 600
    CHART_HEIGHT = 120

    def admin_trend_chart(trend)
      admin_bar_chart(trend.days)
    end

    def admin_bar_chart(rows)
      count = rows.size
      max = [ rows.map(&:last).max, 1 ].max
      gap = 2.0
      bar = (CHART_WIDTH - gap * (count - 1)) / count
      bars = rows.each_with_index.map do |(_day, value), index|
        height = value.zero? ? 0 : [ (value.fdiv(max) * (CHART_HEIGHT - 4)).round(1), 2 ].max
        tag.rect(x: (index * (bar + gap)).round(2), y: (CHART_HEIGHT - height).round(2), width: bar.round(2), height: height, rx: 1, class: "raa-bar")
      end
      baseline = tag.line(x1: 0, y1: CHART_HEIGHT - 0.5, x2: CHART_WIDTH, y2: CHART_HEIGHT - 0.5, class: "raa-axis")
      content_tag(:svg, safe_join(bars + [ baseline ]), viewBox: "0 0 #{CHART_WIDTH} #{CHART_HEIGHT}", class: "raa-chart",
        preserveAspectRatio: "none", focusable: "false", aria: { hidden: true })
    end

    def admin_report_chart(rows, time_series: false)
      return if rows.empty?
      return admin_bar_chart(rows) if !time_series && rows.all? { |_, value| value.is_a?(Numeric) && value >= 0 }
      return unless time_series
      dated = rows.reject { |label, _| label == "—" }
      values = dated.map(&:last).compact
      return if values.empty? || values.any? { |value| !value.is_a?(Numeric) }
      low, high = values.minmax
      points = dated.each_with_index.map do |(_, value), index|
        next if value.nil?
        x = dated.size == 1 ? CHART_WIDTH / 2 : 3 + index.fdiv(dated.size - 1) * (CHART_WIDTH - 6)
        y = high == low ? CHART_HEIGHT / 2 : 3 + (high - value).fdiv(high - low) * (CHART_HEIGHT - 6)
        [ x.round(2), y.round(2) ]
      end
      # A missing average breaks the line. Zero counts remain plotted.
      segments = points.chunk_while { |a, b| a && b }.filter_map do |segment|
        next unless segment.first
        if segment.one?
          tag.circle(cx: segment.first[0], cy: segment.first[1], r: 2, fill: "currentColor")
        else
          tag.polyline(points: segment.map { |point| point.join(",") }.join(" "), fill: "none", stroke: "currentColor", "stroke-width": 2)
        end
      end
      content_tag(:svg, safe_join(segments), viewBox: "0 0 #{CHART_WIDTH} #{CHART_HEIGHT}", class: "raa-chart",
        preserveAspectRatio: "none", focusable: "false", aria: { hidden: true })
    end

    def admin_number(value, capped)
      capped ? t("rails_ai_admin.dashboard.more_than", number: number_with_delimiter(value)) : number_with_delimiter(value)
    end
  end
end
