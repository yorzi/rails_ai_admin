# frozen_string_literal: true

module RailsAiAdmin
  # One search box over every resource the actor may list and search. Each
  # resource runs its own list query (policy relation, default list tab,
  # granted search fields) and each row its own show grant.
  class SearchController < ApplicationController
    PER_RESOURCE = 5
    # A bound on list queries for one search.
    MAX_RESOURCES = 30
    Section = Data.define(:resource, :rows, :more)
    Row = Data.define(:id, :label)

    def index
      query = params[:q]
      raise AccessDenied, "INVALID_QUERY" unless query.nil? || query.is_a?(String)
      @query = query.to_s.strip
      raise AccessDenied, "INVALID_QUERY" unless @query.valid_encoding? && @query.length <= 200
      @sections = @query.empty? ? [] : searchable_resources.first(MAX_RESOURCES).filter_map { |resource| section(resource) }
    end

    private

    def section(resource)
      access = Authorization::Access.new(@context, resource)
      page = Queries::List.new(@context, resource).call(search: @query, page_size: PER_RESOURCE)
      rows = page.records.filter_map do |record|
        access.authorize!(:show, record)
        Row.new(record.id.to_s, access.record_label(record, view: :index))
      rescue AccessDenied
        nil
      end
      return if rows.empty?
      Section.new(resource, rows, page.has_next)
    rescue AccessDenied
      nil
    end
  end
end
