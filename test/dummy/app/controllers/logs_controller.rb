class LogsController < ApplicationController
  def show
    encrypted_path = params[:file_path]

    if encrypted_path.blank?
      redirect_to root_path, alert: "No file specified"
      return
    end

    begin
      @log_file_path = Onlylogs::SecureFilePath.decrypt(encrypted_path)

      unless File.exist?(@log_file_path)
        redirect_to root_path, alert: "File not found"
        return
      end

    rescue Onlylogs::SecureFilePath::SecurityError => e
      Rails.logger.error "LogsController: Security violation - #{e.message}"
      redirect_to root_path, alert: "Access denied"
      return
    end

    @max_lines = (params[:max_lines] || 100).to_i
    @filter = params[:filter]
    @autoscroll = params[:autoscroll] != "false"
    @mode = @filter.blank? ? (params[:mode] || "live") : "search"
  end
end
