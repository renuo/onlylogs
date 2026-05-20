module Onlylogs
  module ApplicationHelper
    def log_file_label(file)
      Pathname.new(file).relative_path_from(Rails.root).to_s
    end
  end
end
