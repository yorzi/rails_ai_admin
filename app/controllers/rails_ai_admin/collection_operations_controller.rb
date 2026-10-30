# frozen_string_literal: true

module RailsAiAdmin
  class CollectionOperationsController < ApplicationController
    before_action :resolve_operation

    def new
      load_form
      @form_values, @errors = {}, {}
    end

    def preflight
      input = submitted_input
      @proposal = Collections::Runner.new.preflight(context: @context, resource: @resource, operation: @definition.key,
        selection_ref: params[:selection_ref], input: input)
      if @proposal.is_a?(Collections::Result)
        render_rejection(@proposal, input)
      else
        @wire_input = @proposal.intent.input_payload.to_json
        render :confirmation
      end
    end

    def execute
      input = confirmed_input
      result = Collections::Runner.new.admit(context: @context, intent_ref: params[:intent_ref], input: input,
        human_confirmed: true, binding: { resource_key: @resource.key, operation: @definition.key, selection_id: params[:selection_ref] })
      if result.accepted?
        redirect_to collection_job_path(job_ref: result.job_ref, **navigation_params), status: :see_other, notice: "Run admitted. Each record is executed separately; queued work is not a completed change."
      else
        render_rejection(result, input)
      end
    end

    private

    def resolve_operation
      @resource = RailsAiAdmin.registry.fetch(params[:resource])
      @definition = RailsAiAdmin.operation_registry.fetch(@resource, params[:operation])
      raise AccessDenied unless @definition.custom? && @definition.scope == :collection
      @access = Authorization::Access.new(@context, @resource)
      resolve_list_navigation
    end

    def load_form
      @selection = Selections::Builder.new.revalidate(context: @context, selection_ref: params[:selection_ref], resource: @resource)
      @access.authorize!(@definition.key)
      @form_fields = @definition.fields(@access, nil)
    end

    def submitted_input
      value = params[:input]
      raise AccessDenied, "INVALID_QUERY" unless value.nil? || value.is_a?(ActionController::Parameters)
      value ? value.to_unsafe_h : {}
    end

    def confirmed_input
      value = params[:confirmed_input]
      raise AccessDenied, "INVALID_QUERY" unless value.is_a?(String) && value.bytesize <= 16_384
      JSON.parse(value)
    rescue JSON::ParserError
      raise AccessDenied, "INVALID_QUERY"
    end

    def render_rejection(result, input)
      raise AccessDenied if result.code == "NOT_FOUND"
      @failure_code = result.code
      @uncertain_job_ref = result.job_ref if result.code == "OUTCOME_UNKNOWN"
      if result.code == "VALIDATION_FAILED"
        load_form
        @form_values = input.is_a?(Hash) ? input.stringify_keys.slice(*@form_fields.map { |field| field.name.to_s }).reject { |_, value| value.is_a?(Array) || value.is_a?(Hash) } : {}
        @errors = result.errors
        render :new, status: :unprocessable_content
      else
        render :failure, status: %w[TIMEOUT OPERATION_FAILED].include?(result.code) ? :service_unavailable : :conflict
      end
    end
  end
end
