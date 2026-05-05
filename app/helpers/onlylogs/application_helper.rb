module Onlylogs
  module ApplicationHelper
    def log_file_label(file)
      pathname = Pathname.new(file)
      relative = pathname.relative_path_from(Rails.root).to_s
      relative.start_with?("..") ? pathname.basename.to_s : relative
    rescue ArgumentError
      Pathname.new(file).basename.to_s
    end

    def encrypted_log_file_path(file)
      Onlylogs::SecureFilePath.encrypt(file.to_s)
    end
  end
end
