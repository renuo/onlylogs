module Onlylogs
  # Base for the endpoints the embedded log viewer calls. A host that shows the
  # viewer to more people than the engine's own pages can give it a different parent.
  class ViewerController < (Onlylogs.viewer_parent_controller || Onlylogs.parent_controller)&.constantize || ActionController::Base
    include Authentication
  end
end
