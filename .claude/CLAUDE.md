# onlylogs

onlylogs is a Rails **engine** to visualize and search the log files for the Application.
There is no top-level application, only a dummy app in `../test/dummy`, which mounts the engine.

## Running the dev server

`bin/rails` at the repo root already points `APP_PATH` at `../test/dummy`.

```bash
bin/rails server
```

Then open http://onlylogs.localhost:3000/onlylogs. 
The viewer is mounted at `/onlylogs`;
The root path is just an index of test log files.

## Testing "live" mode

Live mode tails a file over a websocket, so it needs something appending to that file. 
Use  the continuous log writer in a second terminal while the server runs:

```bash
bin/continuous_log_writer 3 1
```

It appends to `test/dummy/log/development.log` and runs until Ctrl+C.

To confirm streaming actually works:
* the line count in the status row should climb while the writer runs
* the connection dot should be `websocket-status--connected`. 

`test/dummy/log/*.log` is gitignored, so generated logs need no cleanup for git's sake. 
