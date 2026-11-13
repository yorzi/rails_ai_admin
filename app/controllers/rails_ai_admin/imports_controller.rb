# frozen_string_literal: true

module RailsAiAdmin
  # Upload a CSV file, check it, then create one record per row.
  class ImportsController < ApplicationController
    before_action :load_import

    def new; end

    # A header row naming every importable field; no data and no audit.
    def template
      send_data @import.template, filename: "#{@resource.key}-import.csv", type: "text/csv; charset=utf-8", disposition: "attachment"
    end

    def create
      file = params[:file]
      unless file.is_a?(ActionDispatch::Http::UploadedFile)
        @problem = t("rails_ai_admin.imports.choose_file")
        return render(:new, status: :unprocessable_content)
      end
      raise AccessDenied, "INVALID_QUERY" unless params[:mode].nil? || %w[check import].include?(params[:mode])
      if file.size > Presentation::CsvImport::MAX_BYTES
        @problem = t("rails_ai_admin.imports.too_large")
        return render(:new, status: :unprocessable_content)
      end
      @report = @import.call(file.read, write: params[:mode] == "import")
      render :new, status: @report.failed.any? ? :unprocessable_content : :ok
    rescue Presentation::CsvImport::Invalid => error
      @problem = error.message
      render :new, status: :unprocessable_content
    end

    private

    def load_import
      @resource = RailsAiAdmin.registry.fetch(params[:resource])
      Authorization::Access.new(@context, @resource).authorize_import!
      @import = Presentation::CsvImport.new(@context, @resource)
    end
  end
end
