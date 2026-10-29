/*
Package dotenv parses `.env` files and loads them into the process environment.

The parser understands the syntax that most dotenv tools share:

	# Comments start with a hash.
	export APP_ENV=production       # an optional `export ` prefix is ignored
	NAME=plain value                # unquoted values are trimmed
	GREETING="hello\nworld"         # double quotes process escapes
	RAW='no $EXPANSION or \escapes' # single quotes keep text as written
	CERT="-----BEGIN-----
	multiline values are fine
	-----END-----"
	URL=https://${HOST:-localhost}:${PORT-8080}/

Variable expansion with `$NAME` or `${NAME}` works in unquoted and
double-quoted values. Names resolve against keys defined earlier in the same
input first, then against the process environment.

Example:
	import "shared:dotenv"

	main :: proc() {
		// Load ./.env into the process environment, keeping variables
		// that are already set.
		if err, loc := dotenv.load(); err != nil {
			fmt.eprintfln(".env:%d:%d: %v", loc.line, loc.column, err)
		}
	}
*/
package dotenv

import "base:runtime"
import "core:os"

/*
Parse_Error lists the ways that `.env` input can be malformed. The
accompanying Location points at the offending character.
*/
Parse_Error :: enum {
	None,
	// A line doesn't start with a valid key. Keys match `[A-Za-z_][A-Za-z0-9_.]*`.
	Invalid_Key,
	// A key isn't followed by `=`.
	Missing_Equals,
	// A single- or double-quoted value has no closing quote.
	Unterminated_Quote,
	// A double-quoted value contains a backslash escape that isn't supported.
	Invalid_Escape,
	// Something other than whitespace or a comment follows a closing quote.
	Trailing_Characters,
	// A `${` expansion has no closing `}` on the same line or inside its quotes.
	Unterminated_Expansion,
	// A `${...}` expansion has an empty or invalid name, or an unknown operator.
	Invalid_Expansion,
	// A `${NAME:?}` or `${NAME?}` expansion names a variable that isn't set.
	Required_Variable_Unset,
	// A value contains a NUL byte, which the process environment can't hold.
	Invalid_Character,
}

/*
Error is the compound error type returned by every fallible procedure in this
package. `nil` means success.

- Parse_Error: the input is malformed.
- os.Error: reading a file or setting a process variable failed.
- runtime.Allocator_Error: an allocation failed.
*/
Error :: union #shared_nil {
	Parse_Error,
	os.Error,
	runtime.Allocator_Error,
}

/*
Location is a 1-based line and column (in bytes) inside the parsed input. On
success it's the zero value.
*/
Location :: struct {
	line:   int,
	column: int,
}

/*
Options changes how parse, parse_file and load behave. The zero value is the
recommended default: expansion on, process environment visible, and existing
process variables kept.
*/
Options :: struct {
	// Treat `$` as a literal character everywhere.
	disable_expansion:  bool,
	// Resolve expansions only against keys from the same input, never the process environment.
	ignore_process_env: bool,
	// Let load and env_apply replace process variables that are already set.
	overwrite:          bool,
}

/*
Env holds the variables parsed from one input.

Create it with parse or parse_file and release it with env_destroy. `vars`
maps each key to its final, expanded value. `keys` lists each key once, in the
order it first appeared. Both share the same key strings, which the Env owns.

When a key appears more than once, the last value wins and the key keeps its
first position in `keys`.

An Env is safe to use from one thread at a time.
*/
Env :: struct {
	vars:      map[string]string,
	keys:      [dynamic]string,
	allocator: runtime.Allocator,
}

/*
env_destroy frees every key, every value and both containers of `env`, then
zeroes it. Calling it on a zero Env is safe.
*/
env_destroy :: proc(env: ^Env) {
	for key, value in env.vars {
		delete(key, env.allocator)
		delete(value, env.allocator)
	}
	delete(env.vars)
	delete(env.keys)
	env^ = {}
}

/*
env_get returns the value of `key` in `env`.

Returns:
- value: borrowed from `env`; it stays valid until env_destroy.
- ok: false when `env` has no such key.
*/
env_get :: proc(env: Env, key: string) -> (value: string, ok: bool) {
	return env.vars[key]
}

/*
parse parses `.env` text.

Inputs:
- src: the text to parse. The result doesn't borrow from it.
- options: see Options. Only `disable_expansion` and `ignore_process_env` apply.
- allocator: allocates the Env and scratch memory.

Returns:
- env: the parsed variables, owned by the caller; free with env_destroy. Zero on error.
- err: a Parse_Error, or an allocator error.
- loc: where a Parse_Error happened; zero on success.

Example:
	env, err, loc := dotenv.parse("PORT=8080\nURL=http://localhost:${PORT}\n")
	if err != nil {
		fmt.eprintfln("%d:%d: %v", loc.line, loc.column, err)
		return
	}
	defer dotenv.env_destroy(&env)
	fmt.println(env.vars["URL"]) // http://localhost:8080
*/
parse :: proc(src: string, options := Options{}, allocator := context.allocator) -> (env: Env, err: Error, loc: Location) {
	return _parse(src, options, allocator)
}

/*
parse_file reads the file at `path` and parses it like parse.

Inputs:
- path: the file to read.
- options: see Options. Only `disable_expansion` and `ignore_process_env` apply.
- allocator: allocates the Env and scratch memory, including the file contents.

Returns:
- env: the parsed variables, owned by the caller; free with env_destroy. Zero on error.
- err: an os.Error when reading fails, a Parse_Error, or an allocator error.
- loc: where a Parse_Error happened; zero otherwise.
*/
parse_file :: proc(path: string, options := Options{}, allocator := context.allocator) -> (env: Env, err: Error, loc: Location) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return {}, read_err, {}
	}
	defer delete(data, allocator)
	return _parse(string(data), options, allocator)
}
