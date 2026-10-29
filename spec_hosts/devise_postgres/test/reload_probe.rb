require_relative "../config/environment"
raise "Run in development mode" unless Rails.application.config.enable_reloading

before_resource = TicketAdmin
before_policy = TicketPolicy
before_model = SupportTicket
before_context = AdminContext
before_registry = RailsAiAdmin.registry
before_operations = RailsAiAdmin.operation_registry
before_work_registry = RailsAiAdmin.work_registry
before_operation_class = TriageTicketOperation
before_work_class = TicketReceiptWork
product_configuration = RailsToolViews.configuration
product_resolver = product_configuration.scope_resolver
product_llm_configuration = RubyLLM.config
resource_file = Rails.root.join("app/rails_ai_admin/ticket_admin.rb")
policy_file = Rails.root.join("app/policies/ticket_policy.rb")
original_resource = resource_file.read
original_policy = policy_file.read

begin
  # Change real autoloaded source in this isolated packaged host. No private gem
  # state or autoloader cache is patched to simulate a reload.
  resource_file.write(original_resource.sub('  key :tickets', "  key :tickets\n  label \"Reloaded tickets\""))
  policy_file.write(original_policy.sub('def sortable_fields = [ :priority ]', 'def sortable_fields = []').sub('def sortable_fields = [:priority]', 'def sortable_fields = []'))
  Rails.application.reloader.reload!
  raise "Resource class was retained" if TicketAdmin.equal?(before_resource)
  raise "Policy class was retained" if TicketPolicy.equal?(before_policy)
  raise "Model class was retained" if SupportTicket.equal?(before_model)
  raise "Context class was retained" if AdminContext.equal?(before_context)
  raise "Registry was retained" if RailsAiAdmin.registry.equal?(before_registry)
  raise "Operation registry was retained" if RailsAiAdmin.operation_registry.equal?(before_operations)
  raise "Work registry was retained" if RailsAiAdmin.work_registry.equal?(before_work_registry)
  raise "Operation handler was retained" if TriageTicketOperation.equal?(before_operation_class)
  raise "Work handler was retained" if TicketReceiptWork.equal?(before_work_class)
  raise "Operation registry points to an old handler" unless RailsAiAdmin.operation_registry.fetch(TicketAdmin, :triage).handler_class.equal?(TriageTicketOperation)
  raise "Work registry points to an old handler" unless RailsAiAdmin.work_registry.fetch("tickets.triaged").handler_class.equal?(TicketReceiptWork)
  raise "Registry points to the old resource" unless RailsAiAdmin.registry.fetch(:tickets).equal?(TicketAdmin)
  raise "Reload did not apply source" unless TicketAdmin.label == "Reloaded tickets"
  2.times { Rails.application.reloader.reload! }
  raise "Registry duplicated entries" unless RailsAiAdmin.registry.resources.map(&:key).sort == [ :closed_tickets, :tickets ]
  raise "Host Surface config was replaced" unless RailsToolViews.configuration.equal?(product_configuration)
  raise "Host resolver was replaced" unless RailsToolViews.configuration.scope_resolver.equal?(product_resolver)
  raise "Provider config was replaced" unless RubyLLM.config.equal?(product_llm_configuration)
  raise "Product component was lost" unless RailsToolViews.registry.fetch("host_notice")
  raise "Host inflection changed" unless Ai.name == "Ai"
  actor = StaffUser.order(:id).first!
  tenant = actor.tenants.order(:id).first!
  context = RailsAiAdmin::Context.new(actor: actor, tenant: tenant, security_version: actor.security_version)
  adapter = RailsAiAdmin::Authorization::PunditAdapter.new
  raise "Old policy field grant survived reload" unless adapter.fields(context: context, resource: TicketAdmin, action: :sort).empty?
  puts "Development reload passed: fresh resource/model/policy/context, registry replacement, host SDK hooks preserved"
ensure
  resource_file.write(original_resource)
  policy_file.write(original_policy)
  Rails.application.reloader.reload!
end
