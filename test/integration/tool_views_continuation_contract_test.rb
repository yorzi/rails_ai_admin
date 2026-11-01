# frozen_string_literal: true

require "test_helper"
require "support/application"

# Characterizes released rails_tool_views 1.0.2 continuation behavior that the
# admin's shared-mode design depends on (DEP-013). When upstream changes it,
# this test fails and the continuation decision in ADR 0022 must be revisited.
class ToolViewsContinuationContractTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  KEY = "raa_continuation_probe"

  def setup
    [ RailsToolViews::AgentInteraction, RailsToolViews::ActionExecution, RailsToolViews::Presentation, RailsToolViews::Surface ].each(&:delete_all)
    RailsToolViews.reset_registry!
    @previous_adapter = RailsToolViews.configuration.agent_adapter
    RailsToolViews.register(KEY, description: "Continuation probe", partial: "rails_ai_admin/surfaces/operation_review",
      schema: { type: "object", additionalProperties: false, properties: {} },
      policy: ->(access) { access.actor.start_with?("raa:") },
      actions: { confirm: { schema: { type: "object", additionalProperties: false, properties: {} },
        policy: ->(access) { access.actor.start_with?("raa:") },
        handler: ->(_request) { RailsToolViews::Transition.new(state: { "done" => true }, agent: true) } } })
    @scope = RailsToolViews::Scope.new(actor: "raa:actor:TestActor:1", tenant: "raa:tenant:TestTenant:1")
  end

  def teardown
    RailsToolViews.configuration.agent_adapter = @previous_adapter
    RailsToolViews.reset_registry!
  end

  def confirm
    surface = RailsToolViews.present(KEY, props: {}, scope: @scope)
    RailsToolViews.dispatch(surface.id, scope: @scope, action: "confirm", arguments: {}, base_revision: 1, idempotency_key: SecureRandom.uuid)
  end

  def test_without_a_global_adapter_an_explicit_adapter_is_never_called
    RailsToolViews.configuration.agent_adapter = nil
    result = confirm
    interaction = RailsToolViews::AgentInteraction.find(result[:interaction_id])
    assert_equal "skipped", interaction.status, "the initial status depends on the host's global agent_adapter"
    calls = []
    explicit = ->(payload, delivery_key:) { calls << [ payload, delivery_key ] }
    delivered = RailsToolViews.deliver(interaction.id, scope: @scope, adapter: explicit)
    assert_equal "skipped", delivered.status
    assert_empty calls, "deliver(adapter:) treats skipped as terminal, so shared-mode continuation cannot run"
  end

  def test_with_a_global_adapter_the_explicit_adapter_is_used
    RailsToolViews.configuration.agent_adapter = ->(_payload, delivery_key:) { raise "the global adapter must not be called" }
    result = confirm
    calls = []
    delivered = RailsToolViews.deliver(result[:interaction_id], scope: @scope, adapter: ->(payload, delivery_key:) { calls << delivery_key })
    assert_equal "completed", delivered.status
    assert_equal 1, calls.size, "only a configured global adapter makes the interaction pending"
  end
end
