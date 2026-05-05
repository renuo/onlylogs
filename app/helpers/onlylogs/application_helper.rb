module Onlylogs
  module ApplicationHelper
    def log_file_label(file)
      pathname = Pathname.new(file)
      relative = pathname.relative_path_from(Rails.root).to_s
      relative.start_with?("..") ? pathname.basename.to_s : relative
    end
  end
end
