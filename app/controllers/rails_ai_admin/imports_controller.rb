# frozen_string_literal: true

module RailsAiAdmin
  # Upload a CSV file, check it, then create one record per row.
  class ImportsController < ApplicationController
    before_action :load_import

    before_action :load_draft, only: %i[show update confirm suggest]

    def new; end

    def show
      @preview = @review.preview(@draft) if @draft.status == "draft"
    end

    def suggest
      raise AccessDenied unless assistant_for?(@resource)
      require "rails_ai_admin/assistant/import_mapping"
      @preview = @review.preview(@draft)
      @review.check_digest!(@preview.digest, params[:review_digest])
      begin
        @suggestions = Assistant::ImportMapping.suggest(@context, @resource, @preview.headers, @import.fields)
      rescue Assistant::ImportMapping::Unavailable
        @problem = t("rails_ai_admin.imports.ai_unavailable")
      end
      # No database lock spans the provider request. Reopen the draft and its
      # permissions before presenting any suggestion beside the current rows.
      load_import
      load_draft
      raise AccessDenied unless assistant_for?(@resource)
      @preview = @review.preview(@draft)
      @review.check_digest!(@preview.digest, params[:review_digest])
      allowed = @import.fields.map { |field| field.name.to_s }
      @suggestions&.select! { |_, (name, _)| allowed.include?(name) }
      render :show, status: @problem ? :service_unavailable : :ok
    end

    def update
      return confirm if params[:decision] == "confirm"
      @preview = @review.revise!(@draft, params[:review_digest], **choices)
      render :show
    end

    def confirm
      @review.confirm!(@draft, params[:review_digest], choices: params.key?(:mapping) ? choices : nil)
      redirect_to resource_import_draft_path(resource: @resource.key, id: @draft.id), status: :see_other
    end

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
      raise AccessDenied, "INVALID_QUERY" unless params[:mode].nil? || %w[check import review].include?(params[:mode])
      if file.size > Presentation::CsvImport::MAX_BYTES
        @problem = t("rails_ai_admin.imports.too_large")
        return render(:new, status: :unprocessable_content)
      end
      if params[:mode] == "review"
        raise ConfigurationError, "Install the import-drafts migration" unless ImportDraft.table_exists?
        draft = @review.create(file.read, file.original_filename)
        return redirect_to resource_import_draft_path(resource: @resource.key, id: draft.id), status: :see_other
      end
      @report = @import.call(file.read, write: params[:mode] == "import")
      render :new, status: @report.failed.any? ? :unprocessable_content : :ok
    rescue Presentation::CsvImport::Invalid => error
      @problem = error.message
      render :new, status: :unprocessable_content
    end

    private

    def choices
      mapping = params[:mapping]
      raise AccessDenied, "INVALID_QUERY" unless mapping.is_a?(ActionController::Parameters)
      { mapping: mapping.to_unsafe_h, excluded: params.fetch(:excluded, []), duplicates: params.fetch(:duplicates, "skip"),
        match_field: params[:match_field].presence }
    end

    def load_draft
      raise AccessDenied unless ImportDraft.table_exists?
      @draft = @review.find!(params[:id])
    end

    def load_import
      @resource = RailsAiAdmin.registry.fetch(params[:resource])
      Authorization::Access.new(@context, @resource).authorize_import!
      @review = Presentation::ImportReview.new(@context, @resource)
      @import = Presentation::CsvImport.new(@context, @resource)
    end
  end
end
