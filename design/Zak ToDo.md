# Low priority tasks for Zak and stdlib 

Things to ponder to improve usability of the language. 

# Before v1 (package release)
* Add a conditional expression (ternary). Options are in `design/Future.md`, section 6; Python's `a if cond else b` is the current favorite. It has to be syntax, not a function, because a function would evaluate both branches. Two grammar constraints rule out C's `cond ? a : b` as is: a trailing `?` is still valid in names (`actor?`, so `open?"gone"` lexes as one name), and `:` already opens blocks (`if cond:`).

* Implement Array.remove(array, value) This will help with inventory code. What are the most common semantics for the remove operation? 
* Add Array.sort(ary) - probably in-place. How values like nil, booleans or function are sorted?
* Array.get_default(ary, name, default) -> Array.safe_get(ary, name, default=nil) or Array.get_or_default(ary, name, default=nil) like Gleam
* Drop `for .. in` and add Array.each(ary, function(entry): ... end ) like Gleam 
* Add stack trace when reporting an error
* ~~Should strings be considered a collection, hence be "iterable" via a for-loop?~~ Nope
* Should we suppport \n and \t in strings? What does they mean since we don't have a tradional stdout? 
* Add += and other assign in place operators

# Nice to have math stuff
* Add modulo operator. Options and a recommendation (floored `%`, paired with the existing floored `//`) are in `design/Modulo.md`. Dinky has one: `Nickel.dinky:334`.
* Add Math.power() function

# Quirks
* Array.range rounds value and doesn't error
* Native functions can accept variadic arguments while pure Zak functions do not.

# Guide findings 
* Unbounded recursion crashes the host. Do you want that limit added to the interpreter?


