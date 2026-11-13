# frozen_string_literal: true

module RailsAiAdmin
  # Admin Chat pages. A request only saves a message as an inbox turn and
  # enqueues work; no provider call runs in a web request. RubyLLM is loaded
  # inside actions only, so conventional hosts can eager-load this file.
  class AssistantController < ApplicationController
    RETRYABLE = %w[PROVIDER_UNAVAILABLE ASSISTANT_FAILED ATTEMPTS_EXHAUSTED AI_UNAVAILABLE STEP_LIMIT].freeze
    FAILURES = {
      "AI_UNAVAILABLE" => "The assistant is not available right now. The rest of the administration works as usual.",
      "AI_REJECTED" => "The AI provider rejected this request. Try a shorter or different message.",
      "PROVIDER_UNAVAILABLE" => "The AI provider did not respond. Your message is saved; try again.",
      "ASSISTANT_FAILED" => "The assistant could not finish. Your message is saved; try again.",
      "ATTEMPTS_EXHAUSTED" => "The assistant stopped after several attempts. Your message is saved; try again.",
      "STEP_LIMIT" => "The assistant stopped before finishing this request. Try a narrower question.",
      "AUTHORIZATION_REVOKED" => "Your access changed, so this request was not answered.",
      "NOT_ALLOWED" => "No resources are available to the assistant for your account.",
      "CANCELLED" => "Stopped."
    }.freeze

    before_action :require_assistant
    before_action :load_chat, except: %i[index create]
    around_action :bind_surface_context

    def index
      @chats = Assistant::Chat.for_owner(@context).order(updated_at: :desc, id: :desc).limit(50).to_a
    end

    # A new chat; from a record or list page it starts with the question and a
    # server-written "Context:" line naming that page.
    def create
      question = params[:content]
      raise AccessDenied, "INVALID_QUERY" unless question.nil? || question.is_a?(String)
      chat = Assistant.create_chat!(@context)
      if question.present?
        content = [ page_context_line, question.strip ].compact.join("\n\n").first(Assistant::Coordinator::MAX_CONTENT)
        Assistant::Coordinator.admit!(chat, kind: "message", content: content, admission_key: "message:#{SecureRandom.uuid}")
      end
      redirect_to assistant_conversation_path(chat_ref: chat.ref), status: :see_other
    rescue ::RubyLLM::ModelNotFoundError, ::RubyLLM::ModelRegistryError
      admin_status(:unavailable)
    end

    def show
      prepare_transcript
      if turbo_frame_request?
        # A complete standards-mode document; Turbo extracts the matching frame.
        render :frame, layout: "rails_ai_admin/frame"
      else
        @admission_key = "message:#{SecureRandom.uuid}"
      end
    end

    def message
      return admin_status(:conflict) unless @chat.current_for?(@context)
      Assistant::Coordinator.admit!(@chat, kind: "message", content: params[:content], admission_key: params[:admission_key])
      redirect_to assistant_conversation_path(chat_ref: @chat.ref), status: :see_other
    rescue AccessDenied => error
      raise unless %w[INVALID_QUERY RATE_LIMITED].include?(error.code)
      prepare_transcript
      @admission_key = params[:admission_key].is_a?(String) && params[:admission_key].match?(Assistant::Coordinator::ADMISSION_KEY) ? params[:admission_key] : "message:#{SecureRandom.uuid}"
      @draft = params[:content].is_a?(String) ? params[:content].first(Assistant::Coordinator::MAX_CONTENT + 1) : ""
      if error.code == "RATE_LIMITED"
        @message_error = t("rails_ai_admin.assistant.rate_limited", count: RailsAiAdmin.configuration.assistant_daily_message_limit)
        return render :show, status: :too_many_requests
      end
      @message_error = t("rails_ai_admin.assistant.invalid_message", count: Assistant::Coordinator::MAX_CONTENT)
      render :show, status: :unprocessable_content
    end

    # Stops waiting turns now and asks a running one to stop at its next
    # checkpoint. Committed business results are never undone.
    def cancel
      Assistant::Turn.transaction do
        Assistant::Chat.lock.find(@chat.id)
        @chat.turns.where(status: "queued").update_all(status: "cancelled", error_code: "CANCELLED", completed_at: Time.current, updated_at: Time.current)
        @chat.cancel if @chat.turns.where(status: "running").exists?
      end
      redirect_to assistant_conversation_path(chat_ref: @chat.ref), status: :see_other
    end

    # Requeues the latest failed turn. The saved human message is reused, so
    # retrying never repeats it in the conversation.
    def retry_turn
      return admin_status(:conflict) unless @chat.current_for?(@context)
      Assistant::Turn.transaction do
        Assistant::Chat.lock.find(@chat.id)
        turn = @chat.turns.reorder(sequence: :desc).first
        raise AccessDenied, "CONFLICT" unless turn&.status == "failed" && RETRYABLE.include?(turn.error_code)
        turn.update!(status: "queued", attempts: 0, error_code: nil, next_attempt_at: nil, completed_at: nil)
      end
      Assistant::Coordinator.enqueue_after_commit(@chat.ref)
      redirect_to assistant_conversation_path(chat_ref: @chat.ref), status: :see_other
    end

    def archive
      @chat.update!(status: "archived")
      redirect_to assistant_path, status: :see_other, notice: t("rails_ai_admin.assistant.archived")
    end

    private

    # Names the page only when the actor may show it to the assistant now. The
    # line is data for the model and grants nothing; tools check again.
    def page_context_line
      about = params[:about]
      return unless about.is_a?(ActionController::Parameters)
      resource = RailsAiAdmin.registry.fetch(about[:resource].to_s)
      access = Authorization::Access.new(@context, resource)
      access.authorize_assistant!
      id = about[:id]
      if id.is_a?(String) && id.present?
        raise AccessDenied unless access.canonical_id?(id)
        record = access.find!(id)
        "Context: I am looking at #{resource.label.singularize} #{record.id} (\"#{access.record_label(record).truncate(120)}\") in the #{resource.key} resource."
      else
        query = about[:q].is_a?(String) ? about[:q].strip.first(100) : nil
        scope = about[:scope].is_a?(String) ? access.named_scopes.find { |definition| definition.name.to_s == about[:scope] } : nil
        details = [ (query.present? ? "searching for \"#{query}\"" : nil), (scope ? "on the #{scope.label} tab (scope #{scope.name})" : nil) ].compact
        "Context: I am looking at the #{resource.label} list (the #{resource.key} resource)#{details.any? ? ", #{details.join(', ')}" : ''}."
      end
    rescue AccessDenied, ConfigurationError, KeyError
      nil
    end

    def require_assistant
      raise AccessDenied unless RailsAiAdmin.configuration.assistant
      require "rails_ai_admin/assistant"
      raise AccessDenied unless Assistant.available?(@context)
    end

    def load_chat
      @chat = Assistant::Chat.owned(@context, params[:chat_ref]) || raise(AccessDenied)
    end

    # Surfaces in a conversation render through the admin-bound context.
    def bind_surface_context(&block)
      return yield unless RailsAiAdmin.configuration.surfaces
      require "rails_ai_admin/integrations/tool_views"
      Integrations::ToolViews.ensure_registered!
      Integrations::ToolViews.with_context(@context, &block)
    end

    # A security change closes the chat: its transcript, including old tool
    # output, is no longer shown under the new authority.
    def prepare_transcript
      @current = @chat.current_for?(@context)
      @entries = @current ? Assistant::Transcript.new(@context, @chat).entries : []
      last = @chat.turns.reorder(sequence: :desc).first
      @pending = @current && @chat.turns.where(status: Assistant::Turn::ACTIVE).exists?
      @running = @pending && @chat.turns.where(status: "running").exists?
      retrying = @pending && @chat.turns.where(status: "queued").where.not(error_code: nil).reorder(:sequence).first
      @retry_status = t("rails_ai_admin.assistant.retrying", attempt: retrying.attempts + 1, attempts: Assistant::Coordinator::MAX_ATTEMPTS) if retrying
      @failure = last if last&.status == "failed" || last&.status == "cancelled"
      code = @failure && (FAILURES.key?(@failure.error_code.to_s) ? @failure.error_code.to_s : "ASSISTANT_FAILED")
      @failure_message = code && t(code.downcase, scope: %i[rails_ai_admin assistant failures], default: FAILURES.fetch(code))
      @retryable = @current && @failure&.status == "failed" && RETRYABLE.include?(@failure.error_code)
      @surface_scope = Integrations::ToolViews.scope_for(@context) if RailsAiAdmin.configuration.surfaces
    end
  end
end
