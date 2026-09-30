# Statements

A script is a sequence of statements, run one after the other, top to bottom. Each statement goes on its own line — see [Lines and blocks](Lexical.md#lines-and-blocks).

## Blocks

A block is a sequence of statements that belongs to another statement: the body of an `if`, a loop, or a function. A block starts after a `:` and runs until the matching `end`:

```
if player.health <= 0:
    Debug.log("game over")
    player.lives = player.lives - 1
end
```

A block can be empty, and a short one can stay on a single line, as long as it holds a single statement:

```
if done?: return end
```

Every block has its own scope — see [Scope](Execution.md#scope).

## if

`if` runs its block only when its condition is `true`:

```
if player.health <= 0:
    Debug.log("game over")
end
```

An `else` block runs when the condition is `false`:

```
if door.locked?:
    Debug.log("It's locked.")
else:
    door.open? = true
end
```

Further conditions can be chained with `else if`, checked in order until one is `true`. A whole chain closes with a single `end`:

```
let grade = function(score):
    if score >= 90:
        return "A"
    else if score >= 75:
        return "B"
    else if score >= 60:
        return "C"
    else:
        return "F"
    end
end
```

A condition must be a `Bool` — see [Bool](Values.md#bool).

## while

`while` runs its block over and over, as long as its condition is `true`. The condition is checked before every pass, so if it's `false` from the start, the block never runs:

```
let countdown = 3
while countdown > 0:
    Debug.log(String.from(countdown))
    countdown = countdown - 1
end
```

## for

`for` runs its block once for each element of an array, in order, with the loop variable set to that element:

```
for item in inventory:
    Debug.log(item)
end
```

The loop variable is declared by the `for` itself, without `let`, and only exists inside the loop. Assigning to it changes the variable, not the array.

To loop over a range of numbers, build one with [`Array.range`](../stdlib/Array.md):

```
for i in Array.range(1, 3):
    Debug.log(String.from(i))   # 1, then 2, then 3
end
```

`for` only works on arrays. To go through a table's fields, use [`Table.each`](../stdlib/Table.md).

The array is read afresh on every pass, so elements added to it from inside the loop are visited too. To loop over the array as it was when the loop started, loop over a copy made with `Array.clone`.

## break

`break` ends the loop it's in right away. The script carries on after the loop's `end`:

```
let attempts = 0
while true:
    attempts = attempts + 1
    if attempts == 3:
        break
    end
end
```

## continue

`continue` skips the rest of the current pass, and moves on to the next one:

```
let total = 0
for n in [1, 2, 3, 4]:
    if n == 2:
        continue
    end
    total = total + n   # 1 + 3 + 4
end
```

`break` and `continue` only affect the innermost loop they're in. Both are only allowed inside a loop body, directly or inside an `if` there: anywhere else — outside every loop, or inside a function defined within a loop — they're a syntax error.

## return

`return` ends the function it's in right away, and gives back a value to whoever called it. A bare `return`, with no value, gives back `nil`, the same as reaching the end of the function:

```
let find = function(items, wanted):
    for item in items:
        if item == wanted:
            return true   # also ends the loop
        end
    end
    return false
end
```

`return` is also allowed outside any function, where it ends the whole script. The returned value is handed to the host.

## let and const

`let` declares a new variable, `const` a new constant, and both must be given a value right away:

```
let score = 0
const MAX_SCORE = 999
```

See [Execution context](Execution.md) for the rules on declaring, scope, and constants.

## Assignment

An assignment stores a new value into an existing variable, a table field, or an array element:

```
score = score + 10
player.health = 100
items[0] = "key"
```

Field and index steps can be chained, as deep as needed, and can start from any expression, including a function call:

```
game.players[0].name = "Taylor"
current_room().visited? = true
```

What each kind of target allows:

- a variable must already be declared — assignment never creates one
- a table field is created if it doesn't exist yet
- an array index must already exist: assignment never grows an array, use `Array.push` for that

Only those three can be assigned to: `f() = 1` is a syntax error. An assignment is a statement on its own, so it can't be chained (`a = b = 1`) or used inside an expression. There is no compound assignment either: write `score = score + 10`, not `score += 10`.

## Expression statements

Any expression can stand on its own as a statement. Its result is thrown away, so this is only useful for expressions that do something as they're evaluated — in practice, function calls:

```
Debug.log("hello")
Array.push(inventory, "lamp")
```
