# Host authentication parameters are the host's responsibility.
Rails.application.config.filter_parameters += [ :password, :authenticity_token ]
