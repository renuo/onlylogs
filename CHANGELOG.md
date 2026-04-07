# Changelog

## 0.4.0

### Breaking Changes

- Renamed `config.allowed_files` to `config.log_file_patterns` (configuration setting)
- Renamed `Onlylogs.allowed_file_path?` to `Onlylogs.file_path_permitted?` (security check)
- Renamed `Onlylogs.existing_allowed_files` to `Onlylogs.available_log_files` (file listing)

## 0.3.1

- Fix Deadlock bug in SocketLogger.

## 0.3.0
 
- Added denylist configuration for the formatter: an array of regular expressions to exclude matching log lines.

## 0.2.2

- Support for running without importmaps.
