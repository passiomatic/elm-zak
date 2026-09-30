# Arrays

An array is an ordered sequence of values, of any mix of types. Each element has a position, its index, counted from `0`.

```
let inventory = ["lamp", "key", "map"]
let grid = [[1, 2], [3, 4]]
```

## Construction

An array is built with square brackets, listing its elements separated by commas. `[]` builds an empty array. See [Array constructor](Expressions.md#array-constructor).

Every constructor builds a new array, separate from every other. [`Array.range`](../stdlib/Array.md) builds an array of consecutive whole numbers:

```
Array.range(1, 5)   # [1, 2, 3, 4, 5]
```

## Reading elements

An element is read with its index in square brackets. The first element is at `0`, the last at the array's length minus one:

```
inventory[0]                              # "lamp"
inventory[Array.length(inventory) - 1]   # "map"
grid[1][0]                                # 3
```

The index can be any expression that produces a number, as long as it's a whole number within the array:

```
inventory[3]     # error: index 3 is out of bounds — the array has 3 elements
inventory[-1]    # error: index -1 is out of bounds — the array has 3 elements
inventory[0.5]   # error: index 0.5 is not a whole number
```

Negative indexes are always out of bounds: there's no counting from the end. To read an index that might be out of bounds without an error, use `Array.get_default`:

```
let first = Array.get_default(inventory, 0, nil)
```

`[ ]` only works on arrays — not on tables or strings.

## Writing elements

An element is replaced with an assignment:

```
inventory[1] = "silver key"
grid[0][1] = 9
```

The index must already exist: assigning past the end is an error, not a way to grow the array.

## Growing and shrinking

Arrays change size through functions, which change the array in place:

| Function                    | Effect                                           |
| --------------------------- | ------------------------------------------------ |
| `Array.push(array, value)`  | adds `value` to the end                          |
| `Array.append(array, other)`| adds every element of `other` to the end         |
| `Array.pop(array)`          | removes the last element, and returns it         |

```
let stack = []
Array.push(stack, "a")
Array.push(stack, "b")
Array.pop(stack)       # "b" — stack is now ["a"]
```

`Array.push` and `Array.append` return the same array they were given, so calls can be nested: `Array.push(Array.push(stack, "c"), "d")`.

`Array.pop` on an empty array is an error. Check first with `Array.is_empty`:

```
while not Array.is_empty(stack):
    Debug.log(Array.pop(stack))
end
```

## Going through elements

`for` runs a block once for each element, in order:

```
for item in inventory:
    Debug.log(item)
end
```

When the index is needed too, loop over a range of indexes instead:

```
for i in Array.range(0, Array.length(inventory) - 1):
    Debug.log(String.from(i) ++ ": " ++ inventory[i])
end
```

For an empty array, that range is empty too, so the loop simply doesn't run.

The array is read afresh on every pass, so changes made to it inside the loop affect the rest of the loop: elements pushed are visited, elements popped are skipped. To loop over the array as it was when the loop started, loop over `Array.clone(inventory)` instead.

## Transforming arrays

A few functions build a new array, or a single value, out of an existing one, leaving the original untouched:

| Function                          | Result                                               |
| --------------------------------- | ---------------------------------------------------- |
| `Array.map(array, fn)`            | a new array with `fn(element)` for every element     |
| `Array.indexed_map(array, fn)`    | the same, with `fn(index, element)`                  |
| `Array.filter(array, predicate)`  | a new array with only the elements `predicate` accepts |
| `Array.foldl(array, fn, initial)` | a single value, combining elements left to right     |
| `Array.foldr(array, fn, initial)` | the same, right to left                              |

```
let prices = [10, 25, 40]
let affordable = Array.filter(prices, function(p): return p <= 25 end)   # [10, 25]
let total = Array.foldl(prices, function(p, sum): return sum + p end, 0) # 75
```

The rule is the same across every `Array` function: one that edits a specific part of the array — a slot, the end — changes it in place; one that derives something from the whole array returns a new value.

## Checking for an element

`in` is `true` if any element is equal to a value, by the same rules as `==`:

```
"key" in inventory   # true
```

`Array.contains(array, value)` does the same, as a function.

## Arrays are references

Assigning an array to a variable, storing it in a table, or passing it to a function never copies it: every name refers to the same array, and a change through one is visible through all of them. See [Values and references](Values.md#values-and-references).

For the same reason, two arrays are only `==` when they're the same array — two arrays with the same elements are still different arrays.

`Array.clone` makes a new array with the same elements. The copy is shallow: a table or array stored inside the original is shared with the copy, not duplicated.

See the [Array](../stdlib/Array.md) page for every function that works on arrays.
