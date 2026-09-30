# Low priority tasks for Zak and stdlib 

Things to ponder to improve usability of the language. 

* Implement Array.remove(array, value) This will help with inventory code. What are the most common semantics for the remove operation? 
* Add Array.sort(ary) - probably in-place
* ~~Array.member? -> Array.has?(array, value) or Array.contains?(array, value)~~ Fixed, differently: retired `?` from the stdlib's own naming entirely rather than swapping it for another `?`-suffixed alternative — `Array.member?` is now `Array.contains(array, value)` (see "Identifiers and reserved words" in `design/Zak Language Implementation.md`; the `?`/`!` convention itself stays valid grammar for a script's own functions, just no longer used by the stdlib).
* Array.get_default(ary, name, default) -> Array.safe_get(ary, name, default=nil) or Array.get_or_default(ary, name, default=nil)
* Drop `for .. in` and add Array.each(ary, function(entry): ... end ) like Gleam 
* ~~Add a `in` operator to work with arrays _and_ tables `if 'some_value' in ary: ...` which desugars to `Array.member?`~~ Fixed: `in` now works on both (see "Comparison operators" in `design/Zak Language Implementation.md`) — value-based on arrays, matching Python/`Array.contains` (named `Array.member?` at the time this was written), deliberately *not* a literal port of real Squirrel's own `in` (checked directly: index-based on arrays there, and silently `false` rather than erroring on a non-container).
* ~~Emit a log_warning if you try to shadow a const~~ Fixed: a `let`/`const` shadowing a `const` from any outer scope now queues a `LogWarning`, the same shape `Debug.log_warning(message)` itself produces (see "Nil" in `design/Zak Language Implementation.md`).
* ~~Drop single quotes for strings - two ways to obtain the same thing, not clear the win having both ' and " characters~~ Fixed: string literals are now double-quoted only (see "Strings" in `design/Zak Language Implementation.md`) — checked against Squirrel/Python/Lua/Ruby first; Zak's two forms were already fully equivalent, unlike Ruby's real single/double distinction.
* ~~Tweak Zak parser to allow `function?`~~ Fixed: `Zak.Lexer.keyword` now rejects a trailing `?`/`!` too, not just a letter/digit/underscore (`elm/parser`'s own `Parser.keyword` only checked the latter).
* ~~Drop `!` from name identifiers in language grammar - not used anywhere yet~~ Done.
* Add stack trace when reporting an error
* ~~Should strings be considered a collection, hence be "iterable" via a for-loop?~~
* Should we suppport \n and \t in strings? What does they mean since we don't have a tradional stdout? 
* ~~Add Math.min and max functions ~~ Done.
* Add += and other assign in place operators
* Add modulo operator. Options and a recommendation (floored `%`, paired with the existing floored `//`) are in `design/Modulo.md`. Dinky has one: `Nickel.dinky:334`.
* Add Math.power() function

# Guide findings 
* Debug.é only allows strings: no good
* Unbounded recursion crashes the host. Do you want that limit added to the interpreter?
* Duplicate parameter names are accepted