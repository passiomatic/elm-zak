# Low priority tasks for Zak and stdlib 

Things to ponder to improve usability of the language. 

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

# Guide findings 
* Unbounded recursion crashes the host. Do you want that limit added to the interpreter?

# New ideas

Allow specify a numeric index like Squirrel, with a array-like syntax: 

```
local tbl  = {
    some_slot = "foo"
    [99] = "Ninetynine"
}
```

This is more flexbile than that: https://developer.electricimp.com/squirrel/squirrel-guide/variables-collections#tables you can use various  types as keys. 

I think we need to implement this only if there's a real usage need. 



