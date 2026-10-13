module Onlylogs
  class ApplicationController < Onlylogs.parent_controller&.constantize || ActionController::Base
    include Authentication
  end
end
