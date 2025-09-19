# Onlylogs

We believe logs are enough. Even more: we believe logs in human-readable format are enough.

Stop streaming your logs to very expensive external services: just store your logs on disk as you would do during
development and be happy.

You don't need more than this to get started with!

And we believe that by simply analysing your logs you can also have a fancy errors report.
Yes, correct. You don't need Sentry either.

And you know what? You can get also performance reports 🤫

All of a sudden you are 100% free from external services for three more things:

* logs
* errors
* performance

And we have one more good news for you: onlylogs does not even need a database 🥳

When your application grows and self-hosting your log files, for any reason, is not good enough for you anymore, you can
stream them to onlylogs.io and continue enjoying your feature.

## Usage

Head to `/onlylogs` and enjoy your logs streamed right into your face!

Here you can grep your logs with regular expressions.

**Performance Note:** Onlylogs automatically detects and uses [ripgrep (rg)](https://github.com/BurntSushi/ripgrep) if available, which provides significantly faster search performance. 
If ripgrep is not installed, onlylogs falls back to standard grep. 
A warning icon (⚠️) will be displayed in the toolbar when using standard grep to indicate slower search performance.


## Installation

Add this line to your application's Gemfile:

```ruby
gem "onlylogs"
```

And then execute:

```bash
$ bundle
```

### Installing ripgrep for Better Performance

For optimal search performance, we recommend installing [ripgrep](https://github.com/BurntSushi/ripgrep). Onlylogs will automatically detect and use ripgrep if available.

## Secure the Engine

The engine has one Controller and one ActionCable channel that **must be protected**.

Please be sure to secure them properly, because they give access to your log files.

**⚠️ IMPORTANT: By default, onlylogs endpoints are completely inaccessible until basic auth credentials are configured.**

### Basic Authentication Setup

Credentials can be configured using environment variables, Rails credentials, or programmatically. 
Environment variables take precedence over Rails credentials.

#### Environment Variables (Recommended)

Set the following environment variables:

```bash
export ONLYLOGS_BASIC_AUTH_USER="your_username"
export ONLYLOGS_BASIC_AUTH_PASSWORD="your_password"
```

#### Rails Credentials

Configure credentials in your Rails credentials file:

```yml
onlylogs:
  basic_auth_user: your_username
  basic_auth_password: your_password
```

#### Programmatic Configuration

User and password can also be configured programmatically:

```ruby
Onlylogs.configure do |config|
  config.basic_auth_user = "your_username"
  config.basic_auth_password = "your_password"
end
```

### Custom Authentication

If you need custom authentication logic beyond basic auth, you can override the default authentication by configuring a parent controller that defines the `authenticate_onlylogs_user!` method.

#### Using a Parent Controller

Configure a custom parent controller in your initializer:

```ruby
# config/initializers/onlylogs.rb
Onlylogs.configure do |config|
  config.disable_basic_authentication = true
  config.parent_controller = "ApplicationController" # or any other controller
end
```

#### Implementing Custom Authentication

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

For development or when using external authentication systems, you can disable basic authentication entirely:

```ruby
# config/initializers/onlylogs.rb
Onlylogs.configure do |config|
  config.disable_basic_authentication = true
end
```

### WebSocket Authentication

Logs are streamed through a WebSocket connection, the Websocket is not protected, but in order to stream a file,
the file path must be white-listed (see section below) and the file path encrypted using `Onlylogs::SecureFilePath.encrypt`

## Configuration

### File Access Security

Onlylogs includes a secure file access system that prevents unauthorized access to files on your server. By default, onlylogs can access your Rails environment-specific log files (e.g., `log/development.log`, `log/production.log`).

#### Configuring Allowed Files

You can configure which files onlylogs is allowed to access by creating a configuration initializer:

```ruby
# config/initializers/onlylogs.rb
Onlylogs.configure do |config|
  config.allowed_files = [
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

#### Configuring Default Log File Path

You can customize the default log file path that onlylogs uses when no specific file is provided:

```ruby
# config/initializers/onlylogs.rb
Onlylogs.configure do |config|
  # Set a custom default log file path
  config.default_log_file_path = Rails.root.join("log/custom_default.log").to_s
  
  # Or use a different directory structure
  config.default_log_file_path = Rails.root.join("logs", "#{Rails.env}.log").to_s
  
  # Or use an absolute path
  config.default_log_file_path = "/var/log/myapp/#{Rails.env}.log"
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
  config.allowed_files = [
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

#### Configuring Search Engine

You can manually configure which search engine to use although you should not need to do this.

```ruby
# config/initializers/onlylogs.rb
Onlylogs.configure do |config|
  # Force use of ripgrep (requires ripgrep to be installed)
  config.grep_command = :rg
  
  # Force use of standard grep
  config.grep_command = :grep
end
```

## Latency Simulation

For testing how onlylogs behaves under production-like network conditions, you can simulate latency for HTTP requests and WebSocket connections using the included latency simulation tool.

### Usage

```bash
# Enable latency simulation (120±30ms jitter on port 3000)
./bin/simulate_latency enable

# Enable custom latency simulation (150±30ms jitter on port 3000)
./bin/simulate_latency enable 150

# Enable custom latency and jitter (200±50ms jitter on port 3000)
./bin/simulate_latency enable 200/50

# Enable latency simulation on custom port (120±30ms jitter on port 8080)
./bin/simulate_latency enable -p 8080

# Enable custom latency and jitter on custom port (150±50ms jitter on port 8080)
./bin/simulate_latency enable 150/50 -p 8080

# Test the latency
./bin/simulate_latency test

# Check current status
./bin/simulate_latency status

# Disable and clean up
./bin/simulate_latency disable
```


## Contributing

Yes, sure. Do it.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
