# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-29

### Added

- `parse` and `parse_file` read `.env` text into an `Env` that keeps keys in definition order.
- Support for comments, the `export` prefix, single quotes, double quotes with escapes and multiline values.
- `$NAME` and `${NAME}` expansion with the `:-`, `-`, `:?` and `?` operators and nested defaults.
- `load` and `env_apply` copy variables into the process environment without replacing existing ones unless `Options.overwrite` is true.
- `Parse_Error` values with a 1-based line and column for malformed input.
- Support for CRLF line endings and a leading UTF-8 byte order mark.

[Unreleased]: https://github.com/alexisbcz/odin-dotenv/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/alexisbcz/odin-dotenv/releases/tag/v0.1.0
