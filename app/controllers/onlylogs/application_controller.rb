module Onlylogs
  class ApplicationController < (Onlylogs.parent_controller&.constantize || ActionController::Base)
    before_action :authenticate_onlylogs_user!

    private

    def authenticate_onlylogs_user!
      return super if defined?(super)

      return if Onlylogs.disable_basic_authentication?

      unless Onlylogs.basic_auth_configured?
        render plain: "Onlylogs authentication not configured. Please configure basic auth credentials.", status: :forbidden
        return
      end

      authenticate_or_request_with_http_basic("onlylogs") do |username, password|
        username == Onlylogs.http_basic_auth_user && password == Onlylogs.http_basic_auth_password
      end
    end
  end
end
