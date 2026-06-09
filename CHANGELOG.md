# Changelog

## 0.5.3

- Reuse Http connection.
- `HttpLogger` can now buffer undeliverable batches to disk and replay them when the drain
  recovers (and on the next boot), so a transient outage or a restart no longer loses logs.
- `HttpLogger` now treats a non-2xx response as a failed delivery.
- `HttpLogger` now accepts a drain URL without a path (e.g. `https://onlylogs.io`) and forwards any query string, instead of failing every send.

## 0.5.2

- `HttpLogger` now falls back to logging locally when `ONLYLOGS_DRAIN_URL` is not set, instead of silently dropping all log lines.

## 0.5.1

- Update URL parameters when updating the filter and regexp so that they are copy-pastable.

## 0.5.1

- Introduce logwriter for development purposes.
- Persist URL Options.
- Fix text highlighting in live mode.

## 0.5.0

- Add file download button next to log file selector.

## 0.4.5

- Fix compatibility with lograge.

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
