# Builds the admin assistant's provider configuration for one admin Context.
# Returning nil keeps the assistant unavailable for that actor; this is the
# default. Read credentials from your secret store and never change global
# RubyLLM settings here: the admin's provider settings stay separate from your
# product's.
class AdminAssistant
  def llm_context(context:)
    nil
    # key = Rails.application.credentials.dig(:admin_assistant, :openai_api_key)
    # return unless key
    #
    # RubyLLM.context do |config|
    #   config.openai_api_key = key
    #   config.request_timeout = 60
    #   config.max_retries = 1
    # end
  end
end
