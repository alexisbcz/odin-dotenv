// Package dotenv_tests holds the unit tests for dotenv. Run them with `odin test tests`.
package dotenv_tests

import dotenv ".."
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// PURE parses without consulting the process environment, so tests stay hermetic.
PURE :: dotenv.Options{ignore_process_env = true}

// env_mutex serializes every test that reads or writes the process environment.
env_mutex: sync.Mutex

/*
leak_check wraps the current allocator in a tracking allocator. When the
calling test returns, it fails the test if anything leaked or was freed twice.
*/
@(deferred_in_out = leak_check_end)
leak_check :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator) -> runtime.Allocator {
	mem.tracking_allocator_init(track, context.allocator)
	return mem.tracking_allocator(track)
}

leak_check_end :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator, _: runtime.Allocator) {
	for _, entry in track.allocation_map {
		testing.expectf(t, false, "leaked %d bytes at %v", entry.size, entry.location)
	}
	for entry in track.bad_free_array {
		testing.expectf(t, false, "bad free at %v", entry.location)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
	mem.tracking_allocator_destroy(track)
}

expect_var :: proc(t: ^testing.T, env: dotenv.Env, key, want: string, loc := #caller_location) {
	got, ok := dotenv.env_get(env, key)
	testing.expectf(t, ok, "key %q is missing", key, loc = loc)
	testing.expect_value(t, got, want, loc = loc)
}

expect_one :: proc(t: ^testing.T, src, key, want: string, options := PURE, loc := #caller_location) {
	env, err, at := dotenv.parse(src, options)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil, loc = loc)
	testing.expect_value(t, at, dotenv.Location{}, loc = loc)
	expect_var(t, env, key, want, loc)
}

expect_error :: proc(t: ^testing.T, src: string, want: dotenv.Parse_Error, line, column: int, options := PURE, loc := #caller_location) {
	env, err, at := dotenv.parse(src, options)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, dotenv.Error(want), loc = loc)
	testing.expect_value(t, at, dotenv.Location{line = line, column = column}, loc = loc)
	testing.expect_value(t, len(env.keys), 0, loc = loc)
}

// ---- Basic syntax ----

@(test)
test_parse_empty_input :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	env, err, _ := dotenv.parse("", PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(env.vars), 0)
	testing.expect_value(t, len(env.keys), 0)
}

@(test)
test_parse_simple_pair :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "KEY=value\n", "KEY", "value")
}

@(test)
test_parse_keeps_definition_order :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	env, err, _ := dotenv.parse("C=3\nA=1\nB=2\n", PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(env.keys), 3)
	if len(env.keys) == 3 {
		testing.expect_value(t, env.keys[0], "C")
		testing.expect_value(t, env.keys[1], "A")
		testing.expect_value(t, env.keys[2], "B")
	}
}

@(test)
test_parse_trims_whitespace_around_key_and_value :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "  \tKEY \t= \t value with spaces \t \n", "KEY", "value with spaces")
}

@(test)
test_parse_empty_value :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "EMPTY=\n", "EMPTY", "")
	expect_one(t, "EMPTY=   \n", "EMPTY", "")
}

@(test)
test_parse_empty_value_before_comment :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "EMPTY= # nothing here\n", "EMPTY", "")
}

@(test)
test_parse_skips_comments_and_blank_lines :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	src := "# heading\n\n   \n\t# indented comment\nA=1\n\n#B=2\n"
	env, err, _ := dotenv.parse(src, PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(env.vars), 1)
	expect_var(t, env, "A", "1")
}

@(test)
test_parse_inline_comment_after_whitespace :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "A=value # comment\n", "A", "value")
	expect_one(t, "A=value\t# comment\n", "A", "value")
}

@(test)
test_parse_hash_without_whitespace_is_literal :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "COLOR=#ff0000\n", "COLOR", "#ff0000")
	expect_one(t, "URL=http://host/#anchor\n", "URL", "http://host/#anchor")
}

