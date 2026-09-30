# Values and data types

Zak is dynamically typed: variables don't have types, values do. Any variable, array element, or table field can hold a value of any type, and can hold a value of a different type later.

There are seven types:

| Type       | Example                     | `type()` returns |
| ---------- | --------------------------- | ---------------- |
| Number     | `42`, `3.14`                | `"number"`       |
| String     | `"hello"`                   | `"string"`       |
| Bool       | `true`, `false`             | `"bool"`         |
| Nil        | `nil`                       | `"nil"`          |
| Array      | `[1, 2, 3]`                 | `"array"`        |
| Table      | `{ x = 1, y = 2 }`          | `"table"`        |
| Function   | `function(x): return x end` | `"function"`     |

Use [`type(value)`](../stdlib/Global.md) to find out a value's type at runtime.

Zak never converts a value from one type to another on its own. An operator or function that expects a `Number` and gets a `String` stops the script with a type error, rather than guessing what was meant.

## Number

There is a single number type, used for both whole and fractional values. Numbers are 64-bit floating point, so fractional arithmetic can carry small rounding errors:

```
7 / 2              # 3.5
7 // 2             # 3
0.1 + 0.2 == 0.3   # false
```

Dividing by zero, with either `/` or `//`, stops the script with an error. A calculation never produces an "infinity" or "not a number" value.

Some functions, such as `Array.get`, only accept a whole number; passing `1.5` there is an error.

## String

An immutable sequence of characters. No operation changes a string in place: [`String`](../stdlib/String.md) functions and the `++` operator always return a new one.

```
let greeting = "Hello"
let message = greeting ++ ", world"   # greeting is still "Hello"
```

`++` only joins two strings. To include another type, convert it first with `String.from`:

```
"Health: " ++ String.from(100)   # "Health: 100"
"Health: " ++ 100                # error
```

Strings can be compared with `<`, `<=`, `>`, and `>=`, which order them character by character. Uppercase letters sort before lowercase ones, so `"Z" < "a"` is `true`.

## Bool

`true` or `false`. These are the only values a condition accepts: `if`, `while`, `and`, `or`, and `not` all require a `Bool`, and anything else is an error. There are no "truthy" or "falsy" values — `0`, `""`, `[]`, and `nil` are not `false`.

```
let count = 0
if count:          # error: expected Bool, got Number
    ...
end

if count != 0:     # fine
    ...
end
```

## Nil

`nil` is the single value of its type, and stands for "no value". A function that ends without a `return`, or with a bare `return`, returns `nil`:

```
let f = function():
    let x = 1
end

f()   # nil
```

`nil` is an ordinary value: it can be stored in a variable, an array, or a table field. It is only equal to itself.

## Array

An ordered collection of values, of any mix of types, indexed from `0`:

```
let items = ["key", "lamp", 3, nil]
items[0]   # "key"
```

Arrays can grow and shrink with functions like `Array.push` and `Array.pop`. See the [Array](../stdlib/Array.md) page for the full list.

## Table

A collection of named fields, each holding a value of any type:

```
let player = { name = "Taylor", health = 100 }
player.health   # 100
```

Reading a field that doesn't exist is an error. See the [Table](../stdlib/Table.md) page for functions that check for a field, or read it with a fallback.

The standard library's `Array`, `Math`, `String`, and the rest are tables too, whose fields happen to be functions: `Math.cos` reads the `cos` field of the `Math` table.

## Function

A piece of code that can be called with arguments. Functions are values like any other: they can be stored in variables and table fields, passed to other functions, and returned from them.

```
let double = function(x):
    return x * 2
end

let shapes = {
    square = function(side):
        return side * side
    end
}

Array.map([1, 2, 3], double)   # [2, 4, 6]
shapes.square(3)               # 9
```

Functions defined in a script and functions provided by the host or the standard library are indistinguishable: both have type `"function"` and are called the same way.

## Values and references

Numbers, strings, bools, and `nil` are plain values: assigning one to another variable, or passing it to a function, hands over the value itself.

Arrays and tables are references: assigning one, or passing it to a function, hands over the same array or table, not a copy. A change made through one name is visible through every other:

```
let a = { health = 100 }
let b = a
b.health = 50
a.health   # 50 — a and b are the same table
```

```
let add_key = function(items):
    Array.push(items, "key")
end

let inventory = []
add_key(inventory)
Array.length(inventory)   # 1
```

To get an independent copy, use `Array.clone` or `Table.clone`.

## Equality

`==` and `!=` work on any two values, of any types:

- numbers, strings, and bools are equal when they hold the same value
- `nil` is equal only to `nil`
- arrays and tables are equal only when they are the same array or table — two separately built arrays with the same elements are not equal
- functions are never equal to anything, not even to themselves
- values of different types are never equal: `1 == "1"` is `false`

```
[1, 2] == [1, 2]   # false — two different arrays

let a = [1, 2]
let b = a
a == b             # true — the same array
```

Ordering with `<`, `<=`, `>`, and `>=` only works between two numbers or two strings. Any other combination — including a number and a string — is an error.
