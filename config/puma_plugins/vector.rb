# frozen_string_literal: true

require "puma/plugin"
require "rbconfig"
require "timeout"
require "shellwords"

Puma::Plugin.create do
  def start(launcher)
    @launcher = launcher
    @events = launcher.events
    @options = launcher.config.options
    @vector_pid = nil

    setup_paths
    start_vector
    register_hooks
  end

  private

  def setup_paths
    @app_root = @options[:directory] || Dir.pwd
    @vector_bin = env_or_option("ONLYLOGS_VECTOR_BIN", :onlylogs_vector_bin, "vector")
    @vector_config = env_or_option(
      "ONLYLOGS_VECTOR_CONFIG",
      :onlylogs_vector_config,
      File.expand_path("../vector.toml", __dir__)
    )
    @vector_args = env_or_option("ONLYLOGS_VECTOR_ARGS", :onlylogs_vector_args, "")
    @dsn = env_or_option("ONLYLOGS_DSN", :onlylogs_dsn, "https://onlylogs.io/drain/testmac")
  end

  def register_hooks
    events = @launcher.events
    events.register(:on_restart) { restart_vector }
    at_exit { stop_vector }
  end

  def env_or_option(env_key, option_key, default)
    ENV.fetch(env_key, @options.fetch(option_key, default))
  end

  def start_vector
    stop_vector if @vector_pid

    unless File.exist?(@vector_config)
      warn "Vector config not found at #{@vector_config}; skipping start"
      return
    end

    args = [ @vector_bin, "--config", @vector_config ]
    args += Shellwords.split(@vector_args.to_s) unless @vector_args.to_s.empty?

    info "Starting Vector sidecar (config: #{@vector_config}, dsn: #{@dsn})"
    env = { "ONLYLOGS_DSN" => @dsn }
    @vector_pid = Process.spawn(env, *args, chdir: @app_root, pgroup: true)
  rescue Errno::ENOENT => e
    error "Unable to start Vector sidecar: #{e.message}"
  end

  def restart_vector
    info "Restarting Vector sidecar"
    start_vector
  end

  def stop_vector
    return unless @vector_pid

    info "Stopping Vector sidecar"
    pgid = Process.getpgid(@vector_pid)
    Process.kill("TERM", -pgid)
    Timeout.timeout(5) { Process.wait(@vector_pid) }
  rescue Errno::ESRCH, Errno::ECHILD
    # already stopped
  rescue Timeout::Error
    warn "Vector sidecar did not stop in time, killing"
    Process.kill("KILL", -pgid) rescue nil
  ensure
    @vector_pid = nil
  end

  def info(message)
    @events.log("[VectorSidecar] #{message}")
  end

  def warn(message)
    @events.log("[VectorSidecar][WARN] #{message}")
  end

  def error(message)
    @events.error("[VectorSidecar][ERROR] #{message}")
  end
end
