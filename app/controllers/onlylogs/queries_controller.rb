# frozen_string_literal: true

module Onlylogs
  class QueriesController < ApplicationController
    before_action :set_log_file

    rescue_from(ActiveRecord::RecordInvalid) { |e| render_invalid(e.record) }
    rescue_from(ActiveRecord::RecordNotFound) { |e| render_error(e.message, :not_found) }
    rescue_from(ForbiddenPathError) { |e| render_error(e.message, :forbidden) }
    rescue_from(SecureFilePath::SecurityError) { |e| render_error(e.message, :bad_request) }

    def index
      render json: {queries: @log_file.queries}
    end

    def show
      render json: query
    end

    def create
      render json: @log_file.queries.create!(query_params), status: :created
    end

    def update
      query.update!(query_params)

      render json: query
    end

    def destroy
      query.destroy!

      head :no_content
    end

    private

    def query
      @query ||= @log_file.queries.find(params[:id])
    end

    def query_params
      params.permit(:name, :filter, :regexp_mode)
    end

    def set_log_file
      path = SecureFilePath.decrypt(params.require(:log_file_path))

      raise ForbiddenPathError, "Access denied to this log file" unless Onlylogs.file_path_permitted?(path)

      @log_file = File.new(path)
    end

    def render_invalid(record)
      render json: {
        error: record.errors.full_messages.to_sentence,
        errors: record.errors.to_hash
      }, status: :unprocessable_entity
    end

    def render_error(message, status)
      render json: {error: message}, status: status
    end
  end
end
