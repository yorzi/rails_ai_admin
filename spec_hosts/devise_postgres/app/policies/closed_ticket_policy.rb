class ClosedTicketPolicy < TicketPolicy
  def writable_fields = []
  class Scope < TicketPolicy::Scope
    def resolve = super.where(state: "closed")
  end
end
