RailsAiAdmin.configure do |config|
  config.field_types = { trimmed_text: "TrimmedTextField" }
  config.authentication_path = "/staff_users/sign_in"
  config.context_adapter = "AdminContext"
  config.authorization_adapter = "RailsAiAdmin::Authorization::PunditAdapter"
  config.resources = [ "TicketAdmin", "ClosedTicketAdmin" ]
  config.work_handlers = { "tickets.triaged" => "TicketReceiptWork", "tickets.closed" => "ClosedTicketReceiptWork" }
  # This host already owns rails_tool_views for its product; the admin only adds
  # its own endpoints and raa_operation_review component.
  config.surfaces = true
end
