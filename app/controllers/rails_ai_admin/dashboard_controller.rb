# frozen_string_literal: true

module RailsAiAdmin
  class DashboardController < ApplicationController # :nodoc:
    # Counts appear only for resources whose list already opts into exact
    # counts, with the same bound (10,000) and default list tab.
    def index
      @widgets = Presentation::Dashboard.build(@context, RailsAiAdmin.registry.resources.reject { |resource| resource.navigation.hidden })
      @counts = RailsAiAdmin.registry.resources.each_with_object({}) do |resource, counts|
        next unless resource.index.count == :exact
        counts[resource.key.to_s] = Queries::List.new(@context, resource).count
      rescue AccessDenied
        next
      end
    end
  end
end
