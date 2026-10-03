# String

String inspection and formatting. Every function here is pure — none of them mutate their argument, since a string has no identity to mutate in the first place.

## String.from(value)

`value`'s display form, as a `String`. Accepts any type.

| Value | Result |
|---|---|
| `String` | itself, unquoted |
| `Number` | e.g. `String.from(99)` is `"99"`, not `"99.0"` |
| `Bool` | `"true"` / `"false"` |
| `Nil` | `"nil"` |
| `Array` / `Table` / a function | a fixed placeholder: `"<array>"`, `"<table>"`, `"<function>"` |

```
let shots = 99
"I have " ++ String.from(shots) ++ " shots left"   # "I have 99 shots left"
```

## String.length(string)

Number of characters in `string`.

```
String.length("hello")   # 5
```

## String.is_empty(string)

True if `string` has no characters.

```
String.is_empty("")   # true
String.is_empty("hi")  # false
```

## String.reverse(string)

`string`, reversed.

```
String.reverse("hello")   # "olleh"
```

## String.upper(string)

`string`, in uppercase. Works on any letter, not just A–Z. A few characters become more than one, so the result can be longer than `string`.

```
String.upper("Hello")    # "HELLO"
String.upper("città")    # "CITTÀ"
String.upper("straße")   # "STRASSE" (ß becomes two letters)
```

## String.lower(string)

`string`, in lowercase. Works on any letter, not just A–Z.

```
String.lower("Hello")   # "hello"
String.lower("CITTÀ")   # "città"
```

## String.replace(string, needle, replacement)

`string`, with every occurrence of `needle` swapped for `replacement`.

```
String.replace("banana", "a", "o")   # "bonono"
```

## String.slice(string, start, end=nil)

`string`, from `start` up to but not including `end` (0-based). `end` is optional — omit it to slice through the end of the string. `start`/`end` must be non-negative whole numbers, or it's an error; a negative index does *not* count from the end. An `end` past the string's own length just clamps to the length, and `start` at or past `end` gives `""` — neither is an error.

```
String.slice("verb_dance", 5, 10)   # "dance"
String.slice("verb_dance", 5)       # "dance" (end omitted — through the end of the string)
String.slice("abc", 0, 999)         # "abc" (end past the string's length clamps)
String.slice("abc", 2, 1)           # "" (start at or past end)
```

## String.append(a, b)

`a`, with `b` appended — a callable spelling of `a ++ b`, useful when concatenation needs to be passed around as a function value (e.g. to `Array.foldr`).

```
String.append("foo", "bar")   # "foobar", same as "foo" ++ "bar"
```

## String.format(format, args)

Substitutes each `%s`/`%d`/`%f`/`%x`/`%X`/`%%` in `format`, in order, with values from `args` (an `Array`). `args`' length must equal the number of placeholders exactly — both too few and too many are an error.

| Directive | Behavior |
|---|---|
| `%s` | Accepts any value, converted to its display form (same as `String.from`). |
| `%d` | Accepts a `Number`. A fractional value is truncated toward zero, not rounded. |
| `%f` | Accepts a `Number`, shown with its full value (no fixed decimal-place count yet). |
| `%x` / `%X` | Accepts a `Number` — lowercase/uppercase hex, truncated toward zero like `%d`. A negative value is sign-prefixed (`"-ff"`).
| `%%` | A literal `%` in the output. Consumes no argument. |

```
String.format("One %d and two %s", [1, "strings"])   # "One 1 and two strings"
String.format("%d apples", [3.9])                     # "3 apples" (truncated toward zero)
String.format("%f meters", [3.14159])                 # "3.14159 meters"
String.format("%x / %X", [255, 255])                  # "ff / FF"
String.format("%x", [-255])                           # "-ff" (sign-prefixed, not two's-complement)
String.format("100%%", [])                            # "100%"
```