@(test)
test_parse_equals_inside_value :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "QUERY=a=1&b=2\n", "QUERY", "a=1&b=2")
}

@(test)
test_parse_export_prefix :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	env, err, _ := dotenv.parse("export A=1\nexport\tB=2\n  export   C = 3\n", PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(env.vars), 3)
	expect_var(t, env, "A", "1")
	expect_var(t, env, "B", "2")
	expect_var(t, env, "C", "3")
}

@(test)
test_parse_export_as_plain_key :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "export=yes\n", "export", "yes")
	expect_one(t, "export = yes\n", "export", "yes")
	expect_one(t, "exporter=yes\n", "exporter", "yes")
}

@(test)
test_parse_key_with_dots_digits_and_underscores :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "_app.db_2.host=localhost\n", "_app.db_2.host", "localhost")
	expect_one(t, "lower_case=ok\n", "lower_case", "ok")
}

@(test)
test_parse_duplicate_key_last_value_wins :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	env, err, _ := dotenv.parse("A=1\nB=2\nA=3\n", PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil)
	expect_var(t, env, "A", "3")
	testing.expect_value(t, len(env.keys), 2)
	if len(env.keys) == 2 {
		testing.expect_value(t, env.keys[0], "A")
		testing.expect_value(t, env.keys[1], "B")
	}
}

@(test)
test_parse_crlf_line_endings :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	env, err, _ := dotenv.parse("A=1\r\nB=two words\r\n# c\r\n\r\nC='x'\r\n", PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil)
	expect_var(t, env, "A", "1")
	expect_var(t, env, "B", "two words")
	expect_var(t, env, "C", "x")
}

@(test)
test_parse_skips_utf8_bom :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "\xEF\xBB\xBFKEY=value\n", "KEY", "value")
}

@(test)
test_parse_without_trailing_newline :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "A=1\nB=last", "B", "last")
	expect_one(t, "A=\"quoted\"", "A", "quoted")
}

@(test)
test_parse_utf8_values :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "GREETING=héllo wörld 日本\n", "GREETING", "héllo wörld 日本")
	expect_one(t, "GREETING=\"ça va\"\n", "GREETING", "ça va")
}

@(test)
test_parse_result_does_not_borrow_source :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	src := strings.clone("KEY=value\n")
	env, err, _ := dotenv.parse(src, PURE)
	defer dotenv.env_destroy(&env)
	delete(src)
	testing.expect_value(t, err, nil)
	expect_var(t, env, "KEY", "value")
}

// ---- Unquoted values ----

@(test)
test_unquoted_keeps_inner_quotes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "MSG=it's \"fine\"\n", "MSG", "it's \"fine\"")
}

@(test)
test_unquoted_keeps_backslashes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "DIR=C:\\Users\\odin\\n\n", "DIR", "C:\\Users\\odin\\n")
}

@(test)
test_unquoted_escaped_dollar_is_literal :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "PRICE=\\$HOME costs \\$5\n", "PRICE", "$HOME costs $5")
}

// ---- Single quotes ----

@(test)
test_single_quotes_are_literal :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "RAW='$HOME ${X:-y} \\n \"q\"'\n", "RAW", "$HOME ${X:-y} \\n \"q\"")
}

@(test)
test_single_quotes_keep_surrounding_whitespace :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "PAD='  padded  '  # comment\n", "PAD", "  padded  ")
}

@(test)
test_single_quotes_multiline :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "TEXT='line one\nline two'\nNEXT=1\n", "TEXT", "line one\nline two")
}

@(test)
test_single_quotes_hash_inside_is_literal :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "TAG='# not a comment'\n", "TAG", "# not a comment")
}

// ---- Double quotes ----

@(test)
test_double_quotes_process_escapes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, `ESC="a\nb\tc\rd\\e\"f\'g\$h\}i"` + "\n", "ESC", "a\nb\tc\rd\\e\"f'g$h}i")
}

