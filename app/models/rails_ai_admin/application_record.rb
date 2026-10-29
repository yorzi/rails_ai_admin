# frozen_string_literal: true

module RailsAiAdmin
  # Shares ActiveRecord::Base's primary pool; cross-pool operations are refused.
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end
