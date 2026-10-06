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

## Suggested priority

1. **Remove by value** (`arrayfindremove`). This is the only gap outside `Note.dinky`, and the inventory needs it.
2. **Shuffle** (`arrayshuffle`). It could go in `Random` next to `pick`, since `Random` already holds the randomness.
3. **`Array.slice`**. It covers both `arrayresize` (keep the first 5 items) and taking items off the front, and it would match the existing `String.slice`. With it, a separate remove-first function may not be needed.
4. **Sort** (`arrayrsort`). It's only used in debug menus, so it can wait.
5. **Last** (`arraylast`). Skip it: `a[Array.length(a) - 1]` already does the job.
