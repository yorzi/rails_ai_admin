Devise.setup do |config|
  config.secret_key = "synthetic-devise-key-" * 5
  config.mailer_sender = "fixture@example.test"
  require "devise/orm/active_record"
  config.stretches = 4
  config.timeout_in = 30.minutes
  config.responder.error_status = :unprocessable_content
  config.responder.redirect_status = :see_other
end
