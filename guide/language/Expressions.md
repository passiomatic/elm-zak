# Expressions

An expression is anything that produces a value: a literal, a variable, a field or element read, a function call, or operators combining other expressions.

```
42
player.name
items[0]
Math.max(a, b)
(base + bonus) * 2
```

Operands are always evaluated left to right, and so are a function call's arguments.

## Arithmetic operators

| Operator | Meaning          | Example   | Result |
| -------- | ---------------- | --------- | ------ |
| `+`      | addition         | `7 + 2`   | `9`    |
| `-`      | subtraction      | `7 - 2`   | `5`    |
| `*`      | multiplication   | `7 * 2`   | `14`   |
| `/`      | division         | `7 / 2`   | `3.5`  |
| `//`     | floor division   | `7 // 2`  | `3`    |
| `-x`     | negation         | `-7`      | `-7`   |

All of them work on numbers only.

Floor division divides, then rounds down to the nearest whole number — down, not toward zero, so `-7 // 2` is `-4`.

Dividing by zero, with either `/` or `//`, is a runtime error.

There is no remainder operator.

## String concatenation

`++` joins two strings into a new one:

```
"Hello" ++ ", " ++ "world"   # "Hello, world"
```

Both sides must be strings. `+` never joins strings, and `++` never converts a number: use `String.from` for that.

```
"Score: " ++ String.from(score)
```

## Comparison operators

| Operator | Meaning                  |
| -------- | ------------------------ |
| `==`     | equal                    |
| `!=`     | not equal                |
| `<`      | less than                |
| `<=`     | less than or equal       |
| `>`      | greater than             |
| `>=`     | greater than or equal    |

All of them produce a `Bool`.

`==` and `!=` accept any two values, of any types. The ordering operators only accept two numbers or two strings. See [Equality](Values.md#equality) for exactly when two values are equal.

A comparison can't be chained: `a < b < c` is a syntax error. Combine two comparisons with `and` instead:

```
a < b and b < c
```

## Logical operators

| Operator  | Result                                           |
| --------- | ------------------------------------------------ |
| `a and b` | `true` if both `a` and `b` are `true`            |
| `a or b`  | `true` if at least one of `a` and `b` is `true`  |
| `not a`   | `true` if `a` is `false`, and the other way round |

All of them work on `Bool`s only, and produce a `Bool`.

`and` and `or` stop as soon as the answer is known: if the left side of `and` is `false`, or the left side of `or` is `true`, the right side isn't evaluated at all. That makes it safe to guard an expression that would otherwise fail:

```
if "door" in room and room.door.locked?:
    Debug.log("It's locked.")
end
```

## in

`in` checks whether a collection contains something, and produces a `Bool`:

- `value in array` is `true` if any element of `array` is equal to `value`, by the same rules as `==`
- `name in table` is `true` if `table` has a field called `name`, which must be a `String`

```
"lamp" in ["key", "lamp"]         # true
"health" in { health = 100 }      # true
"mana" in { health = 100 }        # false
```

Anything else on the right side of `in` is an error.

`in` belongs with the comparison operators, so it can't be chained with one either. To check the opposite, put `not` in front:

```
if not "key" in inventory:
    Debug.log("You need a key.")
end
```

## Precedence

When operators are mixed without parentheses, those with a higher precedence are applied first. From highest to lowest:

| Precedence | Operators                                | Associativity |
| ---------- | ---------------------------------------- | ------------- |
| 1          | `.field`, `[index]`, `(arguments)`       | left          |
| 2          | `-` (negation)                           | right         |
| 3          | `*`, `/`, `//`                           | left          |
| 4          | `+`, `-`, `++`                           | left          |
| 5          | `==`, `!=`, `<`, `<=`, `>`, `>=`, `in`   | none          |
| 6          | `not`                                    | right         |
| 7          | `and`                                    | left          |
| 8          | `or`                                     | left          |

"Left" means operators of the same level are applied from left to right: `10 - 3 - 2` is `(10 - 3) - 2`. "None" means they can't be chained at all.

A few consequences worth knowing:

- `-p.x` negates the field: `-(p.x)`
- `2 + 3 * 4` is `14`, not `20`
- `not a == b` is `not (a == b)`, and `not x in items` is `not (x in items)`
- `a or b and c` is `a or (b and c)`
- `+` and `++` share a level, so `1 + 2 ++ "!"` is `(1 + 2) ++ "!"` — an error, since `3` isn't a string

Parentheses override precedence as usual: `(2 + 3) * 4` is `20`.

## Field access, indexing, and calls

These three read from the value to their left, and can be chained in any order:

| Form          | Meaning                                                      |
| ------------- | ------------------------------------------------------------ |
| `t.name`      | the field called `name` of the table `t`                     |
| `a[i]`        | the element at index `i` of the array `a`                    |
| `f(x, y)`     | the result of calling the function `f` with `x` and `y`      |

```
game.players[0].name
load_level("intro").rooms[0]
make_greeter()("Taylor")
```

`[ ]` only indexes arrays. To read a table field whose name is only known at runtime, use [`Table.get`](../stdlib/Table.md) — see [Field names known at runtime](Tables.md#field-names-known-at-runtime).

## Array constructor

Square brackets build a new array from a comma-separated list of expressions, of any mix of types:

```
let empty = []
let numbers = [1, 2, 3]
let mixed = ["key", 42, nil, [x, y]]
```

## Table constructor

Braces build a new table from a comma-separated list of `name = value` fields:

```
let empty = {}
let player = {
    name = "Taylor",
    health = 100,
    position = { x = 0, y = 0 }
}
```

A field name is an identifier, written bare: `{ x = 1 }`, not `{ "x" = 1 }`. Each name can appear only once: `{ x = 1, x = 2 }` is a syntax error.

Both constructors build a new, separate array or table every time they're evaluated, so two identical-looking constructors never produce equal values.

A function literal — `function(x): ... end` — is an expression too. See [Functions](Functions.md).
