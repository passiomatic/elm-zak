# Execution context

Where variables live, how long they last, and what happens when something goes wrong while a script runs.

## Variables

A variable is declared with `let`, and must be given a value right away:

```
let health = 100
let name = "Taylor"
```

Once declared, a variable is changed with a plain assignment, without `let`:

```
health = health - 10
```

The two are never interchangeable:

- assigning to a name that was never declared is an error — assignment never creates a variable
- declaring a name twice in the same scope is an error — `let` never overwrites one

```
score = 10      # error: “score” is not defined

let lives = 3
let lives = 2   # error: “lives” is already defined in this scope
```

Reading a variable that was never declared is an error too.

## Constants

`const` declares a variable that can't be reassigned afterwards:

```
const MAX_HEALTH = 100

MAX_HEALTH = 200   # error: “MAX_HEALTH” is const and cannot be reassigned
```

`const` protects the variable, not the value it holds. If that value is an array or a table, its contents can still change:

```
const settings = { volume = 5 }
settings.volume = 8    # fine: the table changes, the variable doesn't
settings = {}          # error
```

`true`, `false`, and `nil` are constants too, always available in every script.

## Scope

Every block — the body of an `if`, `else`, `while`, `for`, or `function` — has its own scope. A variable declared inside a block exists only until the block ends:

```
if true:
    let message = "hello"
end

Debug.log(message)   # error: “message” is not defined
```

A block can read and assign the variables of the blocks around it:

```
let count = 0
if true:
    count = count + 1
end
count   # 1
```

A block can also declare its own variable with the same name as one outside it. The inner one hides the outer one until the block ends, and the outer one is left untouched:

```
let x = 1
if true:
    let x = 2   # a new variable, only inside this block
end
x   # 1
```

Hiding a constant this way is allowed, but logs a warning, since it's more often a typo than a deliberate choice.

A loop body gets a fresh scope on every pass, so a `let` inside a loop declares a new variable each time around, rather than failing as a redeclaration:

```
let total = 0
for n in [1, 2, 3]:
    let square = n * n
    total = total + square
end
total   # 14
```

The `for` loop variable (`n` above) belongs to the loop, and doesn't exist after it ends. A function's parameters, likewise, only exist inside that function.

## The global scope

Variables declared outside any block are global: they're visible from every function in the script, for as long as the script's world exists. Depending on the host, that world can span several scripts, all seeing each other's global variables.

A function looks up the variables it uses when it runs, not when it's defined. So a function can use a global declared further down the script, as long as it's only called after that declaration has run:

```
let greet = function():
    return greeting ++ ", world"
end

let greeting = "Hello"
greet()   # "Hello, world"
```

The same rule is what lets a function call itself by name:

```
let factorial = function(n):
    if n <= 1:
        return 1
    end
    return n * factorial(n - 1)
end
```

The standard library's `Array`, `Math`, `String`, and the rest live in the global scope too, as ordinary variables. A script can declare its own `Math`, or assign to it, which hides the standard library one from then on — so avoid reusing those names.

## Runtime errors

When a script does something invalid — reads an undefined variable, divides by zero, calls something that isn't a function, passes a `String` where a `Number` was expected — it stops at that point with a runtime error. Nothing after the failing statement runs.

The error names what went wrong and where: the line and column of the statement that failed.

```
let health = 100
let damage = healht - 10
```

```
line 2, column 1: “healht” is not defined
```

How the error is shown to you — a console, a log panel, an in-game overlay — is up to the host.

There is no way to catch a runtime error from inside a script. Instead, check for the situation up front where it can legitimately happen, for example with `in`, `type()`, or the `_default` variants of `Array.get` and `Table.get`:

```
if "health" in player:
    player.health = player.health - 10
end

let first = Array.get_default(items, 0, nil)
```
