# These settings belong to this host product, not to the admin engine.
RubyLLM.configure { |config| config.default_model = "gpt-5.6-luna" }
RailsToolViews.configure do |config|
  config.parent_controller = "::ApplicationController"
  config.auto_deliver = false
  config.scope_resolver = ->(controller) { ProductRuntime.scope(controller) }
end
Rails.application.config.to_prepare do
  RailsToolViews.reset_registry!
  RailsToolViews.register("host_notice", description: "Host product notice", partial: "product_notices/notice",
    schema: { type: "object", properties: { message: { type: "string", maxLength: 100 } }, required: [ "message" ], additionalProperties: false },
    policy: ->(access) { access.actor.start_with?("product:StaffUser:") }, expose_to: [])
end
