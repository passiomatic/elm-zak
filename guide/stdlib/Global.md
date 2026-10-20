# Global functions

Functions that aren't fields of a table like `Math` or `Array` — called directly, e.g. `type(value)`, not `Something.type(value)`.

## type(value)

The name of `value`'s runtime type, as a lowercase `String`: `"string"`, `"number"`, `"bool"`, `"nil"`, `"array"`, `"table"`, or `"function"`.

```
type("hi")       # "string"
type(1)          # "number"
type([1, 2])     # "array"
type({ x = 1 })  # "table"

let value = "I'm a string"
if type(value) == "string":
    ...
end
```

## is_string(value), is_number(value), is_bool(value), is_array(value), is_table(value), is_function(value)

`true` if `value` has that type, `false` otherwise. Each is the same as comparing `type(value)` with the type's name, so they always agree with `type`: `is_string(value)` is `type(value) == "string"`. Like `type`, they accept a value of any type.

```
is_string("hi")              # true
is_number("1")               # false
is_array([])                 # true
is_table([])                 # false
is_function(Math.max)        # true
```

There's no `is_nil`: use `value == nil`.
