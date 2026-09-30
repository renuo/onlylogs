<img alt="w:100px" src="app/assets/images/onlylogs/logo.png" width="400px"/>

We believe logs are enough.

We believe logs in human-readable format are enough.

Stop streaming your logs to very expensive external services: just store your logs on disk.

When your application grows and you don't want to self-host your log files anymore, you can stream them
to https://onlylogs.io and continue enjoying the same features.

> [!IMPORTANT]
> https://onlylogs.io is still in beta. Send us an email to a@renuo.ch if you want access to the platform.

## Installation as self-hosted

If you already have a disk, you can just keep there also your log files (as well as you probably already do).

This section explains how to setup onlylogs to self host your logs and access them directly from your Rails app.

If instead you want to stream your logs to https://onlylogs.io, head
to [the onlylogs.io instructions page](https://onlylogs.io/instructions).

Onlylogs needs Rails 8 or newer. It works with Importmap, Sprockets and Propshaft (see
[INTEGRATION.md](INTEGRATION.md) if you have to register the Stimulus controller by hand).

Add this line to your application's Gemfile:

```ruby
gem "onlylogs"
```

And then execute:

```bash
$ bundle
```

mount the engine in your `routes.rb`

```ruby
Rails.application.routes.draw do
  # ...
  mount Onlylogs::Engine, at: "/onlylogs"
end
```

Finally, you **must secure the engine**. Read the section dedicated to the [Authentication](#authentication).

> [!TIP]
> **Install ripgrep for Better Performance**.
> For optimal search performance, we recommend installing [ripgrep](https://github.com/BurntSushi/ripgrep).
> Onlylogs will automatically detect and use ripgrep if available.

## Usage

Head to `/onlylogs` and enjoy your logs streamed right into your face!

The viewer has two modes:

- **Live**: the end of the file is streamed to you as new lines are written.
- **Search**: you look for something in the whole file.

Next to the query field you find two checkboxes:

- **Regexp**: the query is a regular expression. Without it, the query is searched as plain text.
- **Ignore case**: `error` also finds `ERROR`.

What the query matched is highlighted on every line. On any line you can also ask for the lines around it
(press `Enter` on it), and you can download the whole file.

> [!TIP]
> Onlylogs automatically detects and uses [ripgrep (rg)](https://github.com/BurntSushi/ripgrep) if available, which
provides significantly faster search experience.
> If ripgrep is not installed, onlylogs falls back to `grep`.
> A warning icon (⚠️) will be displayed in the toolbar when using `grep` to indicate slower search performance.

### Saved searches

Click the star in the query field to save the current query. The list next to it shows all saved searches: pick one to
apply it, rename it or remove it. A saved search is shared by everybody who opens the same log file.

Saved searches are stored in a small SQLite database, in a hidden `.onlylogs` folder next to the log file
(for example `log/.onlylogs/queries.db`). The folder must be writable. In Docker, keep it on a volume, like the logs
(see [Notes about Docker](#notes-about-docker)). You can change the folder name with `config.database_dir`.

### Keyboard shortcuts

Hold **⌃ Control** on macOS or **Alt** on Windows and Linux: a letter appears on every control of the toolbar, and
modifier + letter triggers it from anywhere, also while typing a query. Press `?` (or the ⌨ button) for the full list.

Inside the log lines, `↑` `↓` (or `j` `k`) move a line cursor, `←` `→` select words of that line (`Shift` grows the
selection) and `Enter` searches the selection, or shows the lines around the current one. `/` jumps to the query,
`Enter` or `Esc` in the query jumps back into the lines.

A host app can give its own controls a letter with the same attribute, e.g.
`<button data-onlylogs-shortcut="f">Fullscreen</button>`.

## Logging in production

Rails apps log to `STDOUT` in production and let the platform collect the stream. onlylogs keeps that default:
`Onlylogs::HttpLogger.new` writes every line to `$stdout` and, when
`ONLYLOGS_DRAIN_URL` is set, ships it to https://onlylogs.io as well. Nothing is written to disk.

```ruby
# config/environments/production.rb
config.logger = Onlylogs::HttpLogger.new
```

Shipping is fire and forget. Lines are batched in memory and sent in the background; when onlylogs.io is down or
does not answer within the timeouts, the sender backs off for a while and the lines of that period are lost. Your
`$stdout` stream still has them. If you would rather keep them, set `ONLYLOGS_SPOOL_ENABLED=true`: batches that could
not be delivered are then written to `ONLYLOGS_SPOOL_DIR` (default `tmp/onlylogs/spool`, up to
`ONLYLOGS_SPOOL_MAX_BYTES`, 128 MB) and replayed once the drain is back, also after a restart when the directory is on
a persistent disk.

Keep this default on an **ephemeral filesystem** (Heroku, Deploio, Docker, Kubernetes). A log file there is lost on
every deploy and, while it grows, its page cache counts towards the container's memory limit: it shows up as a memory
leak that resets on each release.

If you have a **persistent disk** and want the files, for instance to browse them with the engine, pass a rotating log
device as the local fallback. Rails rotates at 100 MB in development, which is a good size here too:

```ruby
# config/environments/production.rb
log_file = Logger::LogDevice.new(Rails.root.join("log", "production.log"), shift_age: 5, shift_size: 100.megabytes)
config.logger = Onlylogs::HttpLogger.new(local_fallback: log_file)
```

Any IO or log device works and is used as is. `Onlylogs::SocketLogger` accepts the same argument.

### Settings of `HttpLogger`

`HttpLogger` is configured with environment variables. Only `ONLYLOGS_DRAIN_URL` is needed. The others have sensible
defaults.

| Variable                      | Default                  | What it does                                              |
|-------------------------------|--------------------------|-----------------------------------------------------------|
| `ONLYLOGS_DRAIN_URL`          | none                     | Where the logs are sent. Without it, logs stay local.     |
| `ONLYLOGS_BATCH_SIZE`         | `100`                    | Lines sent together in one request.                       |
| `ONLYLOGS_FLUSH_INTERVAL`     | `0.5`                    | Seconds to wait before sending an incomplete batch.       |
| `ONLYLOGS_MAX_QUEUE_SIZE`     | `10000`                  | Lines kept in memory while waiting to be sent.            |
| `ONLYLOGS_MAX_BATCH_BYTES`    | `1048576` (1 MB)         | Maximum size of a batch. Longer lines are truncated.      |
| `ONLYLOGS_OPEN_TIMEOUT`       | `0.5`                    | Seconds to wait when connecting to the drain.             |
| `ONLYLOGS_READ_TIMEOUT`       | `0.5`                    | Seconds to wait for the answer of the drain.              |
| `ONLYLOGS_KEEP_ALIVE_TIMEOUT` | `30`                     | Seconds an idle connection is kept open for reuse.        |
| `ONLYLOGS_CIRCUIT_COOLDOWN`   | `30`                     | Seconds to stop sending after repeated failures.          |
| `ONLYLOGS_SPOOL_DIR`          | `tmp/onlylogs/spool`     | Folder where undelivered batches are stored on disk.      |
| `ONLYLOGS_SPOOL_MAX_BYTES`    | `134217728` (128 MB)     | Maximum size of that folder.                              |

A wrong value (for example a negative number) is ignored with a warning and the default is used. A wrong
`ONLYLOGS_DRAIN_URL` never stops your app from booting: it just logs locally.

### What happens when the drain is down

Your app must never become slow or crash because of logging. `HttpLogger` sends the lines from a background thread,
never from the request thread, and it protects your app like this:

1. Lines wait in a queue in memory and are sent in batches.
2. After a few failed requests, a **circuit breaker** stops trying for a while, so your app does not wait on a dead
   server.
3. Batches that could not be delivered are saved in the **spool** folder on disk. They are sent again when the drain
   is back, even after a restart. Because of this, a line can very rarely arrive twice, but it is not lost.
4. If the queue is full, new lines are dropped. If the spool is full, its oldest batches are deleted. Your app keeps
   running.

To see this in action, run `bin/fake_drain` and `bin/fake_app` (see [Development](#development--contributing)).

### Sidecar (alternative to `HttpLogger`)

Instead of sending logs from inside the app, you can let a small separate process do it. The app writes the lines to
a Unix socket with `Onlylogs::SocketLogger`, and the sidecar sends them to the drain.

```ruby
# config/environments/production.rb
config.logger = Onlylogs::SocketLogger.new
```

```ruby
# config/puma.rb
plugin :onlylogs_sidecar # starts and stops the sidecar together with Puma
```

You can also start it yourself with `bin/onlylogs_sidecar`. It reads `ONLYLOGS_DRAIN_URL` and, optionally,
`ONLYLOGS_SIDECAR_SOCKET`, `ONLYLOGS_BATCH_SIZE` and `ONLYLOGS_FLUSH_INTERVAL`.

Prefer `HttpLogger`: it works in every process (Puma, Sidekiq, rake tasks) and has the spool. Use the sidecar only if
you want the sending to happen outside of your app process.

### Filtering Log Lines with a Denylist

The `Onlylogs::Formatter` supports a denylist: an array of regular expressions that prevents matching lines from being
logged. This is useful for filtering out noisy or irrelevant entries like health checks or asset requests.

```ruby
# config/environments/production.rb
config.logger = Onlylogs::HttpLogger.new
config.logger.formatter.denylist = [/health_check/, /ping/, /\.css\z/]
```

Any log message matching at least one pattern in the denylist will be silently dropped.

## Authentication

Yes, we should do this right away, because this engine gives access to your log files, so you want to be sure.

The engine has controllers and one ActionCable channel that **must be protected**.

Please be sure to secure them properly.

> [!IMPORTANT]
> By default, onlylogs endpoints are completely inaccessible until basic auth credentials are configured.

### Notes about Docker

If your app is running in a Docker container, for example with Kamal, remember to mount your logs folder:

```yaml
# config/deploy.yml
volumes:
  - "storage:/rails/storage"
  - "cache:/rails/tmp/cache"
  - "logs:/rails/log"
```

The saved searches live in `log/.onlylogs`, so they are kept too.

### Basic Authentication Setup

Credentials can be configured using environment variables, Rails credentials, or programmatically. Environment variables
take precedence over Rails credentials.

```bash
# env variables
export ONLYLOGS_BASIC_AUTH_USER="your_username"
export ONLYLOGS_BASIC_AUTH_PASSWORD="your_password"
```

```yml
# config/credentials.yml.enc
onlylogs:
  basic_auth_user: your_username
  basic_auth_password: your_password
```

```ruby
# config/initializers/onlylogs.rb
Onlylogs.configure do |config|
  config.basic_auth_user = "your_username"
  config.basic_auth_password = "your_password"
end
```

### Custom Authentication

When you need custom authentication logic beyond basic auth, you can override the default authentication by configuring
a parent controller that defines the `authenticate_onlylogs_user!` method.

Configure a custom parent controller in your initializer:

```ruby
# config/initializers/onlylogs.rb
Onlylogs.configure do |config|
  config.disable_basic_authentication = true
  config.parent_controller = "ApplicationController" # or any other controller
end
```

In your parent controller, define the `authenticate_onlylogs_user!` method:

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  private

  def authenticate_onlylogs_user!
    raise unless current_user.can_access_logs?
  end
end
```

#### Disabling Authentication

For development you can disable basic authentication entirely:

```ruby
# config/environments/development.rb
Onlylogs.configure do |config|
  config.disable_basic_authentication = true
end
```

### Allowing only some users to see some files

By default everybody who gets through the authentication can open every file you allowed (see
[File Access Security](#file-access-security)). To decide per user and per file, set `authorize_log_file`. It runs
inside the controller, so you can use your own `current_user`. Return something falsy to refuse the file.

```ruby
# config/initializers/onlylogs.rb
Onlylogs.configure do |config|
  config.authorize_log_file = ->(file_path) { current_user.admin? || file_path.to_s.end_with?("public.log") }
end
```

If you show the log viewer in your own pages to more people than the rest of the engine, you can give its endpoints a
different parent controller with `config.viewer_parent_controller`.

### WebSocket Authentication

Logs are streamed through a WebSocket. To stream a file, two things must be true:

- the file path is allowed (see [File Access Security](#file-access-security));
- the file path is sent encrypted, with `Onlylogs::SecureFilePath.encrypt`. The viewer does this for you. Nobody can
  ask for a path they were not given.

An empty or unknown path is refused.

### File Access Security

Onlylogs includes a secure file access system that prevents unauthorized access to files on your server. By default,
onlylogs can access your Rails environment-specific log files (e.g., `log/development.log`, `log/production.log`).

#### Configuring Allowed Files

You can configure which files onlylogs is allowed to access by creating a configuration initializer:

```ruby
# config/initializers/onlylogs.rb
Onlylogs.configure do |config|
  config.log_file_patterns = [
    # Default Rails log files
    Rails.root.join("log/development.log"),
    Rails.root.join("log/production.log"),
    Rails.root.join("log/test.log"),

    # Custom log files
    Rails.root.join("log/custom.log"),
    Rails.root.join("log/api.log"),

    # Application-specific logs
    Rails.root.join("log/background_jobs.log"),
    Rails.root.join("log/imports.log"),

    # Allow all .log files in a directory using glob patterns
    Rails.root.join("log/*.log"),
    Rails.root.join("tmp/logs/*.log")
  ]
end
```

**Default Behavior:**

- If not configured, onlylogs defaults to `Rails.root.join("log/#{Rails.env}.log").to_s`
- This means it will use `log/development.log` in development, `log/production.log` in production, etc.

#### Glob Pattern Support

Onlylogs supports glob patterns to allow multiple files at once:

```ruby
# config/initializers/onlylogs.rb
Onlylogs.configure do |config|
  config.log_file_patterns = [
    # Allow all .log files in the log directory
    Rails.root.join("log/*.log"),

    # Allow specific pattern matches
    Rails.root.join("log/*production*.log"),
    Rails.root.join("log/*development*.log"),

    # Allow files in subdirectories
    Rails.root.join("log/**/*.log"),
    Rails.root.join("tmp/**/*.log")
  ]
end
```

**Supported Glob Patterns:**

- `*.log` - Matches all files ending with `.log` in the specified directory
- `*production*.log` - Matches files containing "production" and ending with `.log`
- `**/*.log` - Matches all `.log` files in the directory and all subdirectories

**Important Notes:**

- Patterns are directory-specific - `log/*.log` only matches files in the `log/` directory
- Multiple patterns can be combined in the same configuration

## Configuration

All options go into `Onlylogs.configure`. The most useful ones:

| Option                         | Default                       | What it does                                        |
|--------------------------------|-------------------------------|-----------------------------------------------------|
| `log_file_patterns`            | `log/<Rails.env>.log`         | Files (or globs) the viewer may open.               |
| `basic_auth_user`, `basic_auth_password` | env or credentials | Credentials of the basic authentication.     |
| `disable_basic_authentication` | `false`                       | Turn off basic auth (use it with your own auth).    |
| `parent_controller`            | none                          | Controller the engine inherits from.                |
| `viewer_parent_controller`     | `parent_controller`           | Same, but only for the viewer endpoints.            |
| `authorize_log_file`           | none                          | Per-user, per-file permission check.                |
| `ripgrep_enabled`              | `true` if `rg` exists         | Use ripgrep instead of grep.                        |
| `editor`                       | from env                      | Editor used for file path links.                    |
| `max_line_matches`             | `100000`                      | Maximum lines returned by a search.                 |
| `search_timeout`               | `120`                         | Seconds after which a search is stopped.            |
| `database_dir`                 | `".onlylogs"`                 | Folder (next to the logs) with the saved searche.   |

See `lib/onlylogs/configuration.rb` for the details.

### Configuring Code Editor for File Path Links

Onlylogs automatically detects file paths in log messages and converts them into clickable links that open in your
preferred code editor.

For a complete list of supported editors,
see [app/models/onlylogs/file_path_parser.rb](app/models/onlylogs/file_path_parser.rb).

```bash
# env variables
export EDITOR="vscode"
export RAILS_EDITOR="vscode"
export ONLYLOGS_EDITOR="vscode" # highest precedence
```

```yml
# config/credentials.yml.enc
onlylogs:
  editor: vscode
```

```ruby
# config/initializers/onlylogs.rb
Onlylogs.configure do |config|
  config.editor = :vscode
end
```

### Configuring Maximum Search Results

By default, onlylogs limits search results to 100,000 lines to prevent memory issues and ensure responsive performance.
You can configure this limit based on your needs:

```ruby
# config/initializers/onlylogs.rb
Onlylogs.configure do |config|
  # Set a custom limit (e.g., 50,000 lines)
  config.max_line_matches = 50_000

  # Or remove the limit entirely (use with caution)
  config.max_line_matches = nil
end
```

### Bounding How Long a Viewer Search Can Run

Searches started from the log viewer stop after `search_timeout` seconds, keeping whatever they found and reporting that
they did not reach the end of the file. The default is 120 seconds:

```ruby
# config/initializers/onlylogs.rb
Onlylogs.configure do |config|
  config.search_timeout = 300

  # Or remove the ceiling entirely (a search then holds a CPU until it reaches
  # the end of the file, however large it is)
  config.search_timeout = nil
end
```

## Customization

Onlylogs provides two ways to customize the appearance of the log viewer: CSS Variables and a complete style override.
Check the file [_log_container_styles.html.erb](app/views/onlylogs/shared/_log_container_styles.html.erb) for the
complete list of CSS variables.

## Instrumentation

Every search sends an `ActiveSupport::Notifications` event called `search.onlylogs`. You can use it to measure how long
searches take, for example:

```ruby
ActiveSupport::Notifications.subscribe("search.onlylogs") do |event|
  Rails.logger.info "Search #{event.payload[:query]} took #{event.duration.round}ms, " \
                    "#{event.payload[:matches]} matches, timed out: #{event.payload[:timed_out]}"
end
```

The payload contains `file_path`, `query`, `regexp`, `case_sensitive`, `start_position`, `end_position`,
`max_matches`, `matches` and `timed_out`.

## Development & Contributing

You are more than welcome to help and contribute to this package.

The app uses minitest and includes a dummy app, so getting started should be straightforward.

### Getting Started

First, install dependencies:

```bash
bundle install
```

Then start the dummy Rails app:

```bash
cd test/dummy
bundle exec rails s
```

The dummy app will be available at `http://onlylogs.localhost:3000` and onlylogs at
`http://onlylogs.localhost:3000/onlylogs`.

### Generating Test Logs

To test onlylogs with live log data, use the continuous log writer script. This is especially useful for testing
real-time log streaming and UI behavior.

```bash
# Generate 1 log entry every 2 seconds (default)
bin/continuous_log_writer

# Generate 5 log entries every 1 second
bin/continuous_log_writer 5 1

# Generate 10 log entries every 3 seconds
bin/continuous_log_writer 10 3
```

The script will write logs to `test/dummy/log/development.log`, which will appear in real-time in the onlylogs UI at
`http://onlylogs.localhost:3000/onlylogs`.

The lines are generated by `Onlylogs::ContinuousLogWriter`, in the same format a Rails app logging through
`Onlylogs::Logger` produces. The script is a thin wrapper, so applications embedding onlylogs can reuse the writer
against any file of their own:

```ruby
require "onlylogs/continuous_log_writer"

Onlylogs::ContinuousLogWriter.new(some_log_path, logs_per_batch: 3, interval: 1).call
```

It is plain Ruby (it does not need Rails to be booted) and is not loaded by `require "onlylogs"` — require it explicitly
where you need it.

**Example workflow:**

```bash
# Terminal 1: Start the Rails app
cd test/dummy && bundle exec rails s

# Terminal 2: Generate test logs while viewing in the UI
bin/continuous_log_writer 3 1
```

Open `http://onlylogs.localhost:3000/onlylogs` in your browser and watch logs appear as the script writes them.

### Latency Simulation

For testing how onlylogs behaves under production-like network conditions, you can simulate latency for HTTP requests
and WebSocket connections using the included latency simulation tool.

**Parameters:**

- **Latency** (default: 120ms): The base network delay added to all traffic
- **Jitter** (default: 30ms): Random variation (±) applied to the latency (changes every 2 seconds to simulate real
  network conditions)
- **Port** (default: 3000): The port to apply latency simulation to

**Common scenarios:**

```bash
# Default: 120ms ±30ms jitter (simulates typical 4G/LTE conditions)
bin/simulate_latency enable

# High latency: 500ms (simulates poor connectivity)
bin/simulate_latency enable 500

# High latency with high variation: 300ms ±100ms (simulates unstable connections)
bin/simulate_latency enable 300/100

# Custom port: 120ms ±30ms on port 8080
bin/simulate_latency enable -p 8080
```

**Testing and monitoring:**

```bash
# Test the current latency configuration
bin/simulate_latency test

# Check current status and active pipes
bin/simulate_latency status

# Disable and restore normal network conditions
bin/simulate_latency disable
```

The `test` command will run 10 HTTP requests and 10 WebSocket connections, showing you the actual round-trip times and
helping you verify the latency is working as expected.

### Simulating a drain outage

To see how `HttpLogger` behaves when the drain is slow or broken, run a fake drain and a fake app in two terminals:

```bash
bin/fake_drain  # press a key to change its state: 2=200 5=500 3=503 4=413 h=hang s=slow r=reset d=down
bin/fake_app    # 5 "Puma threads" logging like Rails requests through HttpLogger
```

The dashboard shows request latency, CPU, memory, the queue, the circuit breaker, the spool and the drain counters.
A healthy app has a few % of CPU and no HTTP calls on request threads.

### Performance Testing

Performance tests require large log files that are not included in the repository. You can download them using the
provided script:

```bash
bin/download_performance_fixtures
```

Once the fixtures are downloaded, you can run the performance tests locally:

```bash
bin/rails test test/models/onlylogs/grep_performance_test.rb
```

> [!NOTE]
> Performance tests are automatically skipped in CI environments or if the large fixture files are missing.

### Plans for the future

We believe that by simply analysing your logs you can also get error reports and performance reports. The goal is to
need no external service for logs, errors and performance.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
