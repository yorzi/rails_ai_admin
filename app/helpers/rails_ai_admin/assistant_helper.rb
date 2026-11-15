# frozen_string_literal: true

module RailsAiAdmin
  # Conversation page text that needs formatting beyond a translation.
  module AssistantHelper
    # "Used in the last 24 hours: 1,200 of 200,000 tokens · US$0.0120 of US$1.00."
    def assistant_spend_text(spend)
      parts = []
      if spend.token_limit
        parts << t("rails_ai_admin.assistant.spend.tokens", used: number_with_delimiter(spend.tokens), limit: number_with_delimiter(spend.token_limit))
      end
      if spend.cost_limit
        parts << t("rails_ai_admin.assistant.spend.cost", used: assistant_dollars(spend.cost), limit: assistant_dollars(spend.cost_limit))
      end
      text = t("rails_ai_admin.assistant.spend.used", amounts: parts.join(" · "))
      text = "#{text} #{t('rails_ai_admin.assistant.spend.unpriced', count: spend.unpriced)}" if spend.cost_limit && spend.unpriced.positive?
      text
    end

    # Small amounts keep four decimals so a few requests do not read as zero.
    def assistant_dollars(amount)
      precision = amount.zero? || amount >= 1 ? 2 : 4
      "US$#{number_with_precision(amount, precision: precision, delimiter: ',')}"
    end
  end
end
