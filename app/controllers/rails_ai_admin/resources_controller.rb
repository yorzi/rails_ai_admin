# frozen_string_literal: true

module RailsAiAdmin
  # Conventional pages use the same operation runner as other trusted adapters.
  class ResourcesController < ApplicationController
    before_action :resolve_resource

    def index
      raw = params.to_unsafe_h.slice(*Navigation::ListState::KEYS)
      @list_navigation = Navigation::ListState.new(@access, raw, strict: true)
      if return_state_discarded?
        redirect_to list_return_path, status: :see_other, notice: "Some list settings are no longer available. The current list settings have been restored."
        return
      end
      # A native filter form submits every input; share only the canonical
      # nonblank conditions. This changes no grant and adds no notice.
      if raw.key?("filter") && raw["filter"] != navigation_state["filter"]
        redirect_to list_return_path, status: :see_other
        return
      end
      @page = Queries::List.new(@context, @resource).call(search: navigation_state["q"], sort: navigation_state["sort"], direction: navigation_state.fetch("direction", "asc"), page: navigation_state.fetch("page", "1"), recover_empty_page: true, scope: navigation_state["scope"], filters: navigation_state["filter"])
      if @page.number != navigation_state.fetch("page", "1").to_i
        @list_navigation = Navigation::ListState.new(@access, navigation_state.merge("page" => @page.number.to_s))
        redirect_to list_return_path, status: :see_other, notice: "That list page is now empty. Showing an available page."
        return
      end
      @sortable_fields = @access.fields(:sort)
      @list_scopes = @access.named_scopes
      @filter_fields = @access.fields(:filter)
      @current_scope = @page.scope
      @columns = @resource.index.order(@access.fields(:read, view: :index))
      computed = @columns.map(&:name) | [ @resource.title ]
      @rows = @page.records.map do |record|
        @access.authorize!(:show, record)
        values = @access.project(record, view: :index, only: computed)
        { id: record.id, label: record_label(@resource, record, values: values, view: :index), values: values }
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
      @values = @access.project(@record, view: :show)
      @fields = @access.fields(:read, @record, view: :show)
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

    def recover_form
      response.headers["Vary"] = [ response.headers["Vary"], "Cookie", "X-RailsAiAdmin-Recovery-Intent", "X-RailsAiAdmin-Return-State" ].compact.join(", ")
      session = runner.resume_form(context: @context, resource: @resource,
        intent_ref: request.headers["X-RailsAiAdmin-Recovery-Intent"])
      @intent, @record = session.intent, session.record
      @operation = @intent.operation.to_sym
      build_form_plan(@operation)
      @errors = {}
      render @operation == :create ? :new : :edit
      response.headers["X-RailsAiAdmin-Form-Recovery"] = "ready"
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
      resolve_list_navigation unless action_name == "index"
    end

    def runner
      @runner ||= Operations::Runner.new
    end

    def prepare_form(operation)
      @operation = operation
      @record = operation == :create ? @access.relation.new : @access.find!(params[:id], action: operation)
      @access.authorize!(operation, @record)
      build_form_plan(operation) unless operation == :destroy
      @errors = {}
      @intent = runner.prepare(context: @context, resource: @resource, operation: operation,
        target_id: operation == :create ? nil : @record.id, expected_version: operation == :create ? nil : @record.lock_version)
      render operation == :destroy ? :confirm_destroy : operation == :create ? :new : :edit
    end

    def submit(operation)
      input = operation == :destroy ? {} : submitted_input
      result = runner.execute(context: @context, intent_ref: params[:intent_ref], input: input,
        human_confirmed: true, origin: :ui,
        binding: { resource_key: @resource.key, operation: operation, target_id: params[:id] })
      if result.success?
        target = operation == :destroy ? list_return_path : resource_path(resource: @resource.key, id: result.record_id, **navigation_params)
        redirect_to target, status: :see_other, notice: result.warning ? "Changes saved, but a host callback failed. Review operation #{params[:intent_ref]} before continuing." : "Changes saved."
      elsif result.code == "NOT_FOUND"
        raise AccessDenied
      else
        @operation = operation
        @record = operation == :create ? @access.relation.new : @access.find!(params[:id], action: operation)
        @access.authorize!(operation, @record)
        @intent = OperationRun.find_by!(id: params[:intent_ref], actor_ref: @context.actor_ref, tenant_ref: @context.tenant_ref)
        build_form_plan(operation, input) unless operation == :destroy
        names = operation == :destroy ? [] : @form_fields.map { |field| field.name.to_s }
        @errors = result.errors.slice("base", *names)
        @errors["base"] ||= [ "Some inputs are no longer available" ] if (result.errors.keys - [ "base" ] - names).any?
        @failure_code = result.code
        @needs_reload = result.code != "VALIDATION_FAILED"
        render operation == :destroy ? :confirm_destroy : operation == :create ? :new : :edit,
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

    def build_form_plan(operation, input = nil)
      view = operation == :create ? :create : :edit
      @form_fields = @access.fields(:write, @record, operation: operation)
      readable_values = begin
        @access.project(@record, view: view)
      rescue AccessDenied
        {}
      end
      names = @form_fields.map { |field| field.name.to_s }
      @form_values = readable_values.slice(*names)
      if input.is_a?(Hash)
        @form_values.merge!(input.stringify_keys.slice(*names).reject { |_, value| value.is_a?(Hash) || value.is_a?(Array) })
      end
      readonly_fields = @access.fields(:read, @record, view: view).select { |field| readable_values.key?(field.name.to_s) && !names.include?(field.name.to_s) }
      readonly_values = readable_values.slice(*readonly_fields.map { |field| field.name.to_s })
      @form_plan = Forms::Plan.new(fields: @form_fields, values: @form_values, readonly_fields: readonly_fields, readonly_values: readonly_values, order: @resource.fields)
    end
  end
end
