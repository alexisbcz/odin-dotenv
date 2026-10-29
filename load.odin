package dotenv

import "core:os"

/*
env_apply copies every variable of `env` into the process environment, in the
order of `env.keys`.

When `overwrite` is false, a variable that the process already has, even with
an empty value, keeps its current value.

The process environment is global state, so don't call this while other
threads read or write it.

Inputs:
- env: the variables to apply.
- overwrite: replace process variables that are already set.
- allocator: scratch memory for lookups, freed before env_apply returns.

Returns:
- err: the first os.Error from setting a variable. Variables before it stay set.
*/
env_apply :: proc(env: Env, overwrite := false, allocator := context.allocator) -> (err: Error) {
	for key in env.keys {
		if !overwrite && _process_has(key, allocator) {
			continue
		}
		os.set_env(key, env.vars[key]) or_return
	}
	return nil
}

/*
load parses the file at `path` and applies it to the process environment.

It keeps variables that are already set unless `options.overwrite` is true.
To load several files with the first one taking precedence, call load once
per file, most important first.

Inputs:
- path: the file to read; defaults to `.env` in the current directory.
- options: see Options.
- allocator: scratch memory, all freed before load returns.

Returns:
- err: an os.Error when reading or setting fails, a Parse_Error, or an allocator error.
  On a Parse_Error, load sets no variables.
- loc: where a Parse_Error happened; zero otherwise.
*/
load :: proc(path := ".env", options := Options{}, allocator := context.allocator) -> (err: Error, loc: Location) {
	env: Env
	env, err, loc = parse_file(path, options, allocator)
	if err != nil {
		return
	}
	defer env_destroy(&env)
	err = env_apply(env, options.overwrite, allocator)
	return
}

@(private)
_process_has :: proc(key: string, allocator := context.allocator) -> bool {
	value, found := os.lookup_env(key, allocator)
	delete(value, allocator)
	return found
}
