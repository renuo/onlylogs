# frozen_string_literal: true

require "puma/plugin"
require "rbconfig"
require "fileutils"
require "timeout"

Puma::Plugin.create do
  def start(launcher)
    @launcher = launcher
    @events = launcher.events
    @log_writer = launcher.log_writer
    @options = launcher.config.options
    @sidecar_pid = nil

    setup_paths
    start_sidecar
    register_hooks
  end

  private

  def setup_paths
    @app_root = @options[:directory] || Dir.pwd
    sockets_dir = File.expand_path("tmp/sockets", @app_root)
    FileUtils.mkdir_p(sockets_dir)

    @socket_path = env_or_option("ONLYLOGS_SIDECAR_SOCKET", :onlylogs_socket,
                                 File.join(sockets_dir, "onlylogs-sidecar.sock"))
    @drain_url = ENV["ONLYLOGS_DRAIN_URL"] || @options[:onlylogs_drain_url]
    @batch_size = env_or_option("ONLYLOGS_BATCH_SIZE", :onlylogs_batch_size, 100).to_i
    @flush_interval = env_or_option("ONLYLOGS_FLUSH_INTERVAL", :onlylogs_flush_interval, 0.5).to_f
    @sidecar_script = env_or_option("ONLYLOGS_SIDECAR_BIN", :onlylogs_sidecar_bin,
                                    File.expand_path("../../../bin/onlylogs_sidecar", __dir__))
  end

  def register_hooks
    events = @launcher.events

    events.register(:on_restart) { restart_sidecar }
    at_exit { stop_sidecar }
  end

  def env_or_option(env_key, option_key, default)
    ENV.fetch(env_key, @options.fetch(option_key, default))
  end

  def start_sidecar
    if @drain_url.to_s.strip.empty?
      warn "ONLYLOGS_DRAIN_URL not set; skipping Onlylogs sidecar start"
      return
    end

    stop_sidecar if @sidecar_pid
    remove_socket_file

    env = {
      "ONLYLOGS_SIDECAR_SOCKET" => @socket_path,
      "ONLYLOGS_DRAIN_URL" => @drain_url,
      "ONLYLOGS_BATCH_SIZE" => @batch_size.to_s,
      "ONLYLOGS_FLUSH_INTERVAL" => @flush_interval.to_s
    }

    info "Starting Onlylogs sidecar (socket: #{@socket_path}, drain: #{@drain_url})"
    @sidecar_pid = Process.spawn(env, RbConfig.ruby, @sidecar_script,
                                 chdir: @app_root,
                                 pgroup: true)
  rescue Errno::ENOENT => e
    error "Unable to start sidecar: #{e.message}"
  end

  def restart_sidecar
    info "Restarting Onlylogs sidecar"
    start_sidecar
  end

  def stop_sidecar
    return unless @sidecar_pid

    info "Stopping Onlylogs sidecar"
    pgid = Process.getpgid(@sidecar_pid)
    Process.kill("TERM", -pgid)
    Timeout.timeout(5) { Process.wait(@sidecar_pid) }
  rescue Errno::ESRCH, Errno::ECHILD
    # Already stopped
  rescue Timeout::Error
    warn "Sidecar did not stop in time, killing"
    Process.kill("KILL", -pgid) rescue nil
  ensure
    @sidecar_pid = nil
    remove_socket_file
  end

  def remove_socket_file
    FileUtils.rm_f(@socket_path)
  end

  def log(message)
    @log_writer.log(message)
  end

  def info(message)
    log("[OnlylogsSidecar] #{message}")
  end

  def warn(message)
    log("[OnlylogsSidecar][WARN] #{message}")
  end

  def error(message)
    log("[OnlylogsSidecar][ERROR] #{message}")
  end
end