@(test)
test_double_quotes_multiline :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	src := "CERT=\"-----BEGIN-----\nabc\n-----END-----\"\nAFTER=ok\n"
	env, err, _ := dotenv.parse(src, PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil)
	expect_var(t, env, "CERT", "-----BEGIN-----\nabc\n-----END-----")
	expect_var(t, env, "AFTER", "ok")
}

@(test)
test_double_quotes_multiline_normalizes_crlf :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "TEXT=\"one\r\ntwo\"\r\n", "TEXT", "one\ntwo")
	expect_one(t, "TEXT='one\r\ntwo'\r\n", "TEXT", "one\ntwo")
}

@(test)
test_double_quotes_allow_comment_after_closing_quote :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "A=\"value\"   # comment\n", "A", "value")
	expect_one(t, "A=\"value\"#comment\n", "A", "value")
}

@(test)
test_double_quotes_hash_inside_is_literal :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "PASS=\"p@ss #word\"\n", "PASS", "p@ss #word")
}

@(test)
test_empty_quoted_values :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "A=\"\"\n", "A", "")
	expect_one(t, "A=''\n", "A", "")
}

@(test)
test_quotes_nest_the_other_kind :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "A=\"say 'hi'\"\n", "A", "say 'hi'")
	expect_one(t, "A='say \"hi\"'\n", "A", "say \"hi\"")
}

// ---- Expansion ----

@(test)
test_expand_braced_reference :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "HOST=example.com\nURL=https://${HOST}/api\n", "URL", "https://example.com/api")
}

@(test)
test_expand_bare_reference :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "DIR=/srv\nLOG=$DIR/log\n", "LOG", "/srv/log")
}

@(test)
test_expand_bare_reference_stops_at_dot :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "NAME=app\nFILE=$NAME.log\n", "FILE", "app.log")
}

@(test)
test_expand_braced_reference_allows_dots :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "db.host=pg\nURL=${db.host}:5432\n", "URL", "pg:5432")
}

@(test)
test_expand_in_double_quotes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "USER=odin\nMSG=\"hi $USER, ${USER}!\"\n", "MSG", "hi odin, odin!")
}

@(test)
test_expand_undefined_is_empty :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "A=[${MISSING}][$MISSING]\n", "A", "[][]")
}

@(test)
test_expand_sees_only_earlier_keys :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	env, err, _ := dotenv.parse("A=${B}\nB=1\nC=${B}\n", PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil)
	expect_var(t, env, "A", "")
	expect_var(t, env, "C", "1")
}

@(test)
test_expand_colon_dash_default_on_unset_or_empty :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "A=${PORT:-8080}\n", "A", "8080")
	expect_one(t, "PORT=\nA=${PORT:-8080}\n", "A", "8080")
	expect_one(t, "PORT=3000\nA=${PORT:-8080}\n", "A", "3000")
}

@(test)
test_expand_dash_default_only_on_unset :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "A=${PORT-8080}\n", "A", "8080")
	expect_one(t, "PORT=\nA=[${PORT-8080}]\n", "A", "[]")
}

@(test)
test_expand_default_may_be_empty_or_have_spaces :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "A=[${X:-}]\n", "A", "[]")
	expect_one(t, "A=${X:-two words}\n", "A", "two words")
}

@(test)
test_expand_nested_default :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "B=fallback\nA=${X:-${Y:-$B}}\n", "A", "fallback")
	expect_one(t, "A=${X:-${Y:-last}}\n", "A", "last")
}

@(test)
test_expand_default_escapes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "A=${X:-a\\}b\\$c}\n", "A", "a}b$c")
	expect_one(t, "A=\"${X:-tab\\there}\"\n", "A", "tab\there")
}

@(test)
test_expand_skips_unused_default :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "X=set\nA=${X:-${NEVER:?required}}\n", "A", "set")
}

