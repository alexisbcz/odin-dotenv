// Example basic parses a .env file and loads it into the process environment.
// Run it from the repository root with `odin run examples/basic`.
package main

import dotenv "../.."
import "core:fmt"
import "core:os"

main :: proc() {
	// parse returns the variables without touching the process environment.
	env, err, loc := dotenv.parse_file("examples/basic/example.env")
	if err != nil {
		fmt.eprintfln("example.env:%d:%d: %v", loc.line, loc.column, err)
		os.exit(1)
	}
	defer dotenv.env_destroy(&env)

	for key in env.keys {
		fmt.printfln("%s=%q", key, env.vars[key])
	}

	// load applies the file to the process environment. Variables that are
	// already set, for example by the shell, keep their values.
	if load_err, load_loc := dotenv.load("examples/basic/example.env"); load_err != nil {
		fmt.eprintfln("example.env:%d:%d: %v", load_loc.line, load_loc.column, load_err)
		os.exit(1)
	}
	url := os.get_env("DATABASE_URL", context.allocator)
	defer delete(url)
	fmt.println("DATABASE_URL from the process environment:", url)
}
