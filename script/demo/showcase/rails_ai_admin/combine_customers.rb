# frozen_string_literal: true

class CombineCustomers < RailsAiAdmin::Quality::MergeOperation
  description "Transfer points to the selected customer and deactivate the other accounts"

  def preview_merge(_context, target, sources)
    { points: target.points.to_i + sources.sum { |source| source.points.to_i } }
  end

  def merge(context, target, sources)
    target.update!(preview_merge(context, target, sources))
    sources.each { |source| source.update!(points: 0, active: false) }
    success(target)
  end

  def verify(_context, target, _input)
    [ target.active? ? check_pass(:active, "The retained account is active.") : check_fail(:active, "The retained account is inactive.") ]
  end
end