@(test)
test_expand_required_variable_present :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "KEY=secret\nA=${KEY:?KEY must be set}\n", "A", "secret")
	expect_one(t, "KEY=\nA=[${KEY?}]\n", "A", "[]")
}

@(test)
test_expand_required_variable_unset :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "A=1\nB=x${KEY:?KEY must be set}\n", .Required_Variable_Unset, 2, 4)
	expect_error(t, "B=${KEY?}\n", .Required_Variable_Unset, 1, 3)
}

@(test)
test_expand_required_colon_rejects_empty :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "KEY=\nA=${KEY:?}\n", .Required_Variable_Unset, 2, 3)
}

@(test)
test_lone_dollar_is_literal :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "A=cost: $ 5\n", "A", "cost: $ 5")
	expect_one(t, "A=$1 and $$\n", "A", "$1 and $$")
	expect_one(t, "A=\"end$\"\n", "A", "end$")
	expect_one(t, "A=end$\n", "A", "end$")
}

@(test)
test_expand_keeps_whitespace_from_expansion :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_one(t, "PAD=\" x \"\nA=$PAD\n", "A", " x ")
}

@(test)
test_expand_disabled_keeps_dollar_signs :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	options := dotenv.Options{disable_expansion = true, ignore_process_env = true}
	expect_one(t, "B=1\nA=$B ${B:-x}\n", "A", "$B ${B:-x}", options)
	expect_one(t, "A=\"$B \\$\"\n", "A", "$B $", options)
	// Malformed expansions aren't errors when expansion is off.
	expect_one(t, "A=${\n", "A", "${", options)
}

// ---- Process environment ----

@(test)
test_expand_falls_back_to_process_env :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	sync.guard(&env_mutex)

	testing.expect_value(t, os.set_env("DOTENV_TEST_FALLBACK", "from-process"), nil)
	defer os.unset_env("DOTENV_TEST_FALLBACK")
	expect_one(t, "A=${DOTENV_TEST_FALLBACK}\n", "A", "from-process", {})
	expect_one(t, "A=${DOTENV_TEST_FALLBACK:-unused}\n", "A", "from-process", {})
}

@(test)
test_expand_prefers_file_over_process_env :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	sync.guard(&env_mutex)

	testing.expect_value(t, os.set_env("DOTENV_TEST_PREFER", "process"), nil)
	defer os.unset_env("DOTENV_TEST_PREFER")
	expect_one(t, "DOTENV_TEST_PREFER=file\nA=$DOTENV_TEST_PREFER\n", "A", "file", {})
}

@(test)
test_expand_ignore_process_env_option :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	sync.guard(&env_mutex)

	testing.expect_value(t, os.set_env("DOTENV_TEST_IGNORED", "process"), nil)
	defer os.unset_env("DOTENV_TEST_IGNORED")
	expect_one(t, "A=[${DOTENV_TEST_IGNORED}]\n", "A", "[]", PURE)
}

@(test)
test_env_apply_sets_new_variables :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	sync.guard(&env_mutex)

	env, err, _ := dotenv.parse("DOTENV_TEST_APPLY_A=1\nDOTENV_TEST_APPLY_B='two words'\n", PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil)
	defer os.unset_env("DOTENV_TEST_APPLY_A")
	defer os.unset_env("DOTENV_TEST_APPLY_B")

	testing.expect_value(t, dotenv.env_apply(env), nil)
	a := os.get_env("DOTENV_TEST_APPLY_A", context.allocator)
	defer delete(a)
	b := os.get_env("DOTENV_TEST_APPLY_B", context.allocator)
	defer delete(b)
	testing.expect_value(t, a, "1")
	testing.expect_value(t, b, "two words")
}

