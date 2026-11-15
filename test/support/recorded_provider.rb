# frozen_string_literal: true

require "vcr"
require "support/assistant_eval"

# Real OpenRouter conversations, recorded once and replayed offline.
#
# The tests in test/contract/openrouter_recorded_test.rb and the recorded
# evaluation in test/contract/assistant_eval_recorded_test.rb run the real
# admin tools, grants, persistence and RubyLLM's OpenRouter provider against
# HTTP interactions stored in test/cassettes/openrouter. Replay needs no key
# and no network; every replayed request must have the recorded shape (model,
# streaming, tool names, message roles and the person's own text), so a
# changed tool list or question fails instead of replaying a stale answer.
#
# Record again after changing the prompt, the tools or a question (this calls
# real models and costs a few cents; the key comes only from the environment):
#
#   set -a; . ./.env.openrouter; set +a      # OPENROUTER_API_KEY=...
#   RAA_RECORD=1 bundle exec ruby -Itest test/contract/openrouter_recorded_test.rb
#   RAA_RECORD=1 bundle exec ruby -Itest test/contract/assistant_eval_recorded_test.rb
#
# Recording rewrites the cassettes it uses and test/cassettes/openrouter/manifest.json.
# After changing only the grader in test/support/assistant_eval.rb or an expect
# block, re-grade the recorded answers offline instead:
#
#   RAA_REGRADE=1 bundle exec ruby -Itest test/contract/assistant_eval_recorded_test.rb
module RecordedProvider
  CASSETTES = File.expand_path("../cassettes", __dir__)
  MANIFEST = File.join(CASSETTES, "openrouter", "manifest.json")
  HOST = "openrouter.ai"
  RECORD = ENV["RAA_RECORD"] == "1"
  # Re-grades the recorded evaluation after a grader change, offline: the
  # manifest's failures are rewritten from the replay; nothing is requested.
  REGRADE = ENV["RAA_REGRADE"] == "1" && !RECORD
  # The primary model runs every scenario; the others run the review flow, so
  # one OpenAI, one Anthropic and one Google model are recorded.
  PRIMARY = "openai/gpt-6-luna"
  MODELS = [ PRIMARY, "anthropic/claude-haiku-5.5", "google/gemini-3.8-flash" ].freeze

  # The parts of a chat request that must match the recording. Tool results
  # and the system prompt are left out: they carry ids and timestamps, and
  # the manifest pins the prompt version instead.
  def self.shape(request)
    body = JSON.parse(request.body.to_s)
    messages = Array(body["messages"])
    text = ->(content) { content.is_a?(Array) ? content.filter_map { |part| part["text"] if part.is_a?(Hash) }.join : content.to_s }
    { "model" => body["model"], "stream" => body["stream"] == true,
      "tools" => Array(body["tools"]).map { |tool| tool.dig("function", "name") }.sort,
      "roles" => messages.map { |message| message["role"] },
      "user" => messages.select { |message| message["role"] == "user" }.map { |message| text.call(message["content"]) } }
  rescue JSON::ParserError
    { "body" => request.body.to_s }
  end

  VCR.configure do |config|
    config.cassette_library_dir = CASSETTES
    config.hook_into :webmock
    # Every other host stays under WebMock's own stubs and net-connect rule.
    config.ignore_request { |request| URI(request.uri).host != HOST }
    config.allow_http_connections_when_no_cassette = false
    config.register_request_matcher(:llm_shape) { |recorded, replayed| shape(recorded) == shape(replayed) }
    config.default_cassette_options = { record: RECORD ? :all : :none, match_requests_on: %i[method uri llm_shape],
      allow_playback_repeats: false, decode_compressed_response: true }
    config.filter_sensitive_data("<OPENROUTER_API_KEY>") { ENV["OPENROUTER_API_KEY"] } if ENV["OPENROUTER_API_KEY"].present?
    # Only the content type is kept: no Authorization, cookies or request ids.
    config.before_record do |interaction|
      interaction.request.headers.select! { |name, _| name.casecmp?("Content-Type") }
      interaction.response.headers.select! { |name, _| name.casecmp?("Content-Type") }
    end
  end

  # Provider settings for recorded runs. Replay sends a placeholder key that
  # never leaves the process.
  class Assistant
    def llm_context(context:)
      key = RECORD ? ENV.fetch("OPENROUTER_API_KEY") : "recorded-replay"
      RubyLLM.context do |config|
        config.openrouter_api_key = key
        config.request_timeout = 90
        config.max_retries = 0
      end
    end
  end

  # Any change to the instructions' wording, not only a version bump, needs
  # new recordings.
  def self.prompt_digest = Digest::SHA256.hexdigest(RailsAiAdmin::Assistant::Runtime::PROMPT)

  def self.slug(model) = model.tr("/", "_").tr(".", "-")

  def self.cassette(name, model) = "openrouter/#{name}/#{slug(model)}"

  def self.manifest
    File.exist?(MANIFEST) ? JSON.parse(File.read(MANIFEST)) : {}
  end

  # Called while recording (or re-grading): what each cassette cost and when.
  def self.note!(section, name, model, data)
    current = manifest
    previous = current.dig(section, name, model)
    data = data.merge("recorded_on" => previous["recorded_on"]) if REGRADE && previous
    current["prompt_version"] = RailsAiAdmin::Assistant::Runtime::PROMPT_VERSION
    current["prompt_sha256"] = prompt_digest
    current["ruby_llm"] = RubyLLM::VERSION
    current["recorded_with"] = "OpenRouter chat completions through RubyLLM's openrouter provider"
    (((current[section] ||= {})[name] ||= {})[model] = { "recorded_on" => Date.current.iso8601 }.merge(data))
    FileUtils.mkdir_p(File.dirname(MANIFEST))
    File.write(MANIFEST, JSON.pretty_generate(current.sort.to_h) + "\n")
  end

  # Usage rows the chat's real (or replayed) provider responses produced.
  def self.spend(chat)
    usages = RubyLLM::ActiveRecord::Usage.where(owner: chat)
    # Every bucket: OpenRouter's prompt tokens are mostly cache reads and writes.
    tokens = RailsAiAdmin::Assistant::Budget::TOKEN_COLUMNS.sum { |column| usages.sum(column) }
    { "requests" => usages.count, "tokens" => tokens, "output_tokens" => usages.sum(:output_tokens), "cost" => usages.sum(:total_cost).to_s("F") }
  end
end

module RecordedProviderHelpers
  def with_recorded_assistant(model: RecordedProvider::PRIMARY, &block)
    skip "set OPENROUTER_API_KEY to record" if RecordedProvider::RECORD && ENV["OPENROUTER_API_KEY"].blank?
    RubyLLM::ActiveRecord::Model.find_or_create_by!(model_id: model, provider: "openrouter") { |row| row.name = model }
    with_assistant(resources: AssistantEval::RESOURCES, policy: "AssistantEval::Policy", adapter: "RecordedProvider::Assistant", model: model) do
      config = RailsAiAdmin.configuration
      config.assistant_provider = "openrouter"
      config.assistant_protocol = nil
      yield
    end
  end

  def recorded(name, model: RecordedProvider::PRIMARY, &block)
    path = RecordedProvider.cassette(name, model)
    unless RecordedProvider::RECORD || File.exist?(File.join(RecordedProvider::CASSETTES, "#{path}.yml"))
      flunk "Missing cassette #{path}.yml; record it with RAA_RECORD=1 (see test/support/recorded_provider.rb)"
    end
    VCR.use_cassette(path, &block)
  end
end
