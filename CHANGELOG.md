# Changelog

## 0.4.4

- Remove favicons.
- Use HttpLogger in dummy app.
- Remove line numbers.

## 0.4.3

- Fix file switcher in apps with strict CSP rules.

## 0.4.2

- Avoid loops in the SocketLogger and improve the documentation.

## 0.4.1

- Remove the logo from the log viewer.

## 0.4.0

### Breaking Changes

- Renamed `config.allowed_files` to `config.log_file_patterns`.
- Renamed `Onlylogs.allowed_file_path?` to `Onlylogs.file_path_permitted?`.

### Features

- Added the possibility to view more files from the log viewer.

## 0.3.1

- Fix Deadlock bug in SocketLogger.

## 0.3.0
 
- Added denylist configuration for the formatter: an array of regular expressions to exclude matching log lines.

## 0.2.2

- Support for running without importmaps.
