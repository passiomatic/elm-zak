# Low priority tasks for Zak and stdlib 

Things to ponder to improve usability of the language. 

# Before v1 (package release)
* Add Array.sort(ary) - probably in-place. How values like nil, booleans or function are sorted?
* ~~Array.get_default(ary, name, default) -> Array.safe_get(ary, name, default=nil) or Array.get_or_default(ary, name, default=nil) like Gleam~~ Done: the name stays, and `default` is optional (`nil`) on both `Array.get_default` and `Table.get_default`
* Add stack trace when reporting an error
* Add += and other assign in place operators

# Guide findings 
* Unbounded recursion crashes the host. Do you want that limit added to the interpreter?


