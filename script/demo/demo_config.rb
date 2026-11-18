# frozen_string_literal: true

RailsAiAdmin.configure do |config|
  config.title = "Rails AI Admin"
  config.environment_label = "Demo"
  config.field_types = { trimmed_text: "TrimmedTextField" }
  config.authentication_path = "/login"
  config.context_adapter = "AdminContext"
  config.authorization_adapter = "AdminPolicyAdapter"
  config.actor_label = :email
  config.sign_out_path = "/logout"
  config.resources = [ "ArticleAdmin", "TagAdmin", "SummaryAdmin", "CustomerAdmin", "OrderAdmin" ]
  config.collection_auto_dispatch = true
  config.surfaces = true
  config.assistant = true
  config.mcp = true
  config.assistant_adapter = "AdminAssistant"
  if ENV["RAA_DEMO_PROVIDER"] == "openrouter"
    config.assistant_model = ENV.fetch("RAA_DEMO_MODEL", "openai/gpt-6-luna")
    config.assistant_provider = "openrouter"
    config.assistant_daily_cost_limit = 0.25 # US dollars
  else
    config.assistant_model = "gpt-4.1-mini"
    config.assistant_provider = "openai"
    config.assistant_protocol = "chat_completions"
  end
  config.assistant_daily_token_limit = 500_000
  config.assistant_retention = 30.days
end