@(test)
test_env_apply_keeps_existing_by_default :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	sync.guard(&env_mutex)

	testing.expect_value(t, os.set_env("DOTENV_TEST_KEEP", "original"), nil)
	defer os.unset_env("DOTENV_TEST_KEEP")

	env, err, _ := dotenv.parse("DOTENV_TEST_KEEP=replacement\n", PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, dotenv.env_apply(env), nil)

	got := os.get_env("DOTENV_TEST_KEEP", context.allocator)
	defer delete(got)
	testing.expect_value(t, got, "original")
}

@(test)
test_env_apply_keeps_existing_empty_variable :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	sync.guard(&env_mutex)

	testing.expect_value(t, os.set_env("DOTENV_TEST_EMPTY", ""), nil)
	defer os.unset_env("DOTENV_TEST_EMPTY")

	env, err, _ := dotenv.parse("DOTENV_TEST_EMPTY=filled\n", PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, dotenv.env_apply(env), nil)

	got, found := os.lookup_env("DOTENV_TEST_EMPTY", context.allocator)
	defer delete(got)
	testing.expect(t, found)
	testing.expect_value(t, got, "")
}

@(test)
test_env_apply_overwrite_replaces_existing :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	sync.guard(&env_mutex)

	testing.expect_value(t, os.set_env("DOTENV_TEST_OVERWRITE", "original"), nil)
	defer os.unset_env("DOTENV_TEST_OVERWRITE")

	env, err, _ := dotenv.parse("DOTENV_TEST_OVERWRITE=replacement\n", PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, dotenv.env_apply(env, overwrite = true), nil)

	got := os.get_env("DOTENV_TEST_OVERWRITE", context.allocator)
	defer delete(got)
	testing.expect_value(t, got, "replacement")
}

// ---- Files ----

// write_temp writes `contents` to a new file inside a fresh temporary directory.
write_temp :: proc(t: ^testing.T, contents: string) -> (dir, path: string) {
	err: os.Error
	dir, err = os.make_directory_temp("", "dotenv-test-*", context.allocator)
	testing.expect_value(t, err, nil)
	join_err: runtime.Allocator_Error
	path, join_err = os.join_path({dir, "test.env"}, context.allocator)
	testing.expect_value(t, join_err, nil)
	testing.expect_value(t, os.write_entire_file(path, contents), nil)
	return
}

remove_temp :: proc(dir, path: string) {
	os.remove_all(dir)
	delete(path)
	delete(dir)
}

@(test)
test_parse_file_reads_file :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	dir, path := write_temp(t, "# config\nNAME=odin\nGREETING=\"hello ${NAME}\"\n")
	defer remove_temp(dir, path)

	env, err, _ := dotenv.parse_file(path, PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil)
	expect_var(t, env, "GREETING", "hello odin")
}

@(test)
test_parse_file_missing_returns_os_error :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	env, err, loc := dotenv.parse_file("/definitely/not/here/.env", PURE)
	defer dotenv.env_destroy(&env)
	_, is_os := err.(os.Error)
	testing.expectf(t, is_os, "want an os.Error, got %v", err)
	testing.expect_value(t, loc, dotenv.Location{})
}

@(test)
test_parse_file_reports_parse_error_location :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	dir, path := write_temp(t, "A=1\nB=\"open\n")
	defer remove_temp(dir, path)

	env, err, loc := dotenv.parse_file(path, PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, dotenv.Error(dotenv.Parse_Error.Unterminated_Quote))
	testing.expect_value(t, loc, dotenv.Location{line = 2, column = 3})
}

@(test)
test_load_sets_process_env :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	sync.guard(&env_mutex)

	dir, path := write_temp(t, "export DOTENV_TEST_LOAD=loaded\n")
	defer remove_temp(dir, path)
	defer os.unset_env("DOTENV_TEST_LOAD")

	err, _ := dotenv.load(path)
	testing.expect_value(t, err, nil)
	got := os.get_env("DOTENV_TEST_LOAD", context.allocator)
	defer delete(got)
	testing.expect_value(t, got, "loaded")
}

