# frozen_string_literal: true

module Onlylogs
  class QueriesController < ApplicationController
    before_action :authorize_log_file!

    rescue_from Query::InvalidRegexpError, with: :render_invalid_regexp
    rescue_from Query::NotFoundError, with: :render_not_found
    rescue_from ArgumentError, with: :render_bad_request
    rescue_from SQLite3::ConstraintException, with: :render_conflict

    def index
      queries = Query.all(@log_file_path)

      render json: {
        queries: queries.map(&:to_h)
      }
    rescue => e
      render_internal_error("Failed to fetch queries", e)
    end

    def show
      query = find_query!

      render json: query.to_h
    rescue => e
      render_internal_error("Failed to fetch query", e)
    end

    def create
      query = Query.create(
        @log_file_path,
        name: required_param(:name),
        filter: required_param(:filter),
        regexp_mode: boolean_param(:regexp_mode)
      )

      render json: query.to_h, status: :created
    rescue Query::InvalidRegexpError,
      ArgumentError,
      SQLite3::ConstraintException
      raise
    rescue => e
      render_internal_error("Failed to create query", e)
    end

    def update
      query = find_query!

      query.name = params[:name] if params.key?(:name)
      query.filter = params[:filter] if params.key?(:filter)
      query.regexp_mode = boolean_param(:regexp_mode) if params.key?(:regexp_mode)

      query.save(@log_file_path)

      render json: query.to_h
    rescue Query::InvalidRegexpError,
      Query::NotFoundError,
      ArgumentError,
      SQLite3::ConstraintException
      raise
    rescue => e
      render_internal_error("Failed to update query", e)
    end

    def destroy
      query = find_query!
      query.delete(@log_file_path)

      render json: {success: true}
    rescue Query::NotFoundError
      raise
    rescue => e
      render_internal_error("Failed to delete query", e)
    end

    private

    def find_query!
      query = Query.find(@log_file_path, query_id)

      raise Query::NotFoundError, "Query not found" unless query

      query
    end

    def query_id
      Integer(params[:id])
    rescue ArgumentError, TypeError
      raise ArgumentError, "Invalid query id"
    end

    def required_param(key)
      value = params[key]

      raise ArgumentError, "#{key.to_s.humanize} is required" if value.nil?

      value
    end

    def boolean_param(key)
      ActiveModel::Type::Boolean.new.cast(params[key])
    end

    def authorize_log_file!
      encrypted_path = params[:log_file_path]

      if encrypted_path.blank?
        return render json: {error: "Log file path is required"}, status: :bad_request
      end

      @log_file_path = SecureFilePath.decrypt(encrypted_path)

      unless Onlylogs.file_path_permitted?(@log_file_path)
        render json: {error: "Access denied to this log file"}, status: :forbidden
      end
    rescue SecureFilePath::SecurityError
      render json: {error: "Invalid log file path token"}, status: :bad_request
    end

    def render_invalid_regexp(error)
      render json: {error: error.message}, status: :unprocessable_entity
    end

    def render_not_found(error)
      render json: {error: error.message}, status: :not_found
    end

    def render_bad_request(error)
      render json: {error: error.message}, status: :bad_request
    end

    def render_conflict(_error)
      render json: {error: "A query with that name already exists"}, status: :conflict
    end

    def render_internal_error(message, error)
      Rails.logger.error("[Onlylogs] #{message}: #{error.class} - #{error.message}")

      render json: {
        error: message
      }, status: :internal_server_error
    end
  end
end
