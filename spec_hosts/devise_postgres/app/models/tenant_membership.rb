class TenantMembership < ApplicationRecord
  belongs_to :tenant
  belongs_to :staff_user
end
