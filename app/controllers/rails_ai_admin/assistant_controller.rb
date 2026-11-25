# frozen_string_literal: true

module RailsAiAdmin
  # Admin Chat pages. A request only saves a message as an inbox turn and
  # enqueues work; no provider call runs in a web request. RubyLLM is loaded
  # inside actions only, so conventional hosts can eager-load this file.
  class AssistantController < ApplicationController
    RETRYABLE = %w[PROVIDER_UNAVAILABLE ASSISTANT_FAILED ATTEMPTS_EXHAUSTED AI_UNAVAILABLE].freeze
    FAILURES = {
      "AI_UNAVAILABLE" => "The assistant is not available right now. The rest of the administration works as usual.",
      "AI_REJECTED" => "The AI provider rejected this request. Try a shorter or different message.",
      "PROVIDER_UNAVAILABLE" => "The AI provider did not respond. Your message is saved; try again.",
      "ASSISTANT_FAILED" => "The assistant could not finish. Your message is saved; try again.",
      "ATTEMPTS_EXHAUSTED" => "The assistant stopped after several attempts. Your message is saved; try again.",
      "STEP_LIMIT" => "The assistant stopped before finishing this request. Try a narrower question.",
      "AUTHORIZATION_REVOKED" => "Your access changed, so this request was not answered.",
      "BUDGET_EXCEEDED" => "The assistant stopped because you reached today's assistant spending limit. Try again later.",
      "NOT_ALLOWED" => "No resources are available to the assistant for your account.",
      "CANCELLED" => "Stopped."
    }.freeze

    before_action :require_assistant
    before_action :load_chat, except: %i[index create drawer]
    around_action :bind_surface_context

    def index
      @chats = Assistant::Chat.for_owner(@context).order(updated_at: :desc, id: :desc).limit(50).to_a
    end

    # Contextual shell drawer view. Renders inside a Turbo Frame when opened
    # from another admin page; keeps all authority checks identical to show.
    def drawer
      @drawer = true
      if params[:chat_ref].present?
        @chat = Assistant::Chat.owned(@context, params[:chat_ref])
      end
      @chats = Assistant::Chat.for_owner(@context).where(status: "active").order(updated_at: :desc, id: :desc).limit(10).to_a unless @chat
      if @chat
        prepare_transcript
        @admission_key = "message:#{SecureRandom.uuid}"
      end
      render :drawer, layout: turbo_frame_request? ? "rails_ai_admin/frame" : "rails_ai_admin/application"
    end

    # A new chat; from a record, list, or selection page it starts with the
    # question and a server-verified "Context:" line naming that page.
    def create
      question = params[:content]
      raise AccessDenied, "INVALID_QUERY" unless question.nil? || question.is_a?(String) && question.valid_encoding?
      begin
        context_line = resolve_page_context_line
      rescue AccessDenied => error
        raise unless error.code == Assistant::PageContext::EXPIRED
        # No conversation is started; the question is offered again.
        return refuse_start(question)
      end
      @chat = Assistant.create_chat!(@context)
      if question.present?
        content = [ context_line, question.strip ].compact.join("\n\n").first(Assistant::Coordinator::MAX_CONTENT)
        begin
          Assistant::Coordinator.admit!(@chat, kind: "message", content: content, admission_key: "message:#{SecureRandom.uuid}")
        rescue AccessDenied => error
          raise unless REFUSALS.include?(error.code)
          # The new, empty conversation keeps the question for a later try.
          return refuse_message(error.code, question)
        end
      end
      redirect_to conversation_destination(@chat), status: :see_other
    rescue ::RubyLLM::ModelNotFoundError, ::RubyLLM::ModelRegistryError
      admin_status(:unavailable)
    end

    def show
      @drawer = drawer_request?
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
      key = params[:admission_key]
      raise AccessDenied, "INVALID_QUERY" unless key.is_a?(String) && key.start_with?("message:")
      question = params[:content]
      raise AccessDenied, "INVALID_QUERY" unless question.is_a?(String) && question.valid_encoding? &&
        question.strip.length.between?(1, Assistant::Coordinator::MAX_CONTENT)
      context_line = resolve_page_context_line
      content = context_line ? "#{context_line}\n\n#{question.strip}".first(Assistant::Coordinator::MAX_CONTENT) : question
      Assistant::Coordinator.admit!(@chat, kind: "message", content: content, admission_key: key)
      redirect_to conversation_destination(@chat), status: :see_other
    rescue AccessDenied => error
      raise unless error.code == "INVALID_QUERY" || REFUSALS.include?(error.code)
      refuse_message(error.code, params[:content])
    end

    # Stops waiting turns now and asks a running one to stop at its next
    # checkpoint. Committed business results are never undone.
    def cancel
      Assistant::Turn.transaction do
        Assistant::Chat.lock.find(@chat.id)
        @chat.turns.where(status: "queued").update_all(status: "cancelled", error_code: "CANCELLED", completed_at: Time.current, updated_at: Time.current)
        @chat.cancel if @chat.turns.where(status: "running").exists?
      end
      redirect_to conversation_destination(@chat), status: :see_other
    end

    # Requeues the latest failed turn. The saved human message is reused, so
    # retrying never repeats it in the conversation.
    def retry_turn
      return admin_status(:conflict) unless @chat.current_for?(@context)
      Assistant::Turn.transaction do
        Assistant::Chat.for_owner(@context).order(:id).lock.pluck(:id)
        locked = Assistant::Chat.lock.find(@chat.id)
        turn = locked.turns.reorder(sequence: :desc).first
        raise AccessDenied, "CONFLICT" unless turn&.status == "failed" && RETRYABLE.include?(turn.error_code)
        raise AccessDenied, "RATE_LIMITED" if Assistant::Coordinator.over_daily_limit?(locked)
        raise AccessDenied, "BUDGET_EXCEEDED" if Assistant::Budget.exceeded?(locked)
        turn.update!(status: "queued", attempts: 0, error_code: nil, next_attempt_at: nil, completed_at: nil)
      end
      Assistant::Coordinator.enqueue_after_commit(@chat.ref)
      redirect_to conversation_destination(@chat), status: :see_other
    rescue AccessDenied => error
      raise unless REFUSALS.include?(error.code)
      refuse_message(error.code, "")
    end

    def archive
      Assistant::Turn.transaction do
        locked = Assistant::Chat.lock.find(@chat.id)
        locked.update!(status: "archived")
        locked.turns.where(status: "queued").update_all(status: "cancelled", error_code: "CHAT_CLOSED", completed_at: Time.current, updated_at: Time.current)
        locked.cancel if locked.turns.where(status: "running").exists?
      end
      redirect_to assistant_path, status: :see_other, notice: t("rails_ai_admin.assistant.archived")
    end

    private

    # Admission refusals shown on the conversation page with the text kept.
    # CONTEXT_EXPIRED is Assistant::PageContext::EXPIRED, written out because
    # hosts without the assistant still load this class when eager loading.
    REFUSALS = %w[RATE_LIMITED BUDGET_EXCEEDED CONTEXT_EXPIRED].freeze

    def drawer_request?
      params[:drawer] == "1"
    end

    def conversation_destination(chat)
      drawer_request? ? assistant_drawer_path(chat_ref: chat.ref) : assistant_conversation_path(chat_ref: chat.ref)
    end

    def refuse_message(code, content)
      @drawer = drawer_request?
      prepare_transcript
      @admission_key = params[:admission_key].is_a?(String) && params[:admission_key].match?(Assistant::Coordinator::ADMISSION_KEY) ? params[:admission_key] : "message:#{SecureRandom.uuid}"
      @draft = content.is_a?(String) ? content.first(Assistant::Coordinator::MAX_CONTENT + 1) : ""
      template = @drawer ? :drawer : :show
      layout = @drawer && turbo_frame_request? ? "rails_ai_admin/frame" : "rails_ai_admin/application"
      case code
      when "RATE_LIMITED"
        @message_error = t("rails_ai_admin.assistant.rate_limited", count: RailsAiAdmin.configuration.assistant_daily_message_limit)
        render template, layout: layout, status: :too_many_requests
      when "BUDGET_EXCEEDED"
        @message_error = t("rails_ai_admin.assistant.budget_exceeded")
        render template, layout: layout, status: :too_many_requests
      when Assistant::PageContext::EXPIRED
        @context_expired = true
        @message_error = t("rails_ai_admin.assistant.context_expired")
        render template, layout: layout, status: :unprocessable_content
      else
        @message_error = t("rails_ai_admin.assistant.invalid_message", count: Assistant::Coordinator::MAX_CONTENT)
        render template, layout: layout, status: :unprocessable_content
      end
    end

    # The drawer's start form again, with the question kept, when its page
    # context lapsed before a conversation was started.
    def refuse_start(question)
      @drawer = drawer_request?
      @context_expired = true
      @message_error = t("rails_ai_admin.assistant.context_expired")
      @draft = question.is_a?(String) ? question.first(Assistant::Coordinator::MAX_CONTENT + 1) : ""
      @chats = Assistant::Chat.for_owner(@context).where(status: "active").order(updated_at: :desc, id: :desc).limit(10).to_a
      layout = @drawer && turbo_frame_request? ? "rails_ai_admin/frame" : "rails_ai_admin/application"
      render :drawer, layout: layout, status: :unprocessable_content
    end

    # When a signed page_context token is supplied, it MUST verify cleanly
    # (failing closed on tamper, expiry, foreign tenant, or revoked grant).
    # Falls back to the legacy about[...] fields only when no token is passed.
    def resolve_page_context_line
      token = params[:page_context]
      if token.present?
        return Assistant::PageContext.resolve!(context: @context, token: token).summary
      end
      page_context_line
    end

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
        query = about[:q].is_a?(String) && about[:q].valid_encoding? ? about[:q].strip.first(100) : nil
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
      running = @pending ? @chat.turns.where(status: "running").reorder(:sequence).first : nil
      @running = !running.nil?
      # The reply being written, shown only under the chat's current authority.
      @streaming_text = running&.draft.presence
      retrying = @pending && @chat.turns.where(status: "queued").where.not(error_code: nil).reorder(:sequence).first
      @retry_status = t("rails_ai_admin.assistant.retrying", attempt: retrying.attempts + 1, attempts: Assistant::Coordinator::MAX_ATTEMPTS) if retrying
      @failure = last if last&.status == "failed" || last&.status == "cancelled"
      code = @failure && (FAILURES.key?(@failure.error_code.to_s) ? @failure.error_code.to_s : "ASSISTANT_FAILED")
      @failure_message = code && t(code.downcase, scope: %i[rails_ai_admin assistant failures], default: FAILURES.fetch(code))
      @retryable = @current && @failure&.status == "failed" && RETRYABLE.include?(@failure.error_code)
      @surface_scope = Integrations::ToolViews.scope_for(@context) if RailsAiAdmin.configuration.surfaces
      @spend = Assistant::Budget.spend(actor_ref: @chat.actor_ref, tenant_ref: @chat.tenant_ref) if @current && Assistant::Budget.limited?
    end
  end
end
