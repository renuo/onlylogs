# Changelog

## Unreleased

- **`HttpLogger`'s in-memory queue is bounded by bytes instead of lines.** The old cap of 10,000
  lines said nothing about memory: with lines of up to 1 MB that was a 10 GB worst case, and apps
  that log payloads routinely produce lines of 50-100 KB. The queue now holds at most
  `ONLYLOGS_MAX_QUEUE_BYTES` (32 MB); `ONLYLOGS_MAX_QUEUE_SIZE` and the `max_queue_size` option
  are gone.

## 0.10.0

- **`HttpLogger` no longer burns a CPU core and stalls every request.** The sender thread polled
  its queue in a tight loop whenever a partial batch waited for `flush_interval`, holding the GVL for
  up to 0.5 s per request regardless of the drain's health; it now blocks on the queue.
  `Rails.logger.flush`, which Rails calls after every request, no longer performs the HTTP delivery
  or spool writes on the request thread: it is the tag reset it inherits, and when to ship is the
  sender's decision alone (every 100 lines or 0.5 s). `close` stays synchronous.
- The spool keeps an in-memory byte ledger instead of listing and stat-ing every file on each write.
- **`HttpLogger` now works in forked processes (Puma cluster mode, `fork_worker`).** The logger is
  built in the Puma master and inherited by the workers, but threads do not survive a fork: every
  worker logged into a queue nobody read and, once it was full, dropped every line silently. The
  first write in a new process now rebuilds the queue, the keep-alive connection (previously shared
  with the siblings) and the spool token (previously identical across workers, so their batches
  overwrote each other) and starts a sender for that process.
- **The sender thread can no longer die.** Its own diagnostics on `$stderr` could raise (closed pipe,
  detached tty) from inside an error path, ending the thread for good; they never raise now, every
  loop iteration is rescued, and should the thread die anyway the next write restarts it.
- `bin/fake_drain` and `bin/fake_app` simulate a drain outage locally and show what it does to the
  app.
- **`HttpLogger` no longer retries batches the drain will never accept.** Every non-2xx used to be
  treated alike: a batch answered with 404 (unknown token), 403 (paused project) or 413 was spooled
  and, since replay stopped at the first failure, sat at the head of the spool blocking everything
  behind it until 128 MB of newer logs had been evicted. Now a 4xx drops the batch with one warning
  per cooldown period (and deletes it on replay), 429 pauses the sender for `Retry-After` and keeps
  the batch, and only 5xx, timeouts and connection errors count as an outage. Batch bodies and single
  lines are capped at `ONLYLOGS_MAX_BATCH_BYTES` (1 MB), so a 413 cannot happen by construction.
- **Recovery no longer floods the drain nor drops the live logs.** After an outage the spool was
  replayed in full, at full speed, before the sender returned to the live queue, which overflowed
  meanwhile; every client did so at the same moment. The backlog is now replayed one file per live
  batch (continuously while the app is idle), and the circuit cooldown is jittered between 0.5x
  and 1.5x so clients do not retry in lockstep.

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
