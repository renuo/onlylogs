<img alt="w:100px" src="app/assets/images/onlylogs/logo.png" width="400px"/>

We believe logs are enough. 

We believe logs in human-readable format are enough.

Stop streaming your logs to very expensive external services: just store your logs on disk.

When your application grows and you don't want to self-host your log files anymore, you can
stream them to https://onlylogs.io and continue enjoying the same features.

> [!IMPORTANT]
> https://onlylogs.io is still in beta. Send us an email to a@renuo.ch if you want access to the platform.

## Installation as self-hosted

If you already have a disk, you can just keep there also your log files (as well as you probably already do).

This section explains how to setup onlylogs to self host your logs and access them directly from your Rails app.

If instead you want to stream your logs to https://onlylogs.io, head to [the onlylogs.io instructions page](https://onlylogs.io/instructions).

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
```

Finally, you **must secure the engine**. Read the section dedicated to the [Authentication](#authentication).

> [!TIP]
> **Install ripgrep for Better Performance**.
> For optimal search performance, we recommend installing [ripgrep](https://github.com/BurntSushi/ripgrep).
> Onlylogs will automatically detect and use ripgrep if available.

## Usage

Head to `/onlylogs` and enjoy your logs streamed right into your face!

Here you can grep your logs with regular expressions.

> [!TIP]
> Onlylogs automatically detects and uses [ripgrep (rg)](https://github.com/BurntSushi/ripgrep) if available, which provides significantly faster search experience. 
> If ripgrep is not installed, onlylogs falls back to `grep`. 
> A warning icon (⚠️) will be displayed in the toolbar when using `grep` to indicate slower search performance.

## Authentication

Yes, we should do this right away, because this engine gives access to your log files, so you want to be sure.

The engine has one Controller and one ActionCable channel that **must be protected**.

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

### Basic Authentication Setup

Credentials can be configured using environment variables, Rails credentials, or programmatically.
Environment variables take precedence over Rails credentials.

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

When you need custom authentication logic beyond basic auth, 
you can override the default authentication by configuring a parent controller that defines the `authenticate_onlylogs_user!` method.

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

### WebSocket Authentication

Logs are streamed through a WebSocket connection, the Websocket is not protected, but in order to stream a file,
the file path must be white-listed (see section below) and the file path encrypted using `Onlylogs::SecureFilePath.encrypt`


## Customization

Onlylogs provides two ways to customize the appearance of the log viewer: CSS Variables and a complete style override.
Check the file [_log_container_styles.html.erb](app/views/onlylogs/shared/_log_container_styles.html.erb) for the complete list of CSS variables.

## Configuration

Check `configuration.rb` to see a list of all possible configuration.

### File Access Security

Onlylogs includes a secure file access system that prevents unauthorized access to files on your server. 
By default, onlylogs can access your Rails environment-specific log files (e.g., `log/development.log`, `log/production.log`).

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


### Configuring Code Editor for File Path Links

Onlylogs automatically detects file paths in log messages and converts them into clickable links that open in your preferred code editor.

For a complete list of supported editors, see [lib/onlylogs/editor_detector.rb](lib/onlylogs/editor_detector.rb).

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

#### Configuring Maximum Search Results

By default, onlylogs limits search results to 100,000 lines to prevent memory issues and ensure responsive performance. You can configure this limit based on your needs:

```ruby
# config/initializers/onlylogs.rb
Onlylogs.configure do |config|
  # Set a custom limit (e.g., 50,000 lines)
  config.max_line_matches = 50_000
  
  # Or remove the limit entirely (use with caution)
  config.max_line_matches = nil
end
```

### Filtering Log Lines with a Denylist

The `Onlylogs::Formatter` supports a denylist: an array of regular expressions that prevents matching lines from being logged. This is useful for filtering out noisy or irrelevant entries like health checks or asset requests.

```ruby
# config/environments/production.rb
config.logger = Onlylogs::Logger.new(Rails.root.join("log", "production.log"))
config.logger.formatter.denylist = [/health_check/, /ping/, /\.css\z/]
```

Any log message matching at least one pattern in the denylist will be silently dropped.

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

The dummy app will be available at `http://localhost:3000` and onlylogs at `http://localhost:3000/onlylogs`.

### Generating Test Logs

To test onlylogs with live log data, use the continuous log writer script. This is especially useful for testing real-time log streaming and UI behavior.

```bash
# Generate 1 log entry every 2 seconds (default)
./bin/continuous_log_writer

# Generate 5 log entries every 1 second
./bin/continuous_log_writer 5 1

# Generate 10 log entries every 3 seconds
./bin/continuous_log_writer 10 3
```

The script will write logs to `test/dummy/log/development.log`, which will appear in real-time in the onlylogs UI at `http://localhost:3000/onlylogs`. 

**Example workflow:**

```bash
# Terminal 1: Start the Rails app
cd test/dummy && bundle exec rails s

# Terminal 2: Generate test logs while viewing in the UI
./bin/continuous_log_writer 3 1
```

Open `http://localhost:3000/onlylogs` in your browser and watch logs appear as the script writes them.

### Latency Simulation

For testing how onlylogs behaves under production-like network conditions, you can simulate latency for HTTP requests and WebSocket connections using the included latency simulation tool.

**Parameters:**
- **Latency** (default: 120ms): The base network delay added to all traffic
- **Jitter** (default: 30ms): Random variation (±) applied to the latency (changes every 2 seconds to simulate real network conditions)
- **Port** (default: 3000): The port to apply latency simulation to

**Common scenarios:**

```bash
# Default: 120ms ±30ms jitter (simulates typical 4G/LTE conditions)
./bin/simulate_latency enable

# High latency: 500ms (simulates poor connectivity)
./bin/simulate_latency enable 500

# High latency with high variation: 300ms ±100ms (simulates unstable connections)
./bin/simulate_latency enable 300/100

# Custom port: 120ms ±30ms on port 8080
./bin/simulate_latency enable -p 8080


**Practical workflow:**

```bash
# Terminal 1: Start latency simulation with 200ms delay
./bin/simulate_latency enable 200

# Terminal 2: Start the Rails app
cd test/dummy && bundle exec rails s

# Terminal 3: Generate test logs
./bin/continuous_log_writer 5 1
```

Now open `http://localhost:3000/onlylogs` and observe how the UI performs with network latency. You'll notice slower response times and WebSocket updates taking longer.

**Testing and monitoring:**

```bash
# Test the current latency configuration
./bin/simulate_latency test

# Check current status and active pipes
./bin/simulate_latency status

# Disable and restore normal network conditions
./bin/simulate_latency disable
```

The `test` command will run 10 HTTP requests and 10 WebSocket connections, showing you the actual round-trip times and helping you verify the latency is working as expected.

### Performance Testing

Performance tests require large log files that are not included in the repository. You can download them using the provided script:

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

We believe that by simply analysing your logs you can also have a fancy errors report.
Yes, correct. You don't need Sentry either.

And you know what? You can get also performance reports.

All of a sudden you are 100% free from external services for three more things:

* logs
* errors
* performance


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
