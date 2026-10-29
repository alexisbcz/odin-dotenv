package dotenv

import "base:runtime"
import "core:os"
import "core:strings"

@(private = "file")
UTF8_BOM :: "\xEF\xBB\xBF"

// Parser walks the source once. Values are built in `buf` and cloned into the Env.
@(private = "file")
Parser :: struct {
	src:       string,
	pos:       int,
	options:   Options,
	env:       ^Env,
	buf:       [dynamic]byte,
	allocator: runtime.Allocator,
	// Byte offset of the character that caused the last Parse_Error.
	err_pos:   int,
}

@(private)
_parse :: proc(src: string, options: Options, allocator: runtime.Allocator) -> (env: Env, err: Error, loc: Location) {
	env.allocator = allocator
	env.vars = make(map[string]string, allocator)
	env.keys = make([dynamic]string, allocator)

	p := Parser {
		src       = src,
		options   = options,
		env       = &env,
		buf       = make([dynamic]byte, allocator),
		allocator = allocator,
	}
	defer delete(p.buf)

	if strings.has_prefix(src, UTF8_BOM) {
		p.pos = len(UTF8_BOM)
	}

	for p.pos < len(p.src) {
		err = parse_line(&p)
		if err != nil {
			if _, is_parse := err.(Parse_Error); is_parse {
				loc = location_of(src, p.err_pos)
			}
			env_destroy(&env)
			return {}, err, loc
		}
	}
	return env, nil, {}
}

// location_of turns a byte offset into a 1-based line and column.
@(private = "file")
location_of :: proc(src: string, at: int) -> Location {
	line, line_start := 1, 0
	for i in 0 ..< min(at, len(src)) {
		if src[i] == '\n' {
			line += 1
			line_start = i + 1
		}
	}
	if line == 1 && strings.has_prefix(src, UTF8_BOM) && at >= len(UTF8_BOM) {
		line_start = len(UTF8_BOM)
	}
	return {line = line, column = at - line_start + 1}
}

@(private = "file")
fail :: proc(p: ^Parser, e: Parse_Error, at: int) -> Error {
	p.err_pos = at
	return e
}

@(private = "file")
is_space :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t'
}

@(private = "file")
is_name_start :: proc(c: byte) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private = "file")
is_name_char :: proc(c: byte) -> bool {
	return is_name_start(c) || (c >= '0' && c <= '9')
}

// at_eol reports whether the parser sits at a line ending or the end of input.
@(private = "file")
at_eol :: proc(p: ^Parser) -> bool {
	if p.pos >= len(p.src) {
		return true
	}
	switch p.src[p.pos] {
	case '\n':
		return true
	case '\r':
		return p.pos + 1 >= len(p.src) || p.src[p.pos + 1] == '\n'
	}
	return false
}

@(private = "file")
skip_spaces :: proc(p: ^Parser) {
	for p.pos < len(p.src) && is_space(p.src[p.pos]) {
		p.pos += 1
	}
}

// skip_line moves past the rest of the current line, including its line ending.
@(private = "file")
skip_line :: proc(p: ^Parser) {
	for p.pos < len(p.src) && p.src[p.pos] != '\n' {
		p.pos += 1
	}
	if p.pos < len(p.src) {
		p.pos += 1
	}
}

// read_name reads a key, or an empty string when none starts here.
@(private = "file")
read_name :: proc(p: ^Parser, allow_dots: bool) -> string {
	start := p.pos
	if p.pos >= len(p.src) || !is_name_start(p.src[p.pos]) {
		return ""
	}
	p.pos += 1
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		if !is_name_char(c) && !(allow_dots && c == '.') {
			break
		}
		p.pos += 1
	}
	return p.src[start:p.pos]
}

@(private = "file")
emit_byte :: proc(p: ^Parser, c: byte) -> Error {
	_ = append(&p.buf, c) or_return
	return nil
}

@(private = "file")
emit_string :: proc(p: ^Parser, s: string) -> Error {
	_ = append(&p.buf, s) or_return
	return nil
}

