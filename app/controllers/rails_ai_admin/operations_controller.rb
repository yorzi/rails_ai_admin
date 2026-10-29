# frozen_string_literal: true

module RailsAiAdmin
  # Human input -> pure preview -> input-bound confirmation -> shared Runner.
  class OperationsController < ApplicationController
    before_action :resolve_operation

    def new
      load_form
      @form_values, @errors = {}, {}
      render :form
    end

    def preflight
      load_form
      input = submitted_input
      proposal = Operations::Runner.new.preflight(context: @context, resource: @resource, operation: @definition.key,
        target_id: @record.id, expected_version: params[:expected_version], input: input)
      if proposal.is_a?(Operations::Result)
        render_failure(proposal, input)
      else
        @proposal = proposal
        @form_values = proposal.values
        @wire_input = JSON.generate(proposal.values.transform_values { |value| wire_value(value) })
        if request.format.turbo_stream?
          render turbo_stream: turbo_stream.replace(@flow_id, template: "rails_ai_admin/operations/confirmation", layout: false)
        else
          render :confirmation
        end
      end
    end

    def execute
      input = confirmed_input
      result = Operations::Runner.new.execute(context: @context, intent_ref: params[:intent_ref], input: input,
        human_confirmed: true, binding: { resource_key: @resource.key, operation: @definition.key, target_id: params[:id] })
      if result.success?
        notice = result.work_refs.any? ? "Operation completed. Follow-up work is pending or separately tracked." : "Operation completed."
        notice += " A host callback needs review." if result.warning
        redirect_to resource_path(resource: @resource.key, id: result.record_id), status: :see_other, notice: notice
      elsif result.code == "NOT_FOUND"
        raise AccessDenied
      elsif result.code == "VALIDATION_FAILED"
        load_form
        render_failure(result, input)
      else
        @failure_code = result.code
        render :failure, status: %w[OPERATION_FAILED TIMEOUT].include?(result.code) ? :service_unavailable : :conflict
      end
    end

    private

    def resolve_operation
      @resource = RailsAiAdmin.registry.fetch(params[:resource])
      @definition = RailsAiAdmin.operation_registry.fetch(@resource, params[:operation])
      raise AccessDenied unless @definition.custom?
      @access = Authorization::Access.new(@context, @resource)
      @flow_id = "raa_operation_#{@resource.key}_#{params[:id]}_#{@definition.key}"
    end

    def load_form
      @record = @access.find!(params[:id], action: @definition.key)
      @flow_id = "raa_operation_#{@resource.key}_#{@record.id}_#{@definition.key}"
      @form_fields = @definition.fields(@access, @record)
    end

    def submitted_input
      input = params[:input]
      raise AccessDenied, "INVALID_QUERY" unless input.nil? || input.is_a?(ActionController::Parameters)
      input ? input.to_unsafe_h : {}
    end

    def confirmed_input
      value = params[:confirmed_input]
      raise AccessDenied, "INVALID_QUERY" unless value.is_a?(String) && value.bytesize <= 16_384
      JSON.parse(value)
    rescue JSON::ParserError
      raise AccessDenied, "INVALID_QUERY"
    end

    def wire_value(value)
      case value
      when BigDecimal then value.to_s("F")
      when Time, ActiveSupport::TimeWithZone then value.utc.iso8601(6)
      when Date then value.iso8601
      else value
      end
    end

    def render_failure(result, input)
      names = @form_fields.map { |field| field.name.to_s }
      @form_values = input.is_a?(Hash) ? input.stringify_keys.slice(*names).reject { |_, value| value.is_a?(Array) || value.is_a?(Hash) } : {}
      @errors, @failure_code = result.errors, result.code
      status = case result.code
      when "VALIDATION_FAILED" then :unprocessable_content
      when "CONFLICT" then :conflict
      else :service_unavailable
      end
      render :form, status: status
    end
  end
end
