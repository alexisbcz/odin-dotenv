# dotenv

[![CI](https://github.com/alexisbcz/odin-dotenv/actions/workflows/ci.yml/badge.svg)](https://github.com/alexisbcz/odin-dotenv/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09-1e5a99.svg)](https://odin-lang.org)

`dotenv` parses `.env` files into a map and can load them into the process environment, with quotes, escapes, multiline values and `${VAR}` expansion.

## Install

The repository root is the package, so you can vendor it in two ways.

As a Git submodule inside your project:

```sh
git submodule add https://github.com/alexisbcz/odin-dotenv libs/dotenv
```

```odin
import "libs/dotenv"
```

As a copy in a shared collection that all your projects use:

```sh
git clone https://github.com/alexisbcz/odin-dotenv ~/odin-shared/dotenv
odin build . -collection:shared=$HOME/odin-shared
```

```odin
import "shared:dotenv"
```

## Quick start

Load `.env` from the current directory at startup. Variables that the shell already set keep their values.

```odin
package main

import "core:fmt"
import "core:os"
import "shared:dotenv"

main :: proc() {
	if err, loc := dotenv.load(); err != nil {
		fmt.eprintfln(".env:%d:%d: %v", loc.line, loc.column, err)
		os.exit(1)
	}
	port := os.get_env("PORT", context.allocator)
	defer delete(port)
	fmt.println("listening on port", port)
}
```

To read the variables without changing the process environment, parse them into an `Env`:

```odin
package main

import "core:fmt"
import "shared:dotenv"

main :: proc() {
	env, err, loc := dotenv.parse("HOST=localhost\nURL=http://${HOST}:${PORT:-8080}\n")
	if err != nil {
		fmt.eprintfln("%d:%d: %v", loc.line, loc.column, err)
		return
	}
	defer dotenv.env_destroy(&env)

	for key in env.keys {
		fmt.printfln("%s=%s", key, env.vars[key])
	}
	// HOST=localhost
	// URL=http://localhost:8080
}
```

## Syntax

```sh
# Full-line comments start with a hash.
export APP_ENV=production        # an `export ` prefix is ignored
NAME = plain value               # whitespace around the key and value is trimmed
COLOR=#ff0000                    # a hash starts a comment only after whitespace
GREETING="hello\tworld\n"        # double quotes process escapes
RAW='kept $AS \written'          # single quotes keep text as written
CERT="-----BEGIN-----
multiline values work in both kinds of quotes
-----END-----"
URL=https://${HOST:-localhost}:$PORT/
```

| Form | Meaning |
| --- | --- |
| `KEY=value` | Keys match `[A-Za-z_][A-Za-z0-9_.]*`. A later line with the same key replaces the value. |
| `'value'` | Literal text. No escapes, no expansion. May span lines. |
| `"value"` | Escapes `\n`, `\r`, `\t`, `\\`, `\"`, `\'`, `\$` and `\}`. Expansion applies. May span lines. |
| `$NAME`, `${NAME}` | The value of `NAME`. Unset names expand to an empty string. |
| `${NAME:-word}` | `word` when `NAME` is unset or empty. |
| `${NAME-word}` | `word` when `NAME` is unset. |
| `${NAME:?message}` | Fails with `.Required_Variable_Unset` when `NAME` is unset or empty. |
| `${NAME?message}` | Fails with `.Required_Variable_Unset` when `NAME` is unset. |
| `\$` | A literal dollar sign in unquoted and double-quoted values. |

Expansion looks up keys defined earlier in the same input first, then the process environment. Defaults can nest, as in `${A:-${B:-none}}`. The parser accepts CRLF line endings and a leading UTF-8 byte order mark.

## API overview

| Declaration | Purpose | Allocates | Free with |
| --- | --- | --- | --- |
| `parse(src, options, allocator)` | Parse `.env` text into an `Env` | Yes | `env_destroy` |
| `parse_file(path, options, allocator)` | Read and parse a file | Yes | `env_destroy` |
| `load(path, options, allocator)` | Parse a file and apply it to the process environment | Scratch only | Not needed |
| `env_apply(env, overwrite, allocator)` | Copy an `Env` into the process environment | Scratch only | Not needed |
| `env_get(env, key)` | Look up one value | No | Not needed |
| `env_destroy(env)` | Free an `Env` and everything it owns | No | Not needed |
| `Env` | `vars` map plus `keys` in definition order | Not by itself | `env_destroy` |
| `Options` | `disable_expansion`, `ignore_process_env`, `overwrite` | No | Not needed |
| `Error` | Union of `Parse_Error`, `os.Error` and `runtime.Allocator_Error` | No | Not needed |
| `Location` | 1-based line and column of a `Parse_Error` | No | Not needed |

The zero `Options{}` is the recommended default. To give one file precedence over another, call `load` on the more important file first, because `load` never replaces a variable that's already set unless `overwrite` is true.

## Errors

Malformed input returns a `Parse_Error` and the `Location` of the offending character:

| `Parse_Error` | Cause |
| --- | --- |
| `.Invalid_Key` | A line doesn't start with a valid key, as in `1KEY=x` or `MY-KEY=x`. |
| `.Missing_Equals` | A key has no `=`, as in `export KEY`. |
| `.Unterminated_Quote` | A quoted value never closes. The location points at the opening quote. |
| `.Invalid_Escape` | A double-quoted value contains an unsupported escape such as `\q`. |
| `.Trailing_Characters` | Text follows a closing quote, as in `KEY="a"b`. |
| `.Unterminated_Expansion` | A `${` has no `}` on the same line or inside its quotes. |
| `.Invalid_Expansion` | A `${}` with an empty or invalid name, or an operator other than `-` and `?`. |
| `.Required_Variable_Unset` | A `${NAME:?}` or `${NAME?}` check failed. |
| `.Invalid_Character` | A value contains a NUL byte, which the process environment can't hold. |

On any error, `parse` returns a zero `Env`, and `load` sets no variables.

## Examples

Each directory under `examples/` is a runnable program:

```sh
odin run examples/basic
```

## Design notes

- Every allocating procedure takes `allocator := context.allocator`. An `Env` owns copies of its keys and values and never borrows from the input.
- Parsing procedures return `(Env, Error, Location)`, `load` returns `(Error, Location)` and `env_apply` returns `Error`. The library never panics on bad input.
- Parsing is a single pass over the input with no regular expressions.
- An `Env` is safe to use from one thread at a time. The process environment is global, so don't call `load` or `env_apply` while other threads read or write it.

## Testing

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do
vale sync && vale *.md
```

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Commits follow Conventional Commits, and every change that users can see gets a line in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
