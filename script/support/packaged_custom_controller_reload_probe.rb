# frozen_string_literal: true

require File.expand_path("config/environment", Dir.pwd)
require "action_dispatch/testing/integration"
require "nokogiri"
require "securerandom"

raise "Use the copied session host in development" unless Rails.application.config.enable_reloading && Rails.root.to_s.end_with?("/tmp/packaged-session-sqlite")
raise "Use the installed gem" unless Gem.loaded_specs.fetch("rails_ai_admin").full_gem_path.include?("/gems/rails_ai_admin-")
controller_path = Rails.root.join("app/controllers/order_reviews_controller.rb")
operation_path = Rails.root.join("app/rails_ai_admin/review_order_operation.rb")
original_controller = controller_path.read
original_operation = operation_path.read
modified_controller = original_controller.sub("  def show\n", "  def show\n    response.headers['X-Host-Controller-Reload'] = 'reloaded'\n")
modified_operation = original_operation.sub('version "1"', 'version "2"')
raise "Reload fixture did not match source" if modified_controller == original_controller || modified_operation == original_operation
actor = User.find_by!(email: "admin@example.test")
actor_id, original_role = actor.id, actor.role
actor.update!(role: "admin")
order = Order.create!(account: actor.account, number: "RELOAD-#{SecureRandom.hex(5)}", total: "12.34")
order_id, intent_ref = order.id, nil
session = ActionDispatch::Integration::Session.new(Rails.application)
session.host! "localhost"

def document(session) = Nokogiri::HTML(session.response.body)

begin
  session.get "/login"
  session.post "/login", params: { authenticity_token: document(session).at_css("input[name=authenticity_token]")["value"], email: actor.email, password: "synthetic-fixture-password" }
  raise "Login failed" unless session.response.status == 303
  path = "/staff/workbench/orders/#{order_id}"
  session.get path
  raise "Initial workbench failed" unless session.response.status == 200
  session.post "#{path}/preview", params: { authenticity_token: document(session).at_css("input[name=authenticity_token]")["value"], expected_version: 0, input: { decision: "approve", note: "Reload review contract" } }
  raise "Initial review failed" unless session.response.status == 200
  intent_ref = document(session).at_css("input[name=intent_ref]")["value"]
  wire = document(session).at_css("input[name=confirmed_input]")["value"]
  token = document(session).at_css("meta[name=csrf-token]")["content"]
  before_controller, before_resource, before_operation, before_registry = OrderReviewsController, OrderAdmin, ReviewOrderOperation, RailsAiAdmin.registry
  controller_path.write(modified_controller)
  operation_path.write(modified_operation)
  Rails.application.reloader.reload!
  raise "Host controller class retained" if OrderReviewsController.equal?(before_controller)
  raise "Resource class retained" if OrderAdmin.equal?(before_resource)
  raise "Operation class retained" if ReviewOrderOperation.equal?(before_operation)
  raise "Registry retained" if RailsAiAdmin.registry.equal?(before_registry)
  session.get path
  raise "Reloaded host code did not handle HTTP" unless session.response.status == 200 && session.response.headers["X-Host-Controller-Reload"] == "reloaded"
  session.post "#{path}/execute", params: { authenticity_token: token, intent_ref: intent_ref, confirmed_input: wire }
  raise "Old approval was not rejected" unless session.response.status == 409
  raise "Old approval changed business state" unless Order.find(order_id).state == "draft" && Order.find(order_id).lock_version.zero?
  raise "Old approval wrote success audit" if RailsAiAdmin::AuditEvent.where(correlation_ref: intent_ref, status: "succeeded").exists?
  puts "Real host controller/resource/operation/registry reload passed; HTTP used new code and rejected the original approval without a business write"
ensure
  if controller_path.read == modified_controller
    controller_path.write(original_controller)
  elsif controller_path.read != original_controller
    raise "Concurrent host controller changes preserved"
  end
  if operation_path.read == modified_operation
    operation_path.write(original_operation)
  elsif operation_path.read != original_operation
    raise "Concurrent host operation changes preserved"
  end
  Rails.application.reloader.reload!
  if intent_ref
    RailsAiAdmin::AuditEvent.where(correlation_ref: intent_ref).delete_all
    RailsAiAdmin::OperationRun.where(id: intent_ref, status: "proposed").delete_all
  end
  Order.where(id: order_id).destroy_all if order_id
  User.find(actor_id).update!(role: original_role) if actor_id
end
