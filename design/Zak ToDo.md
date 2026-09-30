# Low priority tasks for Zak and stdlib 

Things to ponder to improve usability of the language. 

* Implement Array.remove(array, value) This will help with inventory code. What are the most common semantics for the remove operation? 
* Add Array.sort(ary) - probably in-place. How values like nil, booleans or function are sorted?
* ~~Array.member? -> Array.has?(array, value) or Array.contains?(array, value)~~ Fixed, differently: retired `?` from the stdlib's own naming entirely rather than swapping it for another `?`-suffixed alternative — `Array.member?` is now `Array.contains(array, value)` (see "Identifiers and reserved words" in `design/Zak Language Implementation.md`; the `?`/`!` convention itself stays valid grammar for a script's own functions, just no longer used by the stdlib).
* Array.get_default(ary, name, default) -> Array.safe_get(ary, name, default=nil) or Array.get_or_default(ary, name, default=nil) like Gleam
* Drop `for .. in` and add Array.each(ary, function(entry): ... end ) like Gleam 
* ~~Add a `in` operator to work with arrays _and_ tables `if 'some_value' in ary: ...` which desugars to `Array.member?`~~ Fixed: `in` now works on both (see "Comparison operators" in `design/Zak Language Implementation.md`) — value-based on arrays, matching Python/`Array.contains` (named `Array.member?` at the time this was written), deliberately *not* a literal port of real Squirrel's own `in` (checked directly: index-based on arrays there, and silently `false` rather than erroring on a non-container).
* ~~Tweak Zak parser to allow `function?`~~ Fixed: `Zak.Lexer.keyword` now rejects a trailing `?`/`!` too, not just a letter/digit/underscore (`elm/parser`'s own `Parser.keyword` only checked the latter).
* ~~Drop `!` from name identifiers in language grammar - not used anywhere yet~~ Done.
* Add stack trace when reporting an error
* ~~Should strings be considered a collection, hence be "iterable" via a for-loop?~~ Nope
* Should we suppport \n and \t in strings? What does they mean since we don't have a tradional stdout? 
* Add += and other assign in place operators

# Nice to have math stuff
* Add modulo operator. Options and a recommendation (floored `%`, paired with the existing floored `//`) are in `design/Modulo.md`. Dinky has one: `Nickel.dinky:334`.
* Add Math.power() function

# Quirks
* Array.range rounds value and doesn't error

# Guide findings 
* Unbounded recursion crashes the host. Do you want that limit added to the interpreter?
