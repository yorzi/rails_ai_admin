# frozen_string_literal: true

require File.expand_path("config/environment", Dir.pwd)
require "rails/generators"
require "action_dispatch/testing/integration"
require "nokogiri"
require "rails_ai_admin/templates/inspector"

raise "Use the copied development host" unless Rails.application.config.enable_reloading && Rails.root.to_s.include?("/tmp/packaged-")
Rails.application.load_generators
source = Rails.root.join("app/views/rails_ai_admin/resources/show.html.erb")
raise "A reviewed host override already exists" if source.exist?
owned_digest = nil
begin
  Rails::Generators.invoke("rails_ai_admin:override", [ "resource_show" ], destination_root: Rails.root.to_s)
  header, *lines = source.read.lines
  original = header + '<span data-raa-reload-override="before"></span>' + lines.join
  source.write(original)
  owned_digest = Digest::SHA256.file(source).hexdigest
  actor = StaffUser.order(:id).first!
  tenant = actor.tenants.order(:id).first!
  record_id = SupportTicket.where(tenant_id: tenant.id).order(:id).first!.id
  browser = ActionDispatch::Integration::Session.new(Rails.application)
  browser.get "/staff_users/sign_in"
  csrf = Nokogiri::HTML(browser.response.body).at_css("input[name=authenticity_token]")&.[]("value")
  raise "Fixture login token missing" unless csrf
  browser.post "/staff_users/sign_in", params: { authenticity_token: csrf, staff_user: { email: actor.email, password: "synthetic-fixture-password" } }
  raise "Fixture login failed" unless browser.response.status == 303
  browser.get "/operations/tickets/#{record_id}"
  raise "Initial host override was not used" unless browser.response.status == 200 && browser.response.body.include?('data-raa-reload-override="before"')
  before_controller = RailsAiAdmin::ResourcesController
  source.write(original.sub('data-raa-reload-override="before"', 'data-raa-reload-override="after"'))
  owned_digest = Digest::SHA256.file(source).hexdigest
  Rails.application.reloader.reload!
  raise "Controller was not reloaded" if RailsAiAdmin::ResourcesController.equal?(before_controller)
  browser.get "/operations/tickets/#{record_id}"
  raise "Changed override did not reload" unless browser.response.status == 200 && browser.response.body.include?('data-raa-reload-override="after"') && !browser.response.body.include?('data-raa-reload-override="before"')
  check = RailsAiAdmin::Templates::Inspector.new(root: Rails.root).checks.find { |entry| entry.key == "resource_show" }
  raise "Host edit changed its upstream baseline unexpectedly" unless check&.code == "CURRENT"
  puts "Actual development template reload passed: host precedence, fresh controller, changed body and preserved source baseline"
ensure
  if source.file?
    raise "Changed override probe was preserved for review" unless owned_digest && Digest::SHA256.file(source).hexdigest == owned_digest
    source.delete
    Rails.application.reloader.reload!
  end
end
