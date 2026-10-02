# Future ideas

## 1. Let underscore identifier be special

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

let x, y = {x: 1, y: 2}
print(y)
 --> 2

# Or...

let [_, b] = [1,2]
let { x, y } = {x: 1, y: 2}
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


[q]: https://quirrel.io/doc/coming-from/squirrel.html