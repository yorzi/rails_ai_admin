class AdminPolicyAdapter < RailsAiAdmin::Authorization::Adapter
  def scope(context:, resource:, relation:)
    relation.where(account_id: context.tenant.id)
  end

  def allowed?(context:, action:, resource:, record: nil)
    if resource.key == :orders && %i[update destroy review_order].include?(action)
      return context.actor.role == "admin" && record && record.state == "draft"
    end
    %i[index show].include?(action) || context.actor.role == "admin"
  end

  def select_records?(context:, resource:) = context.actor.role == "admin"

  def view_history?(context:, resource:, record:) = context.actor.role == "admin"
  def view_audit_log?(context:, resource:) = context.actor.role == "admin"

  # Expedited handling is an admin-only triage view, independent of field reads.
  def named_scopes(context:, resource:)
    return [] unless resource.key == :orders
    %i[drafts reviewed all] + (context.actor.role == "admin" ? [ :expedited ] : [])
  end

  def fields(context:, resource:, action:, record: nil)
    if resource.key == :orders
      case action
      when :read then %i[id number customer state total delivery_on expedited reviewed_at review_summary] + (context.actor.role == "admin" ? [ :review_note ] : [])
      when :write then context.actor.role == "admin" ? %i[number customer state total delivery_on expedited] : []
      when :search then [ :number ]
      when :sort then %i[number delivery_on]
      # Amount ranges are commercial detail; delivery filters are operational.
      when :filter then %i[customer delivery_on expedited] + (context.actor.role == "admin" ? [ :total ] : [])
      else []
      end
    else
      customer_fields(context: context, action: action)
    end
  end

  def customer_fields(context:, action:)
    case action
    when :read then %i[id name active points created_at status_summary]
    when :write then context.actor.role == "admin" ? %i[name active points] : []
    when :search, :sort then [ :name ]
    else []
    end
  end

  def operation_fields(context:, resource:, operation:, record: nil)
    return context.actor.role == "admin" ? %i[decision note] : [] if resource.key == :orders && operation == :review_order
    context.actor.role == "admin" && %i[award_points bulk_award_points].include?(operation) ? [ :amount ] : []
  end

  def cancel_operation?(context:, resource:, operation:) = context.actor.role == "admin" && operation == :bulk_award_points

  def read_operation_receipt?(context:, resource:, operation:, record:)
    return context.actor.role == "admin" if resource.key == :orders && operation == :review_order
    context.actor.role == "admin" && %i[award_points bulk_award_points].include?(operation)
  end
end
