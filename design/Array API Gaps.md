# Array API gaps

Array operations used by the Dinky scripts in DeloresDev (49 `.dinky` files, ~11.8k lines) that the current `Array` API doesn't cover yet. Survey done on 2026-10-06.

Everything else Dinky does with arrays already has a Zak counterpart: `sizeof` → `Array.length`, `arrayappend` → `Array.push`, `arrayremovelast` → `Array.pop`, `arrayfilter` → `Array.filter`, `clone` → `Array.clone`, `randomfrom(a, b, c)` → `Random.pick([a, b, c])`, `foreach` → `for ... in`, and `x in arr` → `in`.

## Gaps

| Dinky | Uses | Where | What it does |
|---|---|---|---|
| `arrayremovefirst(arr)` | 4 | Note.dinky:142-145 | Takes items one at a time off the front of a shuffled copy |
| `arrayfindremove(arr, x)` | 3 | Note.dinky:221, 232, InventoryHelpers.dinky:109 | Removes an element by value, e.g. taking an object out of the inventory |
| `arrayshuffle(arr)` | 2 | Note.dinky:141, 151 | Shuffles in place and also returns the array (line 141 uses the returned value) |
| `arrayresize(arr, 5)` | 2 | Note.dinky:146, 148 | Only used to cut a list down to its first 5 items |
| `arrayrsort(arr)` | 2 | DebugHelpers.dinky:122, 174 | Sorts strings in reverse order. Debug menu only. |
| `arraylast(arr)` | 1 | DebugHelpers.dinky:66 | Last element. Debug only. |
| `loadarray("file.txt")` | 2 | BookStore.dinky, Ending.dinky | Reads a file's lines into an array. This is the host's job, not the stdlib's. |

Most of the gameplay need is in one place: the story-dealing logic in `Note.dinky:135-151`. It filters the stories, shuffles a copy, takes 4 from the front, and cuts the list to 5.

## Proposal: removing elements

Currently `Array.pop` (from the end) is the only way to remove an element. The proposal is two functions, named the way C# does `Remove` / `RemoveAt`:

- **`Array.remove_at(array, index)`** removes the element at `index` and returns it, the same way `Array.pop` returns what it removes. It follows the same index rules as `Array.get` / `Array.set`: an index that's out of range or not a whole number is an error, so an empty array is an error too, consistent with `Array.pop`. This covers `arrayremovefirst` as `Array.remove_at(arr, 0)`. Dinky's pattern becomes `Array.push(active_stories, Array.remove_at(completed_copy, 0))`.
- **`Array.remove(array, value)`** removes an element by value and covers `arrayfindremove`. The `_at` suffix keeps the two apart, which plain `remove(index)` (the Squirrel/Lua way) wouldn't, since it would leave no good name for removing by value.

`Array.pop_first` was considered and dropped. It only handles the front, and 4 calls in one spot don't justify a dedicated name. `Array.pop` stays as the shortcut for the most common case, the end.

`Array.remove` is now implemented, following C#'s `List.Remove`: it removes only the first match, in place, and returns `true` if it removed something or `false` if the value wasn't there (no error). Python's `list.remove` raises an error instead, while Squirrel, Lua and JavaScript have no remove-by-value at all.

How other languages remove the first element, for reference:

| Language | Call | On an empty array |
|---|---|---|
| Squirrel | `arr.remove(0)` | error |
| Lua | `table.remove(t, 1)` | returns `nil` |
| Python | `lst.pop(0)` | error (`IndexError`) |
| Ruby | `arr.shift` | returns `nil` |

## Proposal: sorting

An array can hold values of any type, but Zak can only order some of them: `==` accepts any two values, while `<`, `<=`, `>` and `>=` only accept two numbers or two strings. Sorting doesn't need an order across *all* types, though. It can reuse the order `<` already has, plus a way out for everything else.

How other languages deal with it:

1. **Define an order across all types.** Erlang/Elixir rank the types themselves (number < atom < … < tuple < map < list), so any two values compare. Python 2 ordered mixed types by type name, which was arbitrary and dropped in Python 3. JavaScript's default `sort()` converts everything to strings, so `[10, 9, 1].sort()` gives `[1, 10, 9]`, a famous trap. PHP converts between types loosely, with notoriously inconsistent results.
2. **Sort only what `<` can compare, and error otherwise.** This is the dominant modern choice. Python 3 (`TypeError: '<' not supported between 'int' and 'str'`), Lua (`table.sort`: "attempt to compare number with string"), Ruby (`ArgumentError: comparison of Integer with String failed`) and Squirrel (`arr.sort()` errors on incompatible types). Elm does the same at compile time: `List.sort` only accepts `comparable` values (numbers, strings, and tuples/lists of them).
3. **Let the caller supply the ordering.** Every language in group 2 also has this, for tables, objects and custom orders: Python `sorted(xs, key=fn)`, Lua `table.sort(t, comp)`, Squirrel `arr.sort(fn)` (returning -1/0/1), Ruby `sort_by { }` / `sort { |a, b| }`, Elm `List.sortBy` / `List.sortWith`, JavaScript `sort(compareFn)`.

The proposal follows groups 2 and 3, with no new rules:

- **`Array.sort(array)`** sorts an array of all numbers or all strings, using exactly the order `<` uses. Anything else is the same `TypeError` `<` would give for that pair. Mixed types are rejected rather than ordered by an invented rule, which keeps the JavaScript and PHP surprises out.
- **A key function later, if needed**, e.g. `Array.sort_by(array, fn)` where `fn` returns a number or a string. That covers sorting tables (game objects by name, say) without ever comparing tables directly.
- **It returns a new array.** Sorting derives from the whole array, so by the same rule as `Array.slice` and `Random.shuffle` it doesn't mutate. That's Elm's choice too, though Python, JavaScript and Lua sort in place.

The evidence is thin: `arrayrsort` is used twice, in debug menus only, on lists of strings. Plain `Array.sort` covers the comparison, but the *reverse* order would need either an `Array.reverse` (which Zak doesn't have yet) or a comparator. Wait for game code that actually needs sorting before designing it further.

## Suggested priority

1. ✅ **Remove by value** (`arrayfindremove`) — DONE as `Array.remove` (see above). `Array.remove_at` is still to do. In elm-adventure, the `_without` stand-in (`Note.zak`) and the `Array.filter` in `remove_inventory` (`InventoryHelpers.zak`) can now use `Array.remove`.
2. ✅ **Shuffle** (`arrayshuffle`) — DONE as `Random.shuffle(array)`, next to `Random.pick`. It returns a new array rather than shuffling in place, following the rule that a whole-array derivation doesn't mutate. Dinky's `arrayshuffle(clone(x))` becomes `Random.shuffle(x)`, and the in-place `arrayshuffle(x)` becomes `x = Random.shuffle(x)`.
3. ✅ **`Array.slice`** — DONE as `Array.slice(array, start, end=nil)`, with the same rules as `String.slice`. It returns a new array, like every other language's `slice` (in-place versions always go by another name: `splice`, `RemoveRange`, `resize`). It covers `arrayresize`: elm-adventure's `_first_of(a, n)` stand-in (`Note.zak`) becomes `Array.slice(a, 0, n)`.
4. **Sort** (`arrayrsort`). It's only used in debug menus, so it can wait. See "Proposal: sorting" above.
5. **Last** (`arraylast`). Skip it: `a[Array.length(a) - 1]` already does the job.
