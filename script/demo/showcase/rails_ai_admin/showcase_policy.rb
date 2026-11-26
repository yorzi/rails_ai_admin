# bin/demo showcase grants, prepended to the host's AdminPolicyAdapter so the
# host rules still answer everything else (super). Readers see everything but
# the password; admins also write, import, export, delete in bulk and read
# history and the audit log.
module ShowcasePolicy
  SHOWCASE = %i[articles tags summaries].freeze

  def fields(context:, resource:, action:, record: nil)
    return super unless SHOWCASE.include?(resource.key)
    admin = context.actor.role == "admin"
    case [ resource.key, action ]
    in [ :articles, :read ] then %i[id title views contact website opens_at cover gallery body settings tags password created_at updated_at]
    in [ :articles, :write ] then admin ? %i[title views contact website opens_at cover gallery body settings tags password] : []
    in [ :articles, :search ] then %i[title contact]
    in [ :articles, :sort ] then %i[title views opens_at created_at]
    in [ :articles, :filter ] then %i[views contact website created_at]
    in [ :tags, :read ] then %i[id name]
    in [ :tags, :write ] then admin ? %i[name] : []
    in [ :tags, :search | :sort ] then %i[name]
    in [ :summaries, :read ] then %i[id text article]
    in [ :summaries, :write ] then admin ? %i[text article] : []
    in [ :summaries, :search ] then %i[text]
    else []
    end
  end

  def named_scopes(context:, resource:)
    return [ :first_award ] if resource.key == :customers && context.actor.role == "admin"
    resource.key == :articles ? %i[popular recent] : super
  end

  def share_reports?(context:, resource:) = context.actor.role == "admin"

  def run_recipe?(context:, resource:, slug:)
    context.actor.role == "admin" && %i[customers orders].include?(resource.key) &&
      %w[first_award daily_order_brief check_customer_duplicates].include?(slug)
  end

  def assistant?(context:, resource:)
    context.actor.role == "admin" && %i[articles tags summaries customers orders].include?(resource.key)
  end

  # 0.7: reviewed_award needs a second admin; admins may undo and see Tasks.
  def operation_fields(context:, resource:, operation:, record: nil)
    return context.actor.role == "admin" ? [ :merge_review ] : [] if resource.key == :customers && operation == :combine_customers
    return context.actor.role == "admin" ? [ :amount ] : [] if resource.key == :customers && %i[reviewed_award reviewed_bulk_award].include?(operation)
    super
  end

  def read_operation_receipt?(context:, resource:, operation:, record:)
    return context.actor.role == "admin" if resource.key == :customers && %i[reviewed_award reviewed_bulk_award combine_customers].include?(operation)
    super
  end

  def approve_operation?(context:, resource:, operation:, record: nil, proposed_by_actor_ref: nil)
    context.actor.role == "admin" && resource.key == :customers && %i[reviewed_award reviewed_bulk_award combine_customers].include?(operation)
  end

  def run_quality_rule?(context:, resource:, rule:)
    return context.actor.role == "admin" if resource.key == :customers && rule == :duplicate_active_customers
    super
  end

  def undo_operation?(context:, resource:, operation:, record: nil) = context.actor.role == "admin"
  def view_tasks?(context:) = context.actor.role == "admin"

  def view_history?(context:, resource:, record:) = context.actor.role == "admin"
  def view_audit_log?(context:, resource:) = context.actor.role == "admin"
  def export_records?(context:, resource:) = context.actor.role == "admin"
  def import_records?(context:, resource:) = context.actor.role == "admin" && %i[articles tags customers].include?(resource.key)
end
