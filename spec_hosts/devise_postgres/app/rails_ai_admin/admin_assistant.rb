# Host-owned provider settings for admin Chat, kept apart from the product's
# global RubyLLM configuration. Without a key the assistant stays unavailable.
class AdminAssistant
  def llm_context(context:)
    key = ENV["SUPPORT_ADMIN_OPENAI_KEY"]
    return if key.blank?
    RubyLLM.context do |config|
      config.openai_api_key = key
      config.max_retries = 0
      config.request_timeout = 30
    end
  end
end
