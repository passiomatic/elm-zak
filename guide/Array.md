# Array

Fixed-shape, ordered collections. An array is a reference, not a plain value — passing one to a function, or storing one in a `let`, never copies it.

`array` comes first in every function below, matching real precedent (Lua's own `table.insert(t, pos, value)`, Squirrel's dot-method-call style) rather than Elm's own argument order, which only makes sense there because of currying and `|>` — neither of which Zak has.

Every function below follows one rule for whether it mutates: a function that edits one specific part of the array (a slot, an appended value, the last element) mutates it directly, so every other reference to the same array sees the change. A function that derives a whole new array from the existing one (`map`, `filter`, `foldl`, `foldr`) never mutates — it always returns a new value instead.

`get`/`set` are bounds-checked: `index` must be `0 <= index < length(array)`. `index` must also be a whole number.

## Array.length(array)

Number of elements in `array`.

```
Array.length([1, 2, 3])   # 3
```

## Array.is_empty(array)

True if `array` has no elements.

```
Array.is_empty([1, 2, 3])   # false
Array.is_empty([])          # true
```

## Array.get(array, index)

Element at `index` (0-based). Errors if `index` is out of range or not a whole number.

```
Array.get([1, 2, 3], 1)   # 2
```

## Array.get_default(array, index, default)

Like `Array.get`, but returns `default` instead of erroring if `index` is out of range. An `index` that isn't a whole number is still a hard error — only an out-of-range index is softened.

```
Array.get_default([1, 2, 3], 1, 0)   # 2
Array.get_default([1, 2, 3], 9, 0)   # 0 (index 9 is out of range, so the default)
```

## Array.set(array, index, value)

Sets `index` to `value`.

```
let a = [1, 2, 3]
Array.set(a, 0, 99)   # a is now [99, 2, 3]
```

## Array.push(array, value)

Appends `value` to the end of `array`.

```
let a = [1, 2, 3]
Array.push(a, 4)   # a is now [1, 2, 3, 4]
```

## Array.append(array, other)

Appends every element of `other` to the end of `array`, in order, mutating `array`. `other` itself is left untouched.

```
let a = [1, 2]
Array.append(a, [3, 4])   # a is now [1, 2, 3, 4]
```

## Array.pop(array)

Removes and returns the last element of `array`. An empty `array` is an error, not `nil`.

```
let a = [1, 2, 3]
Array.pop(a)   # 3; a is now [1, 2]
```

## Array.contains(array, value)

True if `value` is present anywhere in `array`.

```
Array.contains([1, 2, 3], 2)   # true
Array.contains([1, 2, 3], 9)   # false
```

## Array.clone(array)

A new array with the same elements as `array` — a shallow copy. Top-level elements are independent afterward, but a nested array/table inside is still the *same* one, shared by reference.

```
let a = [1, 2, 3]
let b = Array.clone(a)
Array.set(b, 0, 99)
a   # [1, 2, 3], unaffected

let inner = [1]
let c = [inner]
let d = Array.clone(c)
Array.set(Array.get(d, 0), 0, 99)
c   # [[99]] — the nested array was shared, not copied
```

## Array.each(array, fn)

Calls `fn(element)` once per element, in order, for the side effect alone — discards whatever `fn` returns and never mutates `array`. An empty `array` is a no-op. For a transform, see `Array.map`.

```
Array.each([1, 2, 3], function(x): Debug.log(x) end)   # logs 1, then 2, then 3

let doubled = []
Array.each([1, 2, 3], function(x): Array.push(doubled, x * 2) end)
doubled   # [2, 4, 6]
```

## Array.map(array, fn)

A new array with `fn(element)` in place of every element. `array` itself is unchanged.

```
Array.map([1, 2, 3], function(x): return x * 2 end)   # [2, 4, 6]
```

## Array.indexed_map(array, fn)

Like `map`, but `fn` also receives each element's index: `fn(index, element)`.

```
Array.indexed_map([1, 2, 3], function(i, x): return i * x end)   # [0, 2, 6]
```

## Array.filter(array, predicate)

A new array holding only the elements where `predicate(element)` is `true`.

```
Array.filter([1, 2, 3], function(x): return x > 1 end)   # [2, 3]
```

## Array.foldl(array, fn, initial)

Reduces `array` to a single value, left to right: `fn(element, accumulator)`, starting from `initial`.

```
Array.foldl([1, 2, 3], function(x, acc): return acc + x end, 0)   # 6
```

## Array.foldr(array, fn, initial)

Like `foldl`, but right to left — the direction matters whenever `fn` isn't commutative.

```
Array.foldr(["a", "b", "c"], String.append, "")   # "abc"
Array.foldl(["a", "b", "c"], String.append, "")   # "cba"
```

## Array.range(lo, hi)

A new array of consecutive integers from `lo` to `hi`, inclusive of both. Empty, not an error, when `lo > hi`.

```
Array.range(3, 6)   # [3, 4, 5, 6]
Array.range(6, 3)   # []
```
