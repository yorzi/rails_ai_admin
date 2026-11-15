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
    end

    def create
      load_plan
      decision = params[:decision] == "dismiss" ? "dismissed" : "confirmed"
      if decision == "dismissed"
        continue_chat("dismissed", "Nothing was changed.")
        return redirect_to(return_path, status: :see_other, notice: t("rails_ai_admin.bulk_changes.dismissed"))
      end
      raise AccessDenied if @ready.empty?
      runner = Operations::Runner.new
      @outcomes = @ready.map do |item|
        code = begin
          intent = runner.prepare(context: @context, resource: @resource, operation: :update, target_id: item.target.id,
            expected_version: item.target.expected_version, input: @proposal.values, origin: :assistant)
          runner.execute(context: @context, intent_ref: intent.id, input: @proposal.values, human_confirmed: true, origin: :assistant).code
        rescue AccessDenied => error
          error.code
        end
        [ item.target, code ]
      end
      @updated = @outcomes.count { |_, code| code == "OK" }
      @failed = @outcomes.reject { |_, code| code == "OK" }
      not_updated = @failed.map(&:last).tally.map { |code, count| "#{count} #{code}" }
      outcome = "#{@updated} of #{@outcomes.size} records were updated." + (not_updated.any? ? " Not updated: #{not_updated.join(', ')}." : "")
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
        manifest_digest: @proposal.manifest_digest) { |record| records[record.id.to_s] = record }
      @resource = RailsAiAdmin.registry.fetch(@selection.resource_key)
      raise AccessDenied unless @resource.key.to_s == @proposal.resource_key && @resource.assistant_change?(:bulk_update)
      @items = Operations::BulkChange.plan(context: @context, resource: @resource, selection: @selection, records: records, values: @proposal.values)
      @ready = @items.select { |item| item.code.nil? }
      @skipped = @items.reject { |item| item.code.nil? }
      @fields = @resource.fields.select { |field| @proposal.values.key?(field.name.to_s) }
      @chat_ref = @proposal.context_ref&.then { |value| value[/\Araa:chat:([0-9a-f-]{36})\z/, 1] }
    rescue KeyError
      raise AccessDenied
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