@(test)
test_load_does_not_overwrite_by_default :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	sync.guard(&env_mutex)

	testing.expect_value(t, os.set_env("DOTENV_TEST_LOAD_KEEP", "shell"), nil)
	defer os.unset_env("DOTENV_TEST_LOAD_KEEP")
	dir, path := write_temp(t, "DOTENV_TEST_LOAD_KEEP=file\n")
	defer remove_temp(dir, path)

	err, _ := dotenv.load(path)
	testing.expect_value(t, err, nil)
	got := os.get_env("DOTENV_TEST_LOAD_KEEP", context.allocator)
	defer delete(got)
	testing.expect_value(t, got, "shell")
}

@(test)
test_load_overwrite_option :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	sync.guard(&env_mutex)

	testing.expect_value(t, os.set_env("DOTENV_TEST_LOAD_OVER", "shell"), nil)
	defer os.unset_env("DOTENV_TEST_LOAD_OVER")
	dir, path := write_temp(t, "DOTENV_TEST_LOAD_OVER=file\n")
	defer remove_temp(dir, path)

	err, _ := dotenv.load(path, {overwrite = true})
	testing.expect_value(t, err, nil)
	got := os.get_env("DOTENV_TEST_LOAD_OVER", context.allocator)
	defer delete(got)
	testing.expect_value(t, got, "file")
}

@(test)
test_load_first_file_wins :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	sync.guard(&env_mutex)

	local_dir, local_path := write_temp(t, "DOTENV_TEST_ORDER=local\n")
	defer remove_temp(local_dir, local_path)
	base_dir, base_path := write_temp(t, "DOTENV_TEST_ORDER=base\nDOTENV_TEST_ORDER_BASE=only-base\n")
	defer remove_temp(base_dir, base_path)
	defer os.unset_env("DOTENV_TEST_ORDER")
	defer os.unset_env("DOTENV_TEST_ORDER_BASE")

	err1, _ := dotenv.load(local_path)
	err2, _ := dotenv.load(base_path)
	testing.expect_value(t, err1, nil)
	testing.expect_value(t, err2, nil)

	order := os.get_env("DOTENV_TEST_ORDER", context.allocator)
	defer delete(order)
	only_base := os.get_env("DOTENV_TEST_ORDER_BASE", context.allocator)
	defer delete(only_base)
	testing.expect_value(t, order, "local")
	testing.expect_value(t, only_base, "only-base")
}

@(test)
test_load_parse_error_sets_nothing :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	sync.guard(&env_mutex)

	dir, path := write_temp(t, "DOTENV_TEST_PARTIAL=1\nBROKEN\n")
	defer remove_temp(dir, path)

	err, loc := dotenv.load(path)
	testing.expect_value(t, err, dotenv.Error(dotenv.Parse_Error.Missing_Equals))
	testing.expect_value(t, loc, dotenv.Location{line = 2, column = 7})
	_, found := os.lookup_env("DOTENV_TEST_PARTIAL", context.allocator)
	testing.expect(t, !found)
}

@(test)
test_load_missing_file_returns_os_error :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	err, _ := dotenv.load("/definitely/not/here/.env")
	_, is_os := err.(os.Error)
	testing.expectf(t, is_os, "want an os.Error, got %v", err)
}

// ---- Malformed input ----

@(test)
test_error_key_starting_with_digit :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "1KEY=value\n", .Invalid_Key, 1, 1)
}

@(test)
test_error_key_with_dash :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "MY-KEY=value\n", .Invalid_Key, 1, 3)
}

@(test)
test_error_key_with_space :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "MY KEY=value\n", .Invalid_Key, 1, 4)
}

@(test)
test_error_line_starting_with_equals :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "  =value\n", .Invalid_Key, 1, 3)
}

@(test)
test_error_missing_equals :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "A=1\nLONELY\n", .Missing_Equals, 2, 7)
	expect_error(t, "LONELY # comment\n", .Missing_Equals, 1, 8)
}

