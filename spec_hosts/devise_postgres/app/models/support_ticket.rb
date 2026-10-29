class SupportTicket < ApplicationRecord
  belongs_to :tenant
  validates :subject, presence: true
end
