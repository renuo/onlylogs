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

## Installation

Add this line to your application's Gemfile:

```ruby
gem "onlylogs"
```

And then execute:

```bash
$ bundle
```

## Contributing

Yes, sure. Do it.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
