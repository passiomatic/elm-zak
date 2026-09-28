# Global functions

Functions that aren't grouped into a namespace — called directly, e.g. `type(value)`, not `Something.type(value)`.

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
