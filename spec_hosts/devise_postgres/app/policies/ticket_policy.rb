class TicketPolicy
  attr_reader :context, :record
  def initialize(context, record)
    @context, @record = context, record
  end
  def select_records? = %w[operator admin].include?(context.actor.role)
  def index? = %w[viewer operator admin].include?(context.actor.role)
  def show? = index? && record.tenant_id == context.tenant.id
  def create? = %w[operator admin].include?(context.actor.role) && record.tenant_id == context.tenant.id
  def update? = %w[operator admin].include?(context.actor.role) && show?
  def destroy? = context.actor.role == "admin" && show?
  def triage? = %w[operator admin].include?(context.actor.role) && show? && record.state == "open"
  def bulk_triage? = %w[operator admin].include?(context.actor.role) && (record.is_a?(Class) || (show? && record.state == "open"))
  def permitted_operation_fields(operation)
    permitted = operation == :triage ? triage? : operation == :bulk_triage && bulk_triage?
    permitted ? %i[decision review_note] : []
  end
  def cancel_operation?(operation) = operation == :bulk_triage && context.actor.role == "admin"
  def read_operation_receipt?(operation) = %i[triage bulk_triage].include?(operation) && %w[operator admin].include?(context.actor.role) && (record.is_a?(Class) || show?)
  def deliver_operation_work?(operation, kind) = %i[triage bulk_triage].include?(operation) && %w[operator admin].include?(context.actor.role) && (record.is_a?(Class) || show?) && %w[tickets.triaged tickets.closed].include?(kind)
  def readable_fields
    fields = %i[id subject state priority review_summary]
    context.actor.role == "viewer" ? fields : fields + [ :internal_note ]
  end
  def presentation_fields(view)
    view == :index ? (readable_fields + writable_fields).uniq - [ :internal_note ] : nil
  end
  def writable_fields = %w[operator admin].include?(context.actor.role) ? %i[subject state priority internal_note] : []
  # missing_note reveals internal_note presence, so it follows that read grant.
  def permitted_named_scopes = context.actor.role == "viewer" ? %i[open triaged] : %i[open triaged missing_note]
  def searchable_fields = [ :subject ]
  def sortable_fields = [ :priority ]
  def filterable_fields = context.actor.role == "viewer" ? [ :state ] : %i[state priority]

  class Scope
    def initialize(context, relation)
      @context, @relation = context, relation
    end
    def resolve
      %w[viewer operator admin].include?(@context.actor.role) ? @relation.where(tenant_id: @context.tenant.id) : @relation.none
    end
  end
end
