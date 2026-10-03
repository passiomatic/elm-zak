# Future ideas

## ✅ 1. Let underscore identifier be special - DONE

Currently this is raises an error:

```
let _ = 123
let _ = 345

    -> “_” is already defined in this scope
```

We should allow the `_` be a throwaway value. This could pair nicely if we allow structural unpacking (see below).

## 2. Structural unpacking

Let unpack values from a collection, being an array or table:

```
let _, b = [1,2]
print(b)
 --> 2

let x, y = {x=1, y=2}
print(y)
 --> 2

# Or...

let [_, b] = [1,2]
let { x, y } = {x=1, y=2}
```

Notes:
* [Quirrel][q] allows this by using the `[a, b]` or `{x, y}` to specify the source data structure, which makes sense too since it communicates the intent better.
* Using `_` from point 1.

## 3. Expand String.format to use name look ups

Use a new name look up syntax to allow to pass a table as an argument.

```
String.format("I ate %{count}d apples and I feel %{status}s.", {count: 5, baz: false, status: "fine"})
```

Notes: 
* The `baz` field is ignored 
* The positions of the table fields are not significant while resolving the format string names

# 3a. Allow String.format to accept multiple arguments

We can implement native functions as variadic.

```
String.format("First %s, then %s", "this", "that")
```


## 4. Multiple variables declarations on the same line

A really little thing, today this isn't allowed:

```
let a=1, b=2, c=3
```

Could be superseded by structural unpacking, although is not really as clear. E.g.:

```
let a, b, c = [1,2,3]
```


# 5. Allow more types as table field names 

Allow specify a numeric index like Squirrel, with a array-like syntax: 

```
local tbl  = {
    some_slot = "foo"
    [99] = "Ninetynine"
}
```

This is more flexbile than that: https://developer.electricimp.com/squirrel/squirrel-guide/variables-collections#tables you can use various  types as keys. 

I think we need to implement this only if there's a real usage need. 


# 6. Ternary operator or if/else variant

We currently don't have a way to return a value from a `if/else` construct. We have various options (quoting from memory):

* Classic C-style op: pred `?` when-true `:` when-false
* Python: when-true `if` pred `else` when-false
* Elm: `if` pred `then` when-true `else` when-false
 
Python's version is stronger for Zak because we don't introduce new keywords and reads well.


[q]: https://quirrel.io/doc/coming-from/squirrel.html

