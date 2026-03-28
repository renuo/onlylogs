# Stream Logs to onlylogs.io

If self-hosting your logs is not what you want, [onlylogs.io](https://onlylogs.io) has you covered.

There are many reasons why you might not want to self-host your logs or why it might not be possible.
For example, if you have an ephemeral disk like on Heroku or deploio, or if you want to make sure your logs live in a
space separated from your application.

This section explains how to stream or drain your logs to [onlylogs.io](https://onlylogs.io).

On the [onlylogs.io website](https://onlylogs.io), you can create a new project and receive a `ONLYLOGS_DRAIN_URL`.
To start receiving logs, configure your log drain using one of the methods below.

## Heroku

Heroku supports log drains, so you can configure it in one command:

```sh
heroku drains:add <ONLYLOGS_DRAIN_URL>
```

## Dokku

Dokku also supports log drains via [Vector](https://vector.dev/):

```sh
dokku logs:set <app-name> --vector-sink url=<ONLYLOGS_DRAIN_URL>
```

## Rails

Set up a `SocketLogger` in your production environment:

```ruby
# config/environments/production.rb
config.logger = Onlylogs::SocketLogger.new
```

This will write your logs to a `ONLYLOGS_SIDECAR_SOCKET` (default: `tmp/sockets/onlylogs-sidecar.sock`).

From there, you can stream them to [onlylogs.io](https://onlylogs.io) using a Puma sidecar process:

```ruby
# config/puma.rb
plugin :onlylogs_sidecar
```

Finally, configure the `ONLYLOGS_DRAIN_URL` environment variable.

If you prefer, you can run the sidecar process separately:

```sh
bin/onlylogs_sidecar
```

## Vector

The entire streaming process is compatible with [Vector](https://vector.dev/).
This means that you can set `ONLYLOGS_DRAIN_URL` to any Vector-compatible sink, or use Vector to read from the socket
and stream to [onlylogs.io](https://onlylogs.io) or other sinks.

The drain endpoint on [onlylogs.io](https://onlylogs.io) is itself a Vector-compatible sink.
