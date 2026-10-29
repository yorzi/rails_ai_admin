RailsAiAdmin.configure do |config|
  config.context_adapter = "AdminContext"
  config.authorization_adapter = "RailsAiAdmin::Authorization::PunditAdapter"
  config.resources = [ "TicketAdmin", "ClosedTicketAdmin" ]
end
