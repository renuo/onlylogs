# Changelog

## 0.9.0

- **Every search is instrumented** as `search.onlylogs`. 
  Subscribe to record whatever your application wants recorded.
- **Viewer searches are now bounded.** A filtered search from the log viewer ran with no ceiling at
  all. It now stops at `config.search_timeout`, in seconds, default is 120.

## 0.8.0

- **Searching a byte range is now faster.**
- **Fixed windowed searches silently returning fewer matches than the file held.** The block count
  ignored the offset the read started from, so a window ending shortly before a block boundary came
  up short with no error and no indication of truncation. A 32,767 line window returned 24,956 lines.
- Kill the search subprocess and its whole pipeline when a search is abandoned. A timeout, a `break`
  out of the block or an exception now stops the work instead of blocking on `close` until the child
  finished scanning the file.
- `Onlylogs::Grep.grep` and `Onlylogs::File#grep` accept a `timeout:` in seconds and raise
  `Onlylogs::Grep::TimeoutError` (a `Timeout::Error`) when a search runs past it. It defaults to
  `nil`, meaning no deadline. The deadline is enforced by `timeout(1)`; without GNU coreutils the
  argument is ignored and only the caller's own deadline applies.
- Reject non-numeric `--start-position`/`--end-position` in the search scripts before they reach
  shell arithmetic expansion, which evaluates its contents as an expression.

## 0.7.0

- Fix wrong level filtering.

## 0.6.0

- Vendor clusterize.js.
- Set a maximum number of lines displayed in live mode.
- Introduce a Range slider.

## 0.5.4

- Use `--no-mmap` option to reduce memory allocation.

## 0.5.3

- Reuse Http connection.
- `HttpLogger` can now buffer undeliverable batches to disk and replay them when the drain.
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