@(test)
test_error_export_without_assignment :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "export KEY\n", .Missing_Equals, 1, 11)
	expect_error(t, "export\n", .Missing_Equals, 1, 7)
}

@(test)
test_error_unterminated_double_quote :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "A=1\nB=\"never closed\nC=3\n", .Unterminated_Quote, 2, 3)
	expect_error(t, "B=\"ends in backslash\\", .Unterminated_Quote, 1, 3)
}

@(test)
test_error_unterminated_single_quote :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "A='open\n", .Unterminated_Quote, 1, 3)
}

@(test)
test_error_invalid_escape :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "PATH=\"C:\\dir\"\n", .Invalid_Escape, 1, 9)
	expect_error(t, "A=\"${X:-\\q}\"\n", .Invalid_Escape, 1, 9)
}

@(test)
test_error_trailing_characters_after_quote :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "A=\"b\"c\n", .Trailing_Characters, 1, 6)
	expect_error(t, "A='b'  c\n", .Trailing_Characters, 1, 8)
}

@(test)
test_error_unterminated_expansion :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "A=x${B\n", .Unterminated_Expansion, 1, 4)
	expect_error(t, "A=${B:-default\nC=1\n", .Unterminated_Expansion, 1, 3)
	expect_error(t, "A=${", .Unterminated_Expansion, 1, 3)
}

@(test)
test_error_unterminated_expansion_at_closing_quote :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "A=\"${B\"\n", .Unterminated_Expansion, 1, 4)
	expect_error(t, "A=\"${B:-x\"\n", .Unterminated_Expansion, 1, 4)
}

@(test)
test_error_invalid_expansion :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "A=${}\n", .Invalid_Expansion, 1, 3)
	expect_error(t, "A=${1X}\n", .Invalid_Expansion, 1, 3)
	expect_error(t, "A=${X+y}\n", .Invalid_Expansion, 1, 3)
	expect_error(t, "A=${X:=y}\n", .Invalid_Expansion, 1, 3)
}

@(test)
test_error_location_after_bom_and_crlf :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	expect_error(t, "\xEF\xBB\xBF-BAD=1\n", .Invalid_Key, 1, 1)
	expect_error(t, "A=1\r\nB=2\r\n  9=x\r\n", .Invalid_Key, 3, 3)
}

@(test)
test_error_leaves_env_zeroed :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	env, err, _ := dotenv.parse("A=1\nB=2\nC=\"\n", PURE)
	testing.expect(t, err != nil)
	testing.expect(t, env.vars == nil)
	testing.expect(t, env.keys == nil)
	dotenv.env_destroy(&env)
}

@(test)
test_errors_print_as_readable_names :: proc(t: ^testing.T) {
	err := dotenv.Error(dotenv.Parse_Error.Unterminated_Quote)
	testing.expect_value(t, fmt.tprint(err), "Unterminated_Quote")
}

// ---- Ownership and allocators ----

@(test)
test_env_get_reports_missing_keys :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	env, err, _ := dotenv.parse("A=1\nEMPTY=\n", PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil)

	_, ok := dotenv.env_get(env, "MISSING")
	testing.expect(t, !ok)
	value, found := dotenv.env_get(env, "EMPTY")
	testing.expect(t, found)
	testing.expect_value(t, value, "")
}

@(test)
test_env_destroy_zero_value_is_safe :: proc(t: ^testing.T) {
	env: dotenv.Env
	dotenv.env_destroy(&env)
	dotenv.env_destroy(&env)
	testing.expect(t, env.vars == nil)
}

@(test)
test_parse_uses_given_allocator :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	env, err, _ := dotenv.parse("A=1\nB=${A}2\n", PURE, allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, len(track.allocation_map) > 0)
	testing.expect_value(t, env.allocator, allocator)
	expect_var(t, env, "B", "12")

	dotenv.env_destroy(&env)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// Budget fails every allocation after `remaining` have succeeded.
