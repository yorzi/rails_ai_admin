class PortalController < ApplicationController
  before_action :authenticate_staff_user!
  def index; end
end
