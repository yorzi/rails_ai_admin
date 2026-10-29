class SessionsController < ActionController::Base
  protect_from_forgery with: :exception
  def new; end

  def create
    actor = User.find_by(email: params[:email].to_s)
    if actor&.authenticate(params[:password].to_s)
      reset_session
      session[:user_id] = actor.id
      redirect_to "/staff", status: :see_other
    else
      render plain: "Invalid credentials", status: :unauthorized
    end
  end
end
