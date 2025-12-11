<figure>
  <img alt="w:100px" src="app/assets/images/onlylogs/logo.png" width="400px"/>
  <figcaption>sexy logs</figcaption>
</figure>

We believe logs are enough. 

We believe logs in human-readable format are enough.

Stop streaming your logs to very expensive external services: just store your logs on disk.

We also believe that by simply analysing your logs you can also have a fancy errors report.
Yes, correct. You don't need Sentry either.

And you know what? You can get also performance reports 🤫

All of a sudden you are 100% free from external services for three more things:

* logs
* errors
* performance

When your application grows and youn don't want to self-host your log files anymore, you can
stream them to https://onlylogs.io and continue enjoying the same features.

> [!IMPORTANT]  
> At the current stage errors and performance monitoring are not yet available. It's all wishful thinking.

> [!IMPORTANT]
> https://onlylogs.io is still in beta. Send us an email if you want access to the platform.

## Installation

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

## Development & Contributing

You are more than welcome to help and contribute to this package.  

The app uses minitest and includes a dummy app, so getting started should be straightforward.

### Latency Simulation

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

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
