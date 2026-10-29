class TicketPolicy
  attr_reader :context, :record
  def initialize(context, record)
    @context, @record = context, record
  end
  def index? = %w[viewer operator admin].include?(context.actor.role)
  def show? = index? && record.tenant_id == context.tenant.id
  def create? = %w[operator admin].include?(context.actor.role) && record.tenant_id == context.tenant.id
  def update? = %w[operator admin].include?(context.actor.role) && show?
  def destroy? = context.actor.role == "admin" && show?
  def triage? = %w[operator admin].include?(context.actor.role) && show? && record.state == "open"
  def permitted_operation_fields(operation) = operation == :triage && triage? ? %i[decision review_note] : []
  def read_operation_receipt?(operation) = operation == :triage && %w[operator admin].include?(context.actor.role) && show?
  def deliver_operation_work?(operation, kind) = operation == :triage && %w[operator admin].include?(context.actor.role) && show? && %w[tickets.triaged tickets.closed].include?(kind)
  def readable_fields
    fields = %i[id subject state priority]
    context.actor.role == "viewer" ? fields : fields + [ :internal_note ]
  end
  def writable_fields = %w[operator admin].include?(context.actor.role) ? %i[subject state priority internal_note] : []
  def searchable_fields = [ :subject ]
  def sortable_fields = [ :priority ]

  class Scope
    def initialize(context, relation)
      @context, @relation = context, relation
    end
    def resolve
      %w[viewer operator admin].include?(@context.actor.role) ? @relation.where(tenant_id: @context.tenant.id) : @relation.none
    end
  end
end
