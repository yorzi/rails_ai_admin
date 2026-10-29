class StaffUser < ApplicationRecord
  devise :database_authenticatable, :timeoutable
  has_many :tenant_memberships, dependent: :destroy
  has_many :tenants, through: :tenant_memberships
end
