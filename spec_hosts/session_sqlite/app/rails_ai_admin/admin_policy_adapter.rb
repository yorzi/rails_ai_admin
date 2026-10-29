class AdminPolicyAdapter < RailsAiAdmin::Authorization::Adapter
  def scope(context:, resource:, relation:)
    relation.where(account_id: context.tenant.id)
  end

  def allowed?(context:, action:, resource:, record: nil)
    %i[index show].include?(action) || context.actor.role == "admin"
  end

  def select_records?(context:, resource:) = context.actor.role == "admin"

  def fields(context:, resource:, action:, record: nil)
    case action
    when :read then %i[id name active points created_at]
    when :write then context.actor.role == "admin" ? %i[name active points] : []
    when :search, :sort then [ :name ]
    else []
    end
  end

  def operation_fields(context:, resource:, operation:, record: nil)
    context.actor.role == "admin" && operation == :award_points ? [ :amount ] : []
  end

  def read_operation_receipt?(context:, resource:, operation:, record:)
    context.actor.role == "admin" && operation == :award_points
  end
end
