# frozen_string_literal: true

module RailsAiAdmin
  # The review page of an assistant's bulk change (Operations::BulkChange).
  # Showing it writes nothing. Confirming updates each ready record through
  # the native update operation as the signed-in person, each in its own
  # transaction with a version check and an audit event; one record that
  # fails does not stop the others. Confirming or dismissing tells the
  # conversation once.
  class BulkChangesController < ApplicationController
    def show
      load_plan
      @review_signature = Operations::BulkChange.sign_review(@selection, params[:change], @ready) if @ready.any?
    end

    # Revises the selected subset and/or proposed field values into a brand-new
    # immutable Selection + encrypted change token, invalidating the previous
    # preview without writing any business records.
    def revise
      load_plan
      selected_ids = submitted_target_ids || []
      ready_ids = @ready.map { |item| item.target.id }
      remember_submission
      if selected_ids.empty?
        @review_signature = Operations::BulkChange.sign_review(@selection, params[:change], @ready) if @ready.any?
        @revise_error = t("rails_ai_admin.bulk_changes.revise.empty_selection")
        return render :show, status: :unprocessable_content
      end
      raise AccessDenied, "INVALID_QUERY" unless (selected_ids - ready_ids).empty?
      revised_values = revised_input_values
      if revised_values.nil?
        @review_signature = Operations::BulkChange.sign_review(@selection, params[:change], @ready) if @ready.any?
        @revise_error = t("rails_ai_admin.bulk_changes.revise.invalid_values")
        return render :show, status: :unprocessable_content
      end
      revised_selection = nil
      Selection.transaction do
        Operations::BulkChange.supersede!(@selection)
        revised_selection = Selections::Builder.new.capture(context: @context, resource: @resource, target_ids: selected_ids)
      end
      revised_token = Operations::BulkChange.encode(context: @context, selection: revised_selection,
        resource: @resource, values: revised_values, context_ref: @proposal.context_ref)
      redirect_to bulk_change_path(selection_ref: revised_selection.selection_ref, change: revised_token), status: :see_other
    end

    def create
      return revise if params[:decision] == "revise"
      decision = params[:decision]
      raise AccessDenied, "INVALID_QUERY" unless Operations::BulkChange::DECISIONS.include?(decision)
      if decision == "dismiss"
        load_dismiss_target
        Operations::BulkChange.decide!(@selection, decision)
        continue_chat("dismissed", "Nothing was changed.")
        return redirect_to(return_path, status: :see_other, notice: t("rails_ai_admin.bulk_changes.dismissed"))
      end
      load_plan
      Operations::BulkChange.verify_review!(params[:review_signature], params[:change], @ready)
      raise AccessDenied if @ready.empty?
      # Unticked rows or edited values must go through a new preview first;
      # confirming applies only the review as it was shown, or nothing.
      unless submission_matches_review?
        remember_submission
        @review_signature = Operations::BulkChange.sign_review(@selection, params[:change], @ready)
        @revise_error = t("rails_ai_admin.bulk_changes.revise.confirm_changed")
        return render :show, status: :unprocessable_content
      end
      return execute_async_bulk_change(decision) if @async_mode
      Operations::BulkChange.decide!(@selection, decision)
      runner = Operations::Runner.new
      outcomes = @ready.map do |item|
        code = begin
          intent = runner.prepare(context: @context, resource: @resource, operation: :update, target_id: item.target.id,
            expected_version: item.target.expected_version, input: @proposal.values, origin: :assistant)
          runner.execute(context: @context, intent_ref: intent.id, input: @proposal.values, human_confirmed: true, origin: :assistant).code
        rescue AccessDenied => error
          error.code
        end
        [ item.target, code ]
      end
      @updated = outcomes.count { |_, code| code == "OK" }
      @not_updated = outcomes.reject { |_, code| code == "OK" } + @skipped.map { |item| [ item.target, item.code ] }
      reasons = @not_updated.map(&:last).tally.map { |code, count| "#{count} #{code}" }
      outcome = "#{@updated} of #{@items.size} records were updated." + (reasons.any? ? " Not updated: #{reasons.join(', ')}." : "")
      continue_chat("confirmed", outcome)
      render :result
    end

    private

    # The token names the selection, its manifest and the values. The
    # manifest must still match, so a record changed since the proposal
    # makes the whole review a conflict rather than a silent overwrite.
    def load_plan
      @proposal = Operations::BulkChange.decode(params[:change], context: @context)
      raise AccessDenied unless @proposal.selection_ref == params[:selection_ref]
      records = {}
      @selection = Selections::Builder.new.revalidate(context: @context, selection_ref: @proposal.selection_ref,
        manifest_digest: @proposal.manifest_digest, max_items: RailsAiAdmin.configuration.async_bulk_limit) { |record| records[record.id.to_s] = record }
      @resource = RailsAiAdmin.registry.fetch(@selection.resource_key)
      raise AccessDenied unless @resource.key.to_s == @proposal.resource_key && @resource.assistant_change?(:bulk_update)
      Operations::BulkChange.ensure_open!(@selection)
      @async_mode = Operations::BulkChange.large?(@selection)
      @items, shown = Operations::BulkChange.review_plan(context: @context, resource: @resource, selection: @selection,
        records: records, values: @proposal.values)
      @ready = @items.select { |item| item.code.nil? }
      @display_ready = shown.select { |item| item.code.nil? }
      @skipped = @items.reject { |item| item.code.nil? }
      @fields = @resource.fields.select { |field| @proposal.values.key?(field.name.to_s) }
      @chat_ref = @proposal.context_ref&.then { |value| value[/\Araa:chat:([0-9a-f-]{36})\z/, 1] }
    rescue KeyError
      raise AccessDenied
    end

    # More than 100 records run as one background collection job. The
    # preflight runs before the review is claimed, and a job that could not
    # be admitted gives the claim back, so a failure never consumes the review
    # without queuing anything. The claim (decide!) still comes before
    # admission so two tabs cannot queue the same review twice.
    def execute_async_bulk_change(decision)
      target_selection_ref = if @skipped.any?
        Selections::Builder.new.capture(context: @context, resource: @resource,
          target_ids: @ready.map { |item| item.target.id }, max_items: RailsAiAdmin.configuration.async_bulk_limit).selection_ref
      else
        @selection.selection_ref
      end
      runner = Collections::Runner.new
      proposed = runner.preflight(context: @context, resource: @resource, operation: :update,
        selection_ref: target_selection_ref, input: @proposal.values, origin: :assistant)
      return async_bulk_change_failed(proposed.code) if proposed.is_a?(Collections::Result)
      Operations::BulkChange.decide!(@selection, decision)
      admitted = runner.admit(context: @context, intent_ref: proposed.intent.id, input: proposed.values, human_confirmed: true)
      unless admitted.accepted?
        Operations::BulkChange.release!(@selection, decision)
        return async_bulk_change_failed(admitted.code)
      end
      continue_chat("confirmed", "Queued background update #{admitted.job_ref} for #{@ready.size} records.")
      redirect_to collection_job_path(job_ref: admitted.job_ref), status: :see_other,
        notice: t("rails_ai_admin.collection_operations.admitted")
    end

    def async_bulk_change_failed(code)
      @review_signature = Operations::BulkChange.sign_review(@selection, params[:change], @ready)
      @revise_error = helpers.admin_outcome(code)
      render :show, status: :conflict
    end

    # Dismissing never mutates domain records, so it stays allowed even if a
    # selected record changed version after the proposal was created.
    def load_dismiss_target
      @proposal = Operations::BulkChange.decode(params[:change], context: @context)
      raise AccessDenied unless @proposal.selection_ref == params[:selection_ref]
      row = Selection.find_by(id: @proposal.selection_ref, actor_ref: @context.actor_ref,
        tenant_ref: @context.tenant_ref, security_version: @context.security_version)
      raise AccessDenied unless row && row.id == @proposal.selection_ref && row.expires_at && row.expires_at > Time.current &&
        row.manifest_digest == @proposal.manifest_digest && row.resource_key == @proposal.resource_key
      @resource = RailsAiAdmin.registry.fetch(row.resource_key)
      raise AccessDenied unless @resource.assistant_change?(:bulk_update)
      @selection = Selections::Builder::Snapshot.new(row.id, row.resource_key, row.manifest_digest, row.expires_at, [].freeze)
      Operations::BulkChange.ensure_open!(@selection)
      @ready = Array.new(row.item_count)
      @fields = @resource.fields.select { |field| @proposal.values.key?(field.name.to_s) }
      @chat_ref = @proposal.context_ref&.then { |value| value[/\Araa:chat:([0-9a-f-]{36})\z/, 1] }
    rescue KeyError
      raise AccessDenied
    end

    # nil when the form did not send the rows (an override older than this
    # check); the empty marker field otherwise makes "none ticked" explicit.
    def submitted_target_ids
      return unless params.key?(:target_ids)
      Array(params[:target_ids]).select { |id| id.is_a?(String) && id.present? }.uniq
    end

    def submitted_values
      raw = params[:values]
      raw.is_a?(ActionController::Parameters) ? raw.to_unsafe_h : nil
    end

    def submission_matches_review?
      ids = submitted_target_ids
      return false unless ids.nil? || ids.sort == @ready.map { |item| item.target.id.to_s }.sort
      values = submitted_values
      return false unless params[:values].nil? || values
      return true if values.nil?
      return false unless values.keys.all? { |name| @proposal.values.key?(name) } && values.values.all?(String)
      schema = InputSchema.new(@fields, partial: true)
      expected = schema.coerce(@proposal.values, time_zone: @context.time_zone)
      actual = schema.coerce(@proposal.values.merge(values), time_zone: @context.time_zone)
      expected.valid? && actual.valid? && InputSchema.digest(actual.values) == InputSchema.digest(expected.values)
    end

    # Shown again as the person left them when the page is rendered again.
    def remember_submission
      @submitted_target_ids = submitted_target_ids
      values = submitted_values
      @submitted_values = values && @proposal.values.merge(values.slice(*@proposal.values.keys).select { |_, value| value.is_a?(String) })
    end

    def revised_input_values
      raw = params[:values]
      return @proposal.values if raw.nil?
      return nil unless raw.is_a?(ActionController::Parameters)
      submitted = raw.to_unsafe_h
      allowed_names = @proposal.values.keys
      return nil unless (submitted.keys - allowed_names).empty?
      merged = @proposal.values.merge(submitted.transform_values { |value| value.is_a?(String) ? value : value.to_s })
      access = Authorization::Access.new(@context, @resource)
      writable = access.fields(:write, nil, operation: :update).select { |field| allowed_names.include?(field.name.to_s) }
      return nil unless writable.size == allowed_names.size
      result = InputSchema.new(writable, partial: true).coerce(merged, time_zone: @context.time_zone)
      return nil unless result.valid?
      wire_proposal_values(result.values)
    end

    def wire_proposal_values(values)
      values.to_h do |name, value|
        wire = case value
        when BigDecimal then value.to_s("F")
        when Time, ActiveSupport::TimeWithZone then value.to_time.getutc.iso8601(6)
        when Date then value.iso8601
        else value
        end
        [ name.to_s, wire ]
      end
    end

    def return_path
      @chat_ref ? assistant_conversation_path(chat_ref: @chat_ref) : resources_path(resource: @resource.key)
    end
    helper_method :return_path

    # A server-written summary; admitted at most once per selection.
    def continue_chat(decision, outcome)
      return unless @chat_ref && RailsAiAdmin.configuration.assistant
      require "rails_ai_admin/assistant"
      label = @resource.label.downcase
      fields = @fields.map { |field| field.label.downcase }.join(", ")
      content = "Review result: the user #{decision} \"update #{fields} on #{@ready.size} #{label}\". #{outcome}"
      Assistant::Continuation.admit_outcome!(context: @context, context_ref: @proposal.context_ref,
        admission_key: "bulk:#{@selection.selection_ref}", content: content)
    end
  end
end
