  # bin/demo --showcase: articles, tags and summaries. Readers see everything
  # but the password; admins also write, export, delete in bulk and read history.
  SHOWCASE = %i[articles tags summaries].freeze

  def showcase_fields(context:, resource:, action:)
    admin = context.actor.role == "admin"
    case [ resource.key, action ]
    in [ :articles, :read ] then %i[id title views contact website opens_at cover body settings tags password updated_at]
    in [ :articles, :write ] then admin ? %i[title views contact website opens_at cover body settings tags password] : []
    in [ :articles, :search ] then %i[title contact]
    in [ :articles, :sort ] then %i[title views opens_at]
    in [ :articles, :filter ] then %i[views]
    in [ :tags, :read ] then %i[id name]
    in [ :tags, :write ] then admin ? %i[name] : []
    in [ :tags, :search | :sort ] then %i[name]
    in [ :summaries, :read ] then %i[id text article]
    in [ :summaries, :write ] then admin ? %i[text article] : []
    in [ :summaries, :search ] then %i[text]
    else []
    end
  end

  def view_history?(context:, resource:, record:) = context.actor.role == "admin"
  def export_records?(context:, resource:) = context.actor.role == "admin"
