# Host-owned provider settings for admin Chat, kept apart from the product's
# global RubyLLM configuration. Without a key the assistant stays unavailable.
class AdminAssistant
  def llm_context(context:)
    key = ENV["SUPPORT_ADMIN_OPENAI_KEY"]
    return if key.blank?
    RubyLLM.context do |config|
      config.openai_api_key = key
      # An OpenAI-compatible gateway, such as a loopback fixture in browser checks.
      config.openai_api_base = ENV["SUPPORT_ADMIN_OPENAI_BASE"] if ENV["SUPPORT_ADMIN_OPENAI_BASE"].present?
      config.max_retries = 0
      config.request_timeout = 30
    end
  end
end
