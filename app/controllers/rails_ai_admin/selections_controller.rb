# frozen_string_literal: true

module RailsAiAdmin
  # Snapshot capture/view is deliberately separate from business confirmation.
  class SelectionsController < ApplicationController
    DESTROY_REVIEW_PURPOSE = "rails_ai_admin/selection_destroy_review"

    def create
      @resource = RailsAiAdmin.registry.fetch(params[:resource])
      if params[:all_matching] == "1"
        resolve_list_navigation(strict: true)
        raise AccessDenied, "INVALID_QUERY" if return_state_discarded?
      else
        resolve_list_navigation
      end
      target_ids = if params[:all_matching] == "1"
        Authorization::Access.new(@context, @resource).authorize_selection!
        ids = matching_ids
        if ids.size > Selections::Builder::LIMIT
          redirect_to list_return_path, status: :see_other, notice: t("rails_ai_admin.selections.too_many", count: Selections::Builder::LIMIT)
          return
        end
        ids
      else
        Array(params[:target_ids])
      end
      # Nothing ticked is an ordinary mistake: return to the same list (RAA-013).
      if target_ids.compact_blank.empty?
        Authorization::Access.new(@context, @resource).authorize_selection!
        redirect_to list_return_path, status: :see_other, notice: t("rails_ai_admin.selections.empty")
        return
      end
      selection = Selections::Builder.new.capture(context: @context, resource: @resource, target_ids: target_ids)
      redirect_to next_step_path(selection.selection_ref), status: :see_other
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
      @operations = granted_collection_operations(@resource, access)
    end

    # Bulk delete reviews the fixed selection: records the actor may delete
    # now, and how many will be skipped. With none, the selection stays.
    def confirm_destroy
      load_deletable
      if @deletable.any?
        @review_signature = sign_destroy_review(@selection, @deletable)
        return
      end
      redirect_to selection_path(selection_ref: @selection.selection_ref, **navigation_params), status: :see_other,
        notice: t("rails_ai_admin.selections.destroy.none")
    end

    # Each record is deleted through the native destroy operation, with its own
    # policy check, captured version, transaction and audit event. One record
    # that cannot be deleted does not stop the others.
    def destroy
      digest = params[:manifest_digest]
      raise AccessDenied, "INVALID_QUERY" unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
      load_deletable(manifest_digest: digest)
      verify_destroy_review!(params[:review_signature], @selection, @deletable)
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

    # Every record the list shows across its pages, from the same normalized
    # search, tab, sort and filters, bounded one past the selection limit.
    # The builder then checks each of them again.
    def matching_ids
      state = navigation_state
      access = Authorization::Access.new(@context, @resource)
      records = Queries::List.new(@context, @resource).relation(search: state["q"], sort: state["sort"], direction: state.fetch("direction", "asc"),
        scope: state["scope"], filters: state["filter"]).limit(Selections::Builder::LIMIT + 1).to_a
      records.filter_map do |record|
        access.authorize!(:show, record)
        record.id.to_s
      rescue AccessDenied
        nil
      end
    end

    def sign_destroy_review(selection, targets)
      destroy_review_verifier.generate(destroy_review_digest(selection, targets),
        expires_at: selection.expires_at, purpose: DESTROY_REVIEW_PURPOSE)
    end

    def verify_destroy_review!(signature, selection, targets)
      raise AccessDenied, "INVALID_QUERY" unless signature.is_a?(String) && signature.bytesize.between?(1, 1024)
      unless destroy_review_verifier.verified(signature, purpose: DESTROY_REVIEW_PURPOSE) == destroy_review_digest(selection, targets)
        raise AccessDenied, "CONFLICT"
      end
    end

    def destroy_review_digest(selection, targets)
      InputSchema.digest(selection_ref: selection.selection_ref, manifest_digest: selection.manifest_digest,
        actor_ref: @context.actor_ref, tenant_ref: @context.tenant_ref, ids: targets.map(&:id))
    end

    def destroy_review_verifier = ::Rails.application.message_verifier(DESTROY_REVIEW_PURPOSE)

    # The list's bulk buttons name the action to review next. An unknown or
    # ungranted name falls back to the selection page; nothing runs here.
    def next_step_path(selection_ref)
      step = params[:then]
      if step == "destroy" && @resource.action_enabled?(:destroy)
        return confirm_destroy_selection_path(selection_ref: selection_ref, **navigation_params)
      end
      if step == "assistant" && assistant_for?(@resource)
        return selection_path(selection_ref: selection_ref, open_assistant: "1", **navigation_params)
      end
      if step.is_a?(String) && (key = step[/\Aoperation:([a-z][a-z0-9_]{0,79})\z/, 1])
        access = Authorization::Access.new(@context, @resource)
        operation = granted_collection_operations(@resource, access).find { |definition| definition.key.to_s == key }
        if operation
          return collection_operation_form_path(resource: @resource.key, operation: operation.key, selection_ref: selection_ref, **navigation_params)
        end
      end
      selection_path(selection_ref: selection_ref, **navigation_params)
    end

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
