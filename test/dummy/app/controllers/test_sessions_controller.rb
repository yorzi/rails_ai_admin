# frozen_string_literal: true

class TestSessionsController < ActionController::Base
  def create
    reset_session
    session[:actor_id] = params[:id].to_i
    head :no_content
  end
end
