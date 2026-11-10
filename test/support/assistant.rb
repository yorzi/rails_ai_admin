# frozen_string_literal: true

require "support/application"
require "support/operations"
require "rails_ai_admin/assistant"
require "rails_ai_admin/integrations/tool_views"
require_relative "../../app/jobs/rails_ai_admin/assistant_turn_job"
require_relative "../../db/assistant_migrate/20261103000001_create_rails_ai_admin_assistant"

class AssistantPolicy < OperationContractPolicy
  class_attribute :exposed, default: true

  def assistant?(context:, resource:)
    !denied && exposed && resource.key == :contract_customers
  end
end

# Builds a provider context per admin Context. No global RubyLLM settings.
class TestAssistant
  class_attribute :available, default: true

  def llm_context(context:)
    return unless available
    RubyLLM.context do |config|
      config.openai_api_key = "test-only-key"
      config.max_retries = 0
      config.request_timeout = 5
    end
  end
end

# Scripted OpenAI chat-completions responses served through WebMock. The real
# RubyLLM provider, protocol parser, tool loop and persistence run offline.
module LLMFixture
  ENDPOINT = "https://api.openai.com/v1/chat/completions"

  class << self
    attr_reader :requests

    def reset!
      @script, @requests = [], []
    end

    def reply(text) = @script << { content: text }
    def tool(name, arguments, id: "call_#{SecureRandom.hex(8)}") = (@script << { tool: [ name, arguments, id ] }) && id
    def failure(status) = @script << { status: status }
    def pending = @script.size

    def respond(request)
      @requests << JSON.parse(request.body)
      step = @script.shift
      raise "LLMFixture script is empty" unless step
      return { status: step[:status], headers: { "Content-Type" => "application/json" }, body: { error: { message: "fixture failure" } }.to_json } if step[:status]
      message = if step[:tool]
        name, arguments, id = step[:tool]
        { role: "assistant", content: nil, tool_calls: [ { id: id, type: "function", function: { name: name, arguments: arguments.to_json } } ] }
      else
        { role: "assistant", content: step[:content] }
      end
      body = { id: "chatcmpl-#{SecureRandom.hex(4)}", object: "chat.completion", created: Time.now.to_i, model: "gpt-4.1-mini",
        choices: [ { index: 0, message: message, finish_reason: step[:tool] ? "tool_calls" : "stop" } ],
        usage: { prompt_tokens: 12, completion_tokens: 4, total_tokens: 16 } }
      { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json }
    end
  end
end

# Host product conversations that share RubyLLM's tool-call and usage tables.
class ProductChat < ActiveRecord::Base
  acts_as_chat messages: :product_messages, message_class: "ProductMessage", messages_foreign_key: :product_chat_id
end

class ProductMessage < ActiveRecord::Base
  acts_as_message chat: :product_chat, chat_class: "ProductChat", chat_foreign_key: :product_chat_id
end

module AssistantHelpers
  def self.prepare_schema
    ActiveRecord::Migration.verbose = false
    CreateRailsAiAdminAssistant.new.migrate(:up) unless ActiveRecord::Base.connection.table_exists?(:rails_ai_admin_assistant_turns)
    return if ActiveRecord::Base.connection.table_exists?(:product_messages)
    ActiveRecord::Schema.define do
      create_table :product_chats do |t|
        t.references :ruby_llm_model, foreign_key: { to_table: :ruby_llm_models }
        t.boolean :cancelled, null: false, default: false
        t.timestamps
      end
      create_table :product_messages do |t|
        t.references :product_chat, null: false, foreign_key: true
        t.string :role, null: false
        t.text :content
        t.boolean :cache_until_here, null: false, default: false
        t.string :cache_ttl
        t.timestamps
      end
    end
  end

  def reset_assistant
    RailsAiAdmin::Assistant::Turn.delete_all
    RubyLLM::ActiveRecord::Usage.delete_all
    RubyLLM::ActiveRecord::ToolCall.delete_all
    RailsAiAdmin::Assistant::Message.delete_all
    ProductMessage.delete_all
    RailsAiAdmin::Assistant::Chat.delete_all
    ProductChat.delete_all
    # One registry row avoids importing RubyLLM's whole model catalog.
    RubyLLM::ActiveRecord::Model.find_or_create_by!(model_id: "gpt-4.1-mini", provider: "openai") { |model| model.name = "GPT-4.1 mini" }
    [ RailsToolViews::AgentInteraction, RailsToolViews::ActionExecution, RailsToolViews::Presentation, RailsToolViews::Surface ].each(&:delete_all)
    AssistantPolicy.exposed = true
    TestAssistant.available = true
    LLMFixture.reset!
    stub_request(:post, LLMFixture::ENDPOINT).to_return { |request| LLMFixture.respond(request) }
  end

  def assistant_configuration(surfaces: true)
    config = RailsAiAdmin::Configuration.new
    config.context_adapter = "OperationJobContext"
    config.authorization_adapter = "AssistantPolicy"
    config.resources = %w[ContractCustomerAdmin ReadonlyContractAdmin]
    config.work_handlers = { "customers.reviewed" => "OperationContractWork", "customers.non_idempotent" => "NonIdempotentContractWork" }
    config.surfaces = surfaces
    config.assistant = true
    config.assistant_adapter = "TestAssistant"
    config.assistant_model = "gpt-4.1-mini"
    config.assistant_provider = "openai"
    config.assistant_protocol = "chat_completions"
    config
  end

  # Like with_operations, with one configuration stub (stubs do not nest).
  def with_assistant(surfaces: true, resources: nil)
    AssistantPolicy.denied = false
    AssistantPolicy.receipt_grant = AssistantPolicy.delivery_grant = AssistantPolicy.input_grant = true
    OperationJobContext.epoch = "1"
    ReviewContractOperation.work_kind = "customers.reviewed"
    OperationContractWork.transport = ->(_delivery, _input) { true }
    config = assistant_configuration(surfaces: surfaces)
    config.resources = resources if resources
    registry = RailsAiAdmin::Registry.new(config.resources)
    operations = RailsAiAdmin::Operations::Registry.new(registry.resources)
    work = RailsAiAdmin::Outbox::Registry.new(config.work_handlers)
    RailsAiAdmin.stub(:configuration, config) do
      RailsAiAdmin.stub(:registry, registry) do
        RailsAiAdmin.stub(:operation_registry, operations) do
          RailsAiAdmin.stub(:work_registry, work) { yield }
        end
      end
    end
  ensure
    OperationJobContext.epoch = "1"
  end

  def new_chat(actor: 1, version: "1")
    RailsAiAdmin::Assistant.create_chat!(context(actor: actor, version: version))
  end

  def admit(chat, text, key: "message:#{SecureRandom.uuid}")
    RailsAiAdmin::Assistant::Coordinator.admit!(chat, kind: "message", content: text, admission_key: key)
  end

  def drain(chat)
    RailsAiAdmin::Assistant::Coordinator.new.run(chat.ref)
  end

  def transcript(chat)
    chat.messages.reload.where.not(role: "system").order(:id).map { |message| [ message.role, message.content ] }
  end
end

AssistantHelpers.prepare_schema