@(private = "file")
parse_line :: proc(p: ^Parser) -> Error {
	skip_spaces(p)
	if at_eol(p) || p.src[p.pos] == '#' {
		skip_line(p)
		return nil
	}

	key := read_name(p, allow_dots = true)
	if key == "export" && p.pos < len(p.src) && is_space(p.src[p.pos]) {
		after_export := p.pos
		skip_spaces(p)
		if p.pos < len(p.src) && is_name_start(p.src[p.pos]) {
			key = read_name(p, allow_dots = true)
		} else {
			p.pos = after_export
		}
	}
	if key == "" {
		return fail(p, .Invalid_Key, p.pos)
	}

	skip_spaces(p)
	if at_eol(p) || p.src[p.pos] == '#' {
		return fail(p, .Missing_Equals, p.pos)
	}
	if p.src[p.pos] != '=' {
		return fail(p, .Invalid_Key, p.pos)
	}
	p.pos += 1
	skip_spaces(p)

	clear(&p.buf)
	quoted := true
	switch {
	case p.pos < len(p.src) && p.src[p.pos] == '\'':
		parse_single_quoted(p) or_return
	case p.pos < len(p.src) && p.src[p.pos] == '"':
		parse_double_quoted(p) or_return
	case:
		quoted = false
		parse_unquoted(p) or_return
	}

	if quoted {
		skip_spaces(p)
		if !at_eol(p) && p.src[p.pos] != '#' {
			return fail(p, .Trailing_Characters, p.pos)
		}
	}
	skip_line(p)
	return set_var(p, key, string(p.buf[:]))
}

/*
set_var stores a copy of `key` and `value`, replacing any earlier value. It
leaves the Env unchanged when an allocation fails.
*/
@(private = "file")
set_var :: proc(p: ^Parser, key, value: string) -> Error {
	owned_value := strings.clone(value, p.allocator) or_return
	key_ptr, value_ptr, just_inserted, entry_err := map_entry(&p.env.vars, key)
	if entry_err != nil {
		delete(owned_value, p.allocator)
		return entry_err
	}
	if !just_inserted {
		delete(value_ptr^, p.allocator)
		value_ptr^ = owned_value
		return nil
	}

	// The new entry borrows `key` from the source until it gets its own copy.
	owned_key, err := strings.clone(key, p.allocator)
	if err == nil {
		_, err = append(&p.env.keys, owned_key)
	}
	if err != nil {
		delete_key(&p.env.vars, key)
		delete(owned_key, p.allocator)
		delete(owned_value, p.allocator)
		return err
	}
	key_ptr^ = owned_key
	value_ptr^ = owned_value
	return nil
}

@(private = "file")
parse_single_quoted :: proc(p: ^Parser) -> Error {
	open := p.pos
	p.pos += 1
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		switch {
		case c == '\'':
			p.pos += 1
			return nil
		case c == '\r' && p.pos + 1 < len(p.src) && p.src[p.pos + 1] == '\n':
			// Normalize CRLF inside multiline values to LF.
			p.pos += 1
		case:
			emit_byte(p, c) or_return
			p.pos += 1
		}
	}
	return fail(p, .Unterminated_Quote, open)
}

// decode_escape maps the character after a backslash inside double quotes.
@(private = "file")
decode_escape :: proc(c: byte) -> (decoded: byte, ok: bool) {
	switch c {
	case 'n':
		return '\n', true
	case 'r':
		return '\r', true
	case 't':
		return '\t', true
	case '\\', '"', '\'', '$', '}':
		return c, true
	}
	return 0, false
}

@(private = "file")
parse_double_quoted :: proc(p: ^Parser) -> Error {
	open := p.pos
	p.pos += 1
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		switch c {
		case '"':
			p.pos += 1
			return nil
		case '\\':
			if p.pos + 1 >= len(p.src) {
				return fail(p, .Unterminated_Quote, open)
			}
			decoded, ok := decode_escape(p.src[p.pos + 1])
			if !ok {
				return fail(p, .Invalid_Escape, p.pos)
			}
			emit_byte(p, decoded) or_return
			p.pos += 2
		case '$':
			if p.options.disable_expansion {
				emit_byte(p, c) or_return
				p.pos += 1
			} else {
				expand(p, '"', true) or_return
			}
		case '\r':
			if p.pos + 1 < len(p.src) && p.src[p.pos + 1] == '\n' {
				p.pos += 1
				continue
			}
			emit_byte(p, c) or_return
			p.pos += 1
		case:
			emit_byte(p, c) or_return
			p.pos += 1
		}
	}
	return fail(p, .Unterminated_Quote, open)
}

/*
parse_unquoted reads up to the end of the line or an inline comment. A `#`
starts a comment only after whitespace. Trailing whitespace is dropped, but
whitespace produced by an expansion is kept.
*/
@(private = "file")
parse_unquoted :: proc(p: ^Parser) -> Error {
	keep := 0
	for !at_eol(p) {
		c := p.src[p.pos]
		if c == '#' && p.pos > 0 && is_space(p.src[p.pos - 1]) {
			break
		}
		switch {
		case c == '\\' && p.pos + 1 < len(p.src) && p.src[p.pos + 1] == '$':
			emit_byte(p, '$') or_return
			p.pos += 2
			keep = len(p.buf)
		case c == '$' && !p.options.disable_expansion:
			expand(p, 0, true) or_return
			keep = len(p.buf)
		case is_space(c):
			emit_byte(p, c) or_return
			p.pos += 1
		case:
			emit_byte(p, c) or_return
			p.pos += 1
			keep = len(p.buf)
		}
	}
	resize(&p.buf, keep)
	return nil
}

