# frozen_string_literal: true

module RailsAiAdmin
  # Lists a resource's soft-deleted records and restores one at a time. Both
  # need the :restore grant; each row's button checks that record again.
  class DeletedRecordsController < ApplicationController
    PAGE_SIZE = 25
    before_action :resolve_deleted_resource

    def index
      page = params[:page].to_s
      page = "1" if page.empty?
      raise AccessDenied, "INVALID_QUERY" unless page.match?(/\A[1-9]\d{0,3}\z/) && page.to_i <= 1000
      @page = page.to_i
      records = @access.discarded_relation.offset((@page - 1) * PAGE_SIZE).limit(PAGE_SIZE + 1).to_a
      @has_next = records.size > PAGE_SIZE
      @records = records.first(PAGE_SIZE).map do |record|
        { id: record.id.to_s, label: record_label(@resource, record), deleted_at: record.public_send(@resource.soft_delete),
          version: RecordVersion.of(record).to_s, restorable: allowed_action?(@resource, :restore, record) }
      end
    end

    def restore
      Operations::Restore.new.call(context: @context, resource: @resource, id: params[:id], expected_version: params[:expected_version])
      redirect_to resource_path(resource: @resource.key, id: params[:id]), status: :see_other, notice: t("rails_ai_admin.deleted_records.restored")
    rescue AccessDenied => error
      raise unless error.code == "CONFLICT"
      redirect_to deleted_records_path(resource: @resource.key), status: :see_other, notice: t("rails_ai_admin.deleted_records.conflict")
    end

    private

    def resolve_deleted_resource
      @resource = RailsAiAdmin.registry.fetch(params[:resource])
      raise AccessDenied unless @resource.soft_delete?
      @access = Authorization::Access.new(@context, @resource)
      @access.authorize!(:restore)
      resolve_list_navigation
    end
  end
end
