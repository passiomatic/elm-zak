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

Still open for `Array.remove`: what happens when the value isn't there (returning a `Bool` the way C# does is the obvious choice), and whether it removes only the first match.

How other languages remove the first element, for reference:

| Language | Call | On an empty array |
|---|---|---|
| Squirrel | `arr.remove(0)` | error |
| Lua | `table.remove(t, 1)` | returns `nil` |
| Python | `lst.pop(0)` | error (`IndexError`) |
| Ruby | `arr.shift` | returns `nil` |

## Suggested priority

1. **Remove by value** (`arrayfindremove`), as `Array.remove`, together with `Array.remove_at` (see above). This is the only gap outside `Note.dinky`, and the inventory needs it.
2. **Shuffle** (`arrayshuffle`). It could go in `Random` next to `pick`, since `Random` already holds the randomness.
3. **`Array.slice`**. It covers `arrayresize` (keep the first 5 items) and would match the existing `String.slice`.
4. **Sort** (`arrayrsort`). It's only used in debug menus, so it can wait.
5. **Last** (`arraylast`). Skip it: `a[Array.length(a) - 1]` already does the job.