Budget :: struct {
	backing:   runtime.Allocator,
	remaining: int,
}

budget_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	b := (^Budget)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if b.remaining <= 0 {
			return nil, .Out_Of_Memory
		}
		b.remaining -= 1
	}
	return b.backing.procedure(b.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
test_allocation_failures_never_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	src := "A=1\nB=\"two ${A}\"\nA=3\nC=${MISSING:-fallback} tail\nD='x'\n"
	succeeded := false
	for limit in 0 ..< 200 {
		budget := Budget{backing = context.allocator, remaining = limit}
		allocator := runtime.Allocator{procedure = budget_proc, data = &budget}

		env, err, _ := dotenv.parse(src, PURE, allocator)
		if err == nil {
			expect_var(t, env, "C", "fallback tail")
			dotenv.env_destroy(&env)
			succeeded = true
			break
		}
		testing.expect_value(t, err, dotenv.Error(runtime.Allocator_Error.Out_Of_Memory))
		testing.expect(t, env.vars == nil)
	}
	testing.expect(t, succeeded)
}

// Single_Failure fails only the allocation numbered `fail_at`, counting from 0.
Single_Failure :: struct {
	backing: runtime.Allocator,
	fail_at: int,
	count:   int,
}

single_failure_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	s := (^Single_Failure)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		n := s.count
		s.count += 1
		if n == s.fail_at {
			return nil, .Out_Of_Memory
		}
	}
	return s.backing.procedure(s.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
test_parse_large_input :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 2000 {
		fmt.sbprintf(&b, "KEY_%d=value_%d\n", i, i)
	}
	fmt.sbprint(&b, "LAST=${KEY_1999}\n")

	env, err, _ := dotenv.parse(strings.to_string(b), PURE)
	defer dotenv.env_destroy(&env)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(env.keys), 2001)
	expect_var(t, env, "LAST", "value_1999")
}

// ---- Regressions ----

@(test)
test_single_allocation_failures_are_reported :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)

	// Unlike the budget test, later allocations succeed again, so an error that
	// a step drops can't be masked by the next allocation failing.
	src := "A=1\nB=\"two ${A}\"\nA=3\nC=${MISSING:-fallback} tail\nD='x'\nB=$A$A\n"
	succeeded := false
	for nth in 0 ..< 200 {
		single := Single_Failure{backing = context.allocator, fail_at = nth}
		allocator := runtime.Allocator{procedure = single_failure_proc, data = &single}

		env, err, _ := dotenv.parse(src, PURE, allocator)
		if err == nil {
			expect_var(t, env, "A", "3")
			expect_var(t, env, "B", "33")
			expect_var(t, env, "C", "fallback tail")
			expect_var(t, env, "D", "x")
			testing.expect_value(t, len(env.keys), 4)
			dotenv.env_destroy(&env)
			succeeded = single.count <= nth
			if succeeded {
				break
			}
			continue
		}
		testing.expect_value(t, err, dotenv.Error(runtime.Allocator_Error.Out_Of_Memory))
		testing.expect(t, env.vars == nil)
	}
	testing.expect(t, succeeded)
}

@(test)
test_error_nul_byte_in_value :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check(t, &track)
	// The process environment can't hold NUL, so load would silently truncate these values.
	expect_error(t, "A=a\x00b\n", .Invalid_Character, 1, 4)
	expect_error(t, "A=\"a\x00b\"\n", .Invalid_Character, 1, 5)
	expect_error(t, "A='a\x00b'\n", .Invalid_Character, 1, 5)
	expect_error(t, "A=${X:-a\x00b}\n", .Invalid_Character, 1, 9)
	// A NUL byte in a comment never reaches a value, so it's harmless.
	expect_one(t, "# a\x00b\nA=1 # c\x00d\n", "A", "1")
}
