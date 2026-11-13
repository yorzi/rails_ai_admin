# frozen_string_literal: true

module RailsAiAdmin
  # Snapshot capture/view is deliberately separate from business confirmation.
  class SelectionsController < ApplicationController
    def create
      @resource = RailsAiAdmin.registry.fetch(params[:resource])
      resolve_list_navigation
      # Nothing ticked is an ordinary mistake: return to the same list (RAA-013).
      if Array(params[:target_ids]).compact_blank.empty?
        Authorization::Access.new(@context, @resource).authorize_selection!
        redirect_to list_return_path, status: :see_other, notice: t("rails_ai_admin.selections.empty")
        return
      end
      selection = Selections::Builder.new.capture(context: @context, resource: @resource, target_ids: params[:target_ids])
      redirect_to selection_path(selection_ref: selection.selection_ref, **navigation_params), status: :see_other
    end

    def show
      records = []
      @selection = Selections::Builder.new.revalidate(context: @context, selection_ref: params[:selection_ref]) { |record| records << record }
      @resource = RailsAiAdmin.registry.fetch(@selection.resource_key)
      resolve_list_navigation
      access = Authorization::Access.new(@context, @resource)
      # Offered when the actor may delete at least one selected record now.
      @deletable = @resource.action_enabled?(:destroy) && records.any? do |record|
        access.authorize!(:destroy, record)
      rescue AccessDenied
        false
      end
      @operations = RailsAiAdmin.operation_registry.custom(@resource).select do |definition|
        next false unless definition.scope == :collection
        access.authorize!(definition.key)
        definition.fields(access, nil)
        true
      rescue AccessDenied
        false
      end
    end

    # Bulk delete reviews the fixed selection: records the actor may delete
    # now, and how many will be skipped.
    def confirm_destroy
      load_deletable
      raise AccessDenied if @deletable.empty?
    end

    # Each record is deleted through the native destroy operation, with its own
    # policy check, captured version, transaction and audit event. One record
    # that cannot be deleted does not stop the others.
    def destroy
      digest = params[:manifest_digest]
      raise AccessDenied, "INVALID_QUERY" unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
      load_deletable(manifest_digest: digest)
      raise AccessDenied if @deletable.empty?
      runner = Operations::Runner.new
      @outcomes = @deletable.map do |target|
        code = begin
          intent = runner.prepare(context: @context, resource: @resource, operation: :destroy, target_id: target.id, expected_version: target.expected_version)
          runner.execute(context: @context, intent_ref: intent.id, input: {}, human_confirmed: true, origin: :ui).code
        rescue AccessDenied => error
          error.code
        end
        [ target, code ]
      end
      @deleted = @outcomes.count { |_, code| code == "OK" }
      failed = @outcomes.reject { |_, code| code == "OK" }
      if failed.empty? && @skipped.zero?
        redirect_to list_return_path, status: :see_other, notice: t("rails_ai_admin.selections.destroy.done", count: @deleted)
      else
        @failed = failed
        render :destroyed
      end
    end

    private

    def load_deletable(manifest_digest: nil)
      records = {}
      @selection = Selections::Builder.new.revalidate(context: @context, selection_ref: params[:selection_ref], manifest_digest: manifest_digest) do |record|
        records[record.id.to_s] = record
      end
      @resource = RailsAiAdmin.registry.fetch(@selection.resource_key)
      resolve_list_navigation
      raise AccessDenied unless @resource.action_enabled?(:destroy)
      access = Authorization::Access.new(@context, @resource)
      @deletable = @selection.targets.select do |target|
        access.authorize!(:destroy, records.fetch(target.id))
      rescue AccessDenied
        false
      end
      @skipped = @selection.targets.size - @deletable.size
    end
  end
end
