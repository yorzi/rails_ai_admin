# frozen_string_literal: true

module RailsAiAdmin
  # Conventional pages use the same operation runner as other trusted adapters.
  class ResourcesController < ApplicationController
    before_action :resolve_resource

    def index
      @page = Queries::List.new(@context, @resource).call(search: params[:q], sort: params[:sort], direction: params.fetch(:direction, "asc"), page: params.fetch(:page, "1"))
      @columns = @access.fields(:read)
      @rows = @page.records.map do |record|
        @access.authorize!(:show, record)
        values = @access.project(record)
        { id: record.id, label: record_label(@resource, record, values: values), values: values }
      end
      @searchable = @access.fields(:search).any?
      @selectable = begin
        @access.authorize_selection!
      rescue AccessDenied
        false
      end
    end

    def show
      @record = @access.find!(params[:id])
      @values = @access.project(@record)
      @fields = @access.fields(:read, @record)
      @operations = RailsAiAdmin.operation_registry.custom(@resource).select { |definition| definition.scope == :member }.select do |definition|
        @access.authorize!(definition.key, @record)
        definition.fields(@access, @record)
        true
      rescue AccessDenied
        false
      end
    end

    def new
      prepare_form(:create)
    end

    def edit
      prepare_form(:update)
    end

    def confirm_destroy
      prepare_form(:destroy)
    end

    def create = submit(:create)
    def update = submit(:update)
    def destroy = submit(:destroy)

    private

    def resolve_resource
      @resource = RailsAiAdmin.registry.fetch(params[:resource])
      @access = Authorization::Access.new(@context, @resource)
    end

    def runner
      @runner ||= Operations::Runner.new
    end

    def prepare_form(operation)
      @operation = operation
      @record = operation == :create ? @access.relation.new : @access.find!(params[:id], action: operation)
      @access.authorize!(operation, @record)
      @form_fields = operation == :destroy ? [] : @access.fields(:write, @record, operation: operation)
      @form_values = form_projection
      @errors = {}
      @intent = runner.prepare(context: @context, resource: @resource, operation: operation,
        target_id: operation == :create ? nil : @record.id, expected_version: operation == :create ? nil : @record.lock_version)
      render operation == :destroy ? :confirm_destroy : :form
    end

    def submit(operation)
      input = operation == :destroy ? {} : submitted_input
      result = runner.execute(context: @context, intent_ref: params[:intent_ref], input: input,
        human_confirmed: true, origin: :ui,
        binding: { resource_key: @resource.key, operation: operation, target_id: params[:id] })
      if result.success?
        target = operation == :destroy ? resources_path(resource: @resource.key) : resource_path(resource: @resource.key, id: result.record_id)
        redirect_to target, status: :see_other, notice: result.warning ? "Changes saved, but a host callback failed. Review operation #{params[:intent_ref]} before continuing." : "Changes saved."
      elsif result.code == "NOT_FOUND"
        raise AccessDenied
      else
        @operation = operation
        @record = operation == :create ? @access.relation.new : @access.find!(params[:id], action: operation)
        @access.authorize!(operation, @record)
        @intent = OperationRun.find_by!(id: params[:intent_ref], actor_ref: @context.actor_ref, tenant_ref: @context.tenant_ref)
        @form_fields = operation == :destroy ? [] : @access.fields(:write, @record, operation: operation)
        @form_values = form_projection.merge(input.is_a?(Hash) ? input.slice(*@form_fields.map { |field| field.name.to_s }).select { |_, value| !value.is_a?(Hash) && !value.is_a?(Array) } : {})
        @errors, @failure_code = result.errors, result.code
        @needs_reload = result.code != "VALIDATION_FAILED"
        render operation == :destroy ? :confirm_destroy : :form,
          status: result.code == "VALIDATION_FAILED" ? :unprocessable_content : :conflict
      end
    rescue ActiveRecord::RecordNotFound
      raise AccessDenied
    end

    def submitted_input
      value = params[:record]
      raise AccessDenied, "INVALID_QUERY" unless value.nil? || value.is_a?(ActionController::Parameters)
      value.is_a?(ActionController::Parameters) ? value.to_unsafe_h : {}
    end

    def form_projection
      @access.project(@record)
    rescue AccessDenied
      {}
    end
  end
end
