# frozen_string_literal: true

class AdminAssistant
  def llm_context(context:)
    if ENV["RAA_DEMO_PROVIDER"] == "openrouter"
      key = ENV["OPENROUTER_API_KEY"]
      return if key.to_s.empty?

      RubyLLM.context do |config|
        config.openrouter_api_key = key
        config.request_timeout = 90
        config.max_retries = 1
      end
    else
      RubyLLM.context do |config|
        config.openai_api_key = "offline-demo"
        config.openai_api_base = "http://127.0.0.1:#{Integer(ENV.fetch('RAA_DEMO_PORT', '3917')) + 1}/v1"
        config.request_timeout = 5
        config.max_retries = 0
      end
    end
  end

  # Operator notes the model reads after the admin's own rules on each turn.
  def instructions(context:)
    <<~TEXT
      This is a demo store with sample data. An order's delivery_on is its promised delivery day; orders without one are not scheduled yet.
      Customers named "Bulk Customer" exist to try changes across many records at once.
    TEXT
  end
end
