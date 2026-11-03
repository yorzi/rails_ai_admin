# frozen_string_literal: true

module RailsAiAdmin
  module Assistant
    # An admin conversation. It belongs to one actor, tenant and security
    # version; a host security change closes it instead of carrying old tool
    # output into a new authority. It never shares rows with host product chats.
    class Chat < ::ActiveRecord::Base
      self.table_name = "rails_ai_admin_assistant_chats"
      STATUSES = %w[active archived].freeze

      # Declared before acts_as_chat so turns go before the messages they cite.
      has_many :turns, -> { order(:sequence) }, class_name: "RailsAiAdmin::Assistant::Turn", foreign_key: :chat_id,
        inverse_of: :chat, dependent: :delete_all
      acts_as_chat messages: :messages, message_class: "RailsAiAdmin::Assistant::Message", messages_foreign_key: :chat_id

      validates :ref, :actor_ref, :tenant_ref, :security_version, presence: true
      validates :status, inclusion: { in: STATUSES }

      # Byte-exact owner lookup; a non-binary collation cannot widen it.
      def self.owned(context, ref)
        return unless ref.is_a?(String) && ref.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
        chat = find_by(ref: ref, actor_ref: context.actor_ref, tenant_ref: context.tenant_ref)
        chat if chat && chat.ref == ref && chat.actor_ref == context.actor_ref && chat.tenant_ref == context.tenant_ref
      end

      def self.for_owner(context)
        where(actor_ref: context.actor_ref, tenant_ref: context.tenant_ref)
      end

      def current_for?(context)
        status == "active" && security_version == context.security_version
      end

      def context_reference = "raa:chat:#{ref}"
    end

    # Persisted RubyLLM message. Tool calls and usages are reached only through
    # this class's own polymorphic associations, never by table-wide queries.
    class Message < ::ActiveRecord::Base
      self.table_name = "rails_ai_admin_assistant_messages"
      acts_as_message chat: :chat, chat_class: "RailsAiAdmin::Assistant::Chat", chat_foreign_key: :chat_id
    end

    # A unit of inbox work: one human message or one Surface continuation.
    class Turn < ::ActiveRecord::Base
      self.table_name = "rails_ai_admin_assistant_turns"
      self.filter_attributes += %i[content]
      KINDS = %w[message continuation].freeze
      STATUSES = %w[queued running completed failed cancelled].freeze
      ACTIVE = %w[queued running].freeze

      belongs_to :chat, class_name: "RailsAiAdmin::Assistant::Chat", inverse_of: :turns
      belongs_to :user_message, class_name: "RailsAiAdmin::Assistant::Message", optional: true

      validates :kind, inclusion: { in: KINDS }
      validates :status, inclusion: { in: STATUSES }
      validates :admission_key, :content, presence: true

      def active? = ACTIVE.include?(status)
    end
  end
end
