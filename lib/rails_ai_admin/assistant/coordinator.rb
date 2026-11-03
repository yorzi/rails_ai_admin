# frozen_string_literal: true

require "securerandom"

module RailsAiAdmin
  module Assistant
    # Persistent per-chat inbox (plan §6.8, SPIKE-03). Web requests and Surface
    # confirmations only admit a turn by key; workers claim the lowest active
    # turn under a lease with a fencing generation and run RubyLLM outside any
    # transaction. The human message is persisted once per turn, so a retried
    # worker continues the same conversation instead of repeating it. Provider
    # calls can still repeat (and bill) after a crash; business writes never
    # happen here, only through a human-confirmed Surface.
    class Coordinator
      LEASE = 5.minutes
      MAX_ATTEMPTS = 3
      MAX_STEPS = 12
      MAX_CONTENT = 4_000
      ADMISSION_KEY = /\A[a-z]{1,16}:[A-Za-z0-9-]{1,64}\z/
      # Provider-side failures that a later attempt may recover from.
      RETRYABLE = [ ::RubyLLM::Error, ::Faraday::Error, ::Timeout::Error, ::Errno::ETIMEDOUT ].freeze

      Claim = ::Data.define(:turn_id, :chat_id, :owner, :generation)
      Fenced = Class.new(StandardError)
      StepLimit = Class.new(StandardError)

      # Admits one turn per (chat, key); a repeated key returns the first turn.
      # Safe inside a caller transaction (Surface confirmation) and outside one.
      def self.admit!(chat, kind:, content:, admission_key:)
        raise ArgumentError, "Unknown turn kind" unless Turn::KINDS.include?(kind)
        raise AccessDenied, "INVALID_QUERY" unless admission_key.is_a?(String) && admission_key.match?(ADMISSION_KEY)
        text = content.is_a?(String) ? content.strip : ""
        raise AccessDenied, "INVALID_QUERY" unless text.valid_encoding? && text.length.between?(1, MAX_CONTENT)
        turn = Turn.transaction(requires_new: true) do
          locked = Chat.lock.find(chat.id)
          raise AccessDenied, "CHAT_CLOSED" unless locked.status == "active"
          existing = Turn.find_by(chat_id: locked.id, admission_key: admission_key)
          next existing if existing && existing.admission_key == admission_key
          sequence = Turn.where(chat_id: locked.id).maximum(:sequence).to_i + 1
          created = Turn.create!(id: SecureRandom.uuid, chat_id: locked.id, sequence: sequence, kind: kind,
            admission_key: admission_key, content: text, status: "queued")
          locked.touch
          created
        end
        enqueue_after_commit(chat.ref)
        turn
      end

      # Workers are an accelerator; a recurring scan recovers lost jobs.
      def self.enqueue_after_commit(ref)
        ::ActiveRecord.after_all_transactions_commit { AssistantTurnJob.perform_later(ref) }
      end

      # Enqueues chats with due queued turns or expired leases.
      def scan_pending!(limit: 100, inline: false)
        raise ArgumentError, "limit must be between 1 and 1000" unless limit.is_a?(Integer) && (1..1000).cover?(limit)
        now = Time.current
        queued = Turn.where(status: "queued").where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
        stale = Turn.where(status: "running").where("lease_expires_at IS NULL OR lease_expires_at <= ?", now)
        chat_ids = queued.or(stale).distinct.limit(limit).pluck(:chat_id)
        Chat.where(id: chat_ids).pluck(:ref).count do |ref|
          inline ? (run(ref); true) : !!AssistantTurnJob.perform_later(ref)
        end
      end

      # Runs due turns of one chat in sequence until none is claimable.
      def run(ref, limit: 10)
        raise ConfigurationError, "Assistant turns cannot run inside a transaction" if Turn.connection.transaction_open?
        limit.times do
          claim = claim_next(ref)
          break unless claim
          execute(claim)
        end
      end

      # Claims the lowest active turn only; later turns never overtake it.
      def claim_next(ref)
        Turn.transaction(requires_new: true) do
          chat = Chat.lock.find_by(ref: ref)
          next unless chat && chat.ref == ref
          now = Time.current
          loop do
            turn = Turn.where(chat_id: chat.id, status: Turn::ACTIVE).order(:sequence).lock.first
            break unless turn
            break if turn.status == "running" && turn.lease_expires_at && turn.lease_expires_at > now
            break if turn.status == "queued" && turn.next_attempt_at && turn.next_attempt_at > now
            if chat.status != "active"
              turn.update!(status: "cancelled", error_code: "CHAT_CLOSED", completed_at: now)
              next
            end
            if turn.attempts >= MAX_ATTEMPTS
              turn.update!(status: "failed", error_code: turn.error_code || "ATTEMPTS_EXHAUSTED", completed_at: now)
              next
            end
            # A cancel request belongs to the turn that was running then.
            chat.update_columns(cancelled: false) if chat.cancelled
            turn.update!(status: "running", lease_owner: SecureRandom.uuid, generation: turn.generation + 1,
              attempts: turn.attempts + 1, lease_expires_at: now + LEASE, next_attempt_at: nil)
            break Claim.new(turn.id, chat.id, turn.lease_owner, turn.generation)
          end
        end
      end

      def execute(claim)
        chat = Chat.find(claim.chat_id)
        turn = Turn.find(claim.turn_id)
        context = resolve_context(chat)
        return finish(claim, "failed", "AUTHORIZATION_REVOKED") unless context
        session = Session.new(context: context, chat: chat, fence: -> { renew!(claim) })
        return finish(claim, "failed", "NOT_ALLOWED") if session.resources.empty?
        llm = Assistant.llm_context(context)
        return finish(claim, "failed", "AI_UNAVAILABLE") unless llm
        admit_message!(claim, chat, turn)
        Runtime.configure(chat, session, llm)
        steps = 0
        ::RubyLLM.with_usage_owner(chat) do
          loop do
            renew!(claim)
            break if chat.complete?
            raise ConfigurationError, "Assistant tools must not wait for approval" if chat.waiting?
            raise StepLimit if (steps += 1) > MAX_STEPS
            chat.step
          end
        end
        finish(claim, "completed")
      rescue Fenced
        nil
      rescue StepLimit
        finish(claim, "failed", "STEP_LIMIT")
      rescue ::RubyLLM::CancelledError
        finish(claim, "cancelled", "CANCELLED")
      rescue ::RubyLLM::ConfigurationError, ::RubyLLM::ModelNotFoundError, ::RubyLLM::UnauthorizedError,
          ::RubyLLM::ForbiddenError, ::RubyLLM::PaymentRequiredError
        finish(claim, "failed", "AI_UNAVAILABLE")
      rescue ::RubyLLM::BadRequestError, ::RubyLLM::ContextLengthExceededError, ::RubyLLM::ContentFilterError
        finish(claim, "failed", "AI_REJECTED")
      rescue *RETRYABLE
        retry_later(claim, "PROVIDER_UNAVAILABLE")
      rescue StandardError => error
        Rails.error.report(error, handled: true, severity: :error, context: { turn_id: claim.turn_id }, source: "rails_ai_admin")
        retry_later(claim, "ASSISTANT_FAILED")
      end

      # Extends a live lease or stops the worker. Called before each provider
      # step and each tool call, so a fenced worker cannot start either.
      def renew!(claim)
        updated = Turn.where(id: claim.turn_id, status: "running", lease_owner: claim.owner, generation: claim.generation)
          .where("lease_expires_at > ?", Time.current).update_all(lease_expires_at: Time.current + LEASE, updated_at: Time.current)
        raise Fenced unless updated == 1
      end

      private

      # The human message is persisted once per turn, atomically with the turn.
      def admit_message!(claim, chat, turn)
        Turn.transaction(requires_new: true) do
          locked = Turn.lock.find(turn.id)
          raise Fenced unless locked.status == "running" && locked.lease_owner == claim.owner && locked.generation == claim.generation
          next if locked.user_message_id
          message = chat.add_message(role: :user, content: locked.content)
          locked.update!(user_message_id: message.id)
        end
      end

      # Fresh host authority for the chat owner; read-only like other jobs.
      def resolve_context(chat)
        ::ActiveRecord::Base.while_preventing_writes do
          adapter = RailsAiAdmin.configuration.context_adapter&.constantize&.new
          return nil unless adapter.respond_to?(:resolve_job)
          current = adapter.resolve_job(actor_ref: chat.actor_ref, tenant_ref: chat.tenant_ref, security_version: chat.security_version)
          current if current.is_a?(Context) && current.actor_ref == chat.actor_ref && current.tenant_ref == chat.tenant_ref &&
            current.security_version == chat.security_version
        end
      rescue AccessDenied
        nil
      rescue ::ActiveRecord::ReadOnlyError
        raise ConfigurationError, "Job context resolution must be read-only", cause: nil
      end

      def finish(claim, status, code = nil)
        fenced_update(claim, status: status, error_code: code, completed_at: Time.current, lease_owner: nil, lease_expires_at: nil)
      end

      def retry_later(claim, code)
        turn = Turn.find(claim.turn_id)
        return finish(claim, "failed", code) if turn.attempts >= MAX_ATTEMPTS
        fenced_update(claim, status: "queued", error_code: code, next_attempt_at: Time.current + (2**turn.attempts).seconds,
          lease_owner: nil, lease_expires_at: nil)
      end

      # An acknowledgment belongs only to the attempt that holds the lease.
      def fenced_update(claim, **attributes)
        Turn.where(id: claim.turn_id, status: "running", lease_owner: claim.owner, generation: claim.generation)
          .update_all(**attributes, updated_at: Time.current) == 1
      end
    end
  end
end
