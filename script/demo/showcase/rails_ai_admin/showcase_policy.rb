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
    in [ :articles, :filter ] then %i[views created_at]
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
    resource.key == :articles ? %i[popular recent] : super
  end

  def view_history?(context:, resource:, record:) = context.actor.role == "admin"
  def view_audit_log?(context:, resource:) = context.actor.role == "admin"
  def export_records?(context:, resource:) = context.actor.role == "admin"
  def import_records?(context:, resource:) = context.actor.role == "admin" && %i[articles tags customers].include?(resource.key)
end