/*
lookup resolves `name` against the keys parsed so far, then the process
environment. When `allocated` is true the caller must delete `value`.
*/
@(private = "file")
lookup :: proc(p: ^Parser, name: string) -> (value: string, found: bool, allocated: bool) {
	if v, ok := p.env.vars[name]; ok {
		return v, true, false
	}
	if p.options.ignore_process_env {
		return "", false, false
	}
	value, found = os.lookup_env(name, p.allocator)
	return value, found, found
}

// ends_expansion reports whether the character at `pos` can't be part of a `${...}` body.
@(private = "file")
ends_expansion :: proc(p: ^Parser, quote: byte) -> bool {
	if p.pos >= len(p.src) {
		return true
	}
	c := p.src[p.pos]
	return c == '\n' || c == '\r' || (quote != 0 && c == quote)
}

/*
expand handles a `$` at p.pos inside a value whose quote character is `quote`
(0 when unquoted). When `emit` is false it only validates and skips the
expansion, which is how unused defaults are parsed.
*/
@(private = "file")
expand :: proc(p: ^Parser, quote: byte, emit: bool) -> Error {
	start := p.pos
	p.pos += 1

	if p.pos < len(p.src) && p.src[p.pos] == '{' {
		p.pos += 1
		name := read_name(p, allow_dots = true)
		if ends_expansion(p, quote) {
			return fail(p, .Unterminated_Expansion, start)
		}
		if name == "" {
			return fail(p, .Invalid_Expansion, start)
		}

		c := p.src[p.pos]
		if c == '}' {
			p.pos += 1
			if emit {
				emit_lookup(p, name) or_return
			}
			return nil
		}

		colon := c == ':'
		if colon {
			p.pos += 1
			if ends_expansion(p, quote) {
				return fail(p, .Unterminated_Expansion, start)
			}
		}
		op := p.src[p.pos]
		if op != '-' && op != '?' {
			return fail(p, .Invalid_Expansion, start)
		}
		p.pos += 1

		value, found, allocated := lookup(p, name)
		defer if allocated {
			delete(value, p.allocator)
		}
		use_fallback := !found || (colon && value == "")

		if op == '-' {
			if emit && !use_fallback {
				emit_string(p, value) or_return
			}
			return expansion_word(p, quote, start, emit && use_fallback)
		}

		// `?`: the word is a message for humans; parse and skip it.
		expansion_word(p, quote, start, false) or_return
		if emit {
			if use_fallback {
				return fail(p, .Required_Variable_Unset, start)
			}
			emit_string(p, value) or_return
		}
		return nil
	}

	if p.pos < len(p.src) && is_name_start(p.src[p.pos]) {
		name := read_name(p, allow_dots = false)
		if emit {
			emit_lookup(p, name) or_return
		}
		return nil
	}

	// A `$` that starts no expansion is literal.
	if emit {
		emit_byte(p, '$') or_return
	}
	return nil
}

@(private = "file")
emit_lookup :: proc(p: ^Parser, name: string) -> Error {
	value, _, allocated := lookup(p, name)
	defer if allocated {
		delete(value, p.allocator)
	}
	return emit_string(p, value)
}

/*
expansion_word reads the text after `:-`, `-`, `:?` or `?` up to and including
the closing `}`. It may contain nested expansions and backslash escapes.
*/
@(private = "file")
expansion_word :: proc(p: ^Parser, quote: byte, start: int, emit: bool) -> Error {
	for !ends_expansion(p, quote) {
		c := p.src[p.pos]
		switch c {
		case '}':
			p.pos += 1
			return nil
		case '$':
			expand(p, quote, emit) or_return
		case '\\':
			if p.pos + 1 >= len(p.src) {
				return fail(p, .Unterminated_Expansion, start)
			}
			next := p.src[p.pos + 1]
			decoded: byte
			ok: bool
			if quote == '"' {
				decoded, ok = decode_escape(next)
				if !ok {
					return fail(p, .Invalid_Escape, p.pos)
				}
			} else if next == '$' || next == '}' || next == '\\' {
				decoded, ok = next, true
			}
			if ok {
				if emit {
					emit_byte(p, decoded) or_return
				}
				p.pos += 2
			} else {
				if emit {
					emit_byte(p, c) or_return
				}
				p.pos += 1
			}
		case:
			if emit {
				emit_byte(p, c) or_return
			}
			p.pos += 1
		}
	}
	return fail(p, .Unterminated_Expansion, start)
}
