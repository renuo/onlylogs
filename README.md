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
