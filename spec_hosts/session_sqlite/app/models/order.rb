class Order < ApplicationRecord
  belongs_to :account
  belongs_to :customer, optional: true
  validates :number, presence: true, uniqueness: { scope: :account_id }
  validates :state, inclusion: { in: %w[draft approved rejected] }
  validates :total, numericality: { greater_than_or_equal_to: 0, less_than: 10_000_000_000 }
  validate :whole_minor_units

  private

  def whole_minor_units
    raw = BigDecimal(total_before_type_cast.to_s, exception: false)
    return unless raw&.finite?
    errors.add(:total, "must have at most two fractional digits") unless (raw * 100).frac.zero?
  end
end
