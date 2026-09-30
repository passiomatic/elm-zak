# Functions

A function is a block of code that runs when it's called, with values passed in as arguments, and gives back a result.

## Defining a function

A function is written as a function literal: the keyword `function`, a list of parameters in parentheses, a `:`, the body, and `end`:

```
function(a, b):
    return a + b
end
```

A function literal is an expression like any other, and produces a function value. Functions don't have names of their own: to call a function by name, store it in a variable, or in a table field.

```
let add = function(a, b):
    return a + b
end

let shapes = {
    square = function(side):
        return side * side
    end
}
```

A short function can stay on a single line, as long as its body is a single statement:

```
let double = function(x): return x * 2 end
```

## Calling a function

A function is called by writing parentheses after it, with the arguments inside, separated by commas:

```
add(2, 3)           # 5
shapes.square(4)    # 16
double(add(1, 2))   # 6
```

The parentheses are required even with no arguments: `greet()` calls the function, while `greet` alone is just the function value.

Arguments are evaluated left to right, before the function starts running. Each parameter is then a fresh variable inside the function, holding its argument. Assigning to a parameter only changes that variable, never the caller's — but an array or a table passed in is the caller's own, so changes to its contents are visible outside. See [Values and references](Values.md#values-and-references).

Calling something that isn't a function is a runtime error:

```
let score = 10
score()   # error: the number 10 is not a function, and cannot be called
```

## Parameters and arguments

A call must pass exactly as many arguments as the function has parameters, unless some parameters have default values (see below). Too few or too many is a runtime error:

```
add(1)         # error: expected 2 arguments, got 1
add(1, 2, 3)   # error: expected 2 arguments, got 3
```

Every parameter must have a different name: `function(a, a)` is a syntax error. That includes `_`, which is an ordinary name like any other.

There's no way to accept a variable number of arguments. To pass any number of values, pass an array.

## Default parameter values

A parameter can be given a default value, used when the call leaves that argument out:

```
let greet = function(name, greeting = "Hello"):
    return greeting ++ ", " ++ name
end

greet("Taylor")          # "Hello, Taylor"
greet("Taylor", "Hi")    # "Hi, Taylor"
```

Once a parameter has a default, every parameter after it must have one too — `function(a = 1, b)` is a syntax error. Arguments are always matched to parameters in order, so there's no way to skip one in the middle.

A default is only used when the argument is left out entirely. Passing `nil` explicitly passes `nil`, not the default.

A default can be any expression, and is evaluated anew on every call that needs it. So a default of `[]` or `{}` gives each call its own new array or table, never one shared between calls:

```
let collect = function(item, into = []):
    Array.push(into, item)
    return into
end

collect("a")   # ["a"]
collect("b")   # ["b"] — a new array, not ["a", "b"]
```

A default is evaluated in the scope where the function was defined, not among the other parameters, so it can't refer to an earlier parameter: `function(a, b = a)` fails when `b`'s default is needed.

## Returning a value

`return` ends the function right away and gives its value back to the caller. A function that reaches its `end` without a `return`, or runs a bare `return`, gives back `nil`. See [return](Statements.md#return).

A function returns a single value. To give back several, return an array or a table:

```
let bounds = function(items):
    return { low = items[0], high = items[Array.length(items) - 1] }
end
```

## Functions are values

A function can be stored, passed, and returned like any other value.

Passing a function to another one is how the standard library's `Array.map`, `Array.filter`, `Table.each`, and the like work:

```
let is_expensive = function(price): return price > 100 end
Array.filter([50, 150, 300], is_expensive)   # [150, 300]
```

The function can also be written right where it's passed:

```
Array.map([1, 2, 3], function(x): return x * x end)   # [1, 4, 9]
```

Standard library and host functions are values in the same way, and can be passed along or stored just like a function defined in the script:

```
let round = Math.round
Array.map([1.4, 2.6], round)   # [1, 3]
```

Two functions are never `==`, not even a function compared with itself.

## Closures

A function can use the variables of the scope it was defined in, and keeps access to them even after that scope has ended. A function that does this is called a closure:

```
let make_counter = function():
    let count = 0
    return function():
        count = count + 1
        return count
    end
end

let next_id = make_counter()
next_id()   # 1
next_id()   # 2
next_id()   # 3
```

`count` lives on after `make_counter` returns, because the inner function still uses it. Each call to `make_counter` creates a new, separate `count`, so every counter it makes is independent.

A closure shares the variable itself, not a copy of its value at the time the function was made: an assignment made later, by the closure or from outside, is seen by both. A closure made inside a loop body gets that pass's own variables, since each pass has a fresh scope:

```
let getters = []
for i in [1, 2, 3]:
    Array.push(getters, function(): return i end)
end

getters[0]()   # 1
getters[2]()   # 3
```

## Recursion

A function can call itself, through the variable it's stored in:

```
let factorial = function(n):
    if n <= 1:
        return 1
    end
    return n * factorial(n - 1)
end

factorial(5)   # 120
```

This works because a function looks up variables when it runs, not when it's defined — by the time `factorial` calls itself, the variable `factorial` exists. For the same reason, two functions can call each other, in either order of declaration. See [The global scope](Execution.md#the-global-scope).

## Functions in tables

A function stored in a table doesn't automatically receive the table it's called through. When it needs it, pass the table explicitly, conventionally as a first parameter named `self`. See [Functions in tables](Tables.md#functions-in-tables).
