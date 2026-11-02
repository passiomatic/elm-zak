# Low priority tasks for Zak and stdlib 

Things to ponder to improve usability of the language. 

# Before v1 (package release)
* Add a conditional expression (ternary). The proposal, the options and the Delores use cases are in `design/Future.md`, section 6; Elm's `if cond then a else b` is the current favorite.

* ~~Implement Array.remove(array, value) This will help with inventory code. What are the most common semantics for the remove operation?~~ Done: removes the first element equal to `value` and returns whether it removed one
* Add Array.sort(ary) - probably in-place. How values like nil, booleans or function are sorted?
* Array.get_default(ary, name, default) -> Array.safe_get(ary, name, default=nil) or Array.get_or_default(ary, name, default=nil) like Gleam
* Drop `for .. in` and ~~add Array.each(ary, function(entry): ... end ) like Gleam~~ (`Array.each` done; `for .. in` is still there)
* Add stack trace when reporting an error
* ~~Should strings be considered a collection, hence be "iterable" via a for-loop?~~ Nope
* ~~Should we suppport \n and \t in strings? What does they mean since we don't have a tradional stdout?~~ Done: elm-adventure's close-up text (`Scene.draw_text`) needs line breaks, and the host decides what a line break or a tab looks like
* Add += and other assign in place operators

# Nice to have math stuff
* Add Math.power() function

# Quirks
* Array.range rounds value and doesn't error
* Native functions can accept variadic arguments while pure Zak functions do not.

# Guide findings 
* Unbounded recursion crashes the host. Do you want that limit added to the interpreter?


