# Stdlib improvements

Which `Array`, `Table` and `String` functions would make game scripts shorter and say what they do. Surveyed on 2026-11-03 against elm-adventure's `Delores/` and `Shared/` folders (`rework` branch): 35 `.zak` files, about 9,100 lines. The yack files use no arrays or tables. Line numbers are as of that date.

**Short answer:** four additions cover the patterns that keep coming back:

- an optional default for `get_default`;
- `Table.merge`;
- `Array.any` and `Array.find`;
- a way to add to an array used as a set.

`Table.keys` and `Table.values` are optional. On the string side, the game has everything it needs. `Array.sort`, `String.contains`, and width and precision in `String.format` wait for a use case.

This replaces two earlier surveys of the DeloresDev Dinky scripts:

- **`Array API Gaps.md`** (2026-10-06). Everything it proposed is done, except two:
  - **Sorting**, carried over [below](#sorting).
  - **`Array.remove_at`**, which nothing needs: the port uses `Array.slice` where Dinky used `arrayremovefirst`.
- **`String API Gaps.md`** (2026-10-13). What's left of it is in [Strings](#strings) and [Truncating numbers](#truncating-numbers).

## How the stdlib is used today

| Function | Calls |
|---|---|
| `Table.get_default` | 50 |
| `Array.range` | 15 |
| `Table.get` | 14 |
| `Array.length` | 10 |
| `Array.push` | 9 |
| `Array.contains` | 7 |
| every other `Array` / `Table` function | 4 or fewer |
| `Array.each` | 0 |

There are 35 `for` loops.

## Worth adding

### 1. An optional default for `get_default` (done)

**Done on 2026-11-03.** `default` is now optional, `nil` when omitted, on both `Table.get_default` and `Array.get_default`. The names stay.

29 of the 50 `Table.get_default` calls pass `nil` as the default. They read a field that may not be there, because reading a missing field with `.` is an error:

```
let exec = Table.get_default(actor, "_exec", nil)
let pool = Table.get_default(scene, "music_pool", nil)
```

Making `default` optional, with `nil` as its own default, shortens all 29. The same change applies to `Array.get_default`, as the ToDo already suggests, along with its question about renaming it (`safe_get`, `get_or_default`).

### 2. `Table.merge(table, other)`

Sets every field of `other` on `table`, overwriting the ones `table` already has, and returns `table`. `other` is left untouched. The copy is shallow, like `Table.clone`. It mutates the way `Array.append` does: it edits one specific table.

Two identical blocks do this by hand today, the "base object plus overrides" pattern that replaces Dinky's delegates:

- `_with_base` (`Shared/SystemHelpers.zak:74-80`), for doors and drawers;
- `define_actor` (`Shared/ActorHelpers.zak:56-60`).

```
# Now
let object = Table.clone(base)
Table.each(table, function(key, value):
    Table.set(object, key, value)
    return nil
end)

# With Table.merge
let object = Table.merge(Table.clone(base), table)
```

### 3. `Array.any(array, predicate)` and `Array.find(array, predicate)`

`any` is `true` if `predicate` is `true` for at least one element. `find` returns the first element `predicate` is `true` for, or `nil` if there's none.

Four loops search an array by hand:

| Where | What it does | Becomes |
|---|---|---|
| `Note.is_active_story` (`Delores/Note.zak:201`) | `return true` inside the loop, `return false` after it | `any` |
| `_check_verbs` (`Shared/VerbHelpers.zak:58-63`) | sets a `has_chain_verb` flag | `any` |
| `_default_verb` (`Shared/VerbHelpers.zak:104-108`) | keeps the first match with `if verb == nil and ...`, with no `break` | `find` |
| the camera's `bad_story` hint (`Delores/Items.zak:215-220`) | takes the first matching pair, says it, then `break` | `find` |

```
# Now
for story in String.split(story_list, ","):
    if story in _active_stories:
        return true
    end
end
return false

# With Array.any
return Array.any(String.split(story_list, ","), function(story): return story in _active_stories end)
```

Notes:

- **`find` and `nil`.** `find` can't tell "found a `nil`" from "found nothing". No array in the game holds `nil`. If that ever matters, `find` could take a default, like `get_default`.
- **No use case for `all`**, but it could come with `any` for symmetry.
- **No use case for counting.** Nickel's good and bad photo counts play a sound and a line for each photo, so they stay a loop.
- **Lambdas are long.** With today's syntax, these one-liners run long. The shorter lambdas in `Future.md` (section 9) would help most here.

### 4. Adding to an array used as a set

Zak has no set type, so six arrays act as one:

- `heard_about_subjects`
- `_photos_taken`
- `_active_photos_taken`
- `_completed_stories`
- `_inventory_names`
- each actor's inventory

`in` checks for a value and `Array.remove` takes it out, but adding one is always written by hand, in three shapes:

| Shape | Where |
|---|---|
| push unless it's there | `heard_about` (`Delores/Globals.zak:80`), `pickup_object` (`Shared/InventoryHelpers.zak:87`) |
| check, react if it's there, else push | `_photos_taken` (`Delores/Items.zak:117-125`), `_inventory_names` (`Shared/InventoryHelpers.zak:43-46`) |
| remove, then push (move it to the end) | `Note.take_photo` (`Delores/Note.zak:225`), `Note.save_game` (`Delores/Note.zak:260`) |

Nothing reads the order of `_active_photos_taken` or `_completed_stories`, so "push unless it's there" would do the same job as "move it to the end".

The proposal is a function that pushes `value` unless `array` already holds an equal one, compared the same way as `==`. It returns `true` if it pushed, like `Array.remove` returns `true` if it removed. That return value folds the "check, react" shape into one call:

```
if not Array.push_unique(_photos_taken, taken_key):
    Actor.say_line(actor, "I already took a photo of that.")
    return nil
end
```

**Open: the name.** `Array.push` returns the array, so a `push_...` name that returns a `Bool` breaks that pattern. Other names to consider: `Array.add`, `Array.include`.

### 5. Maybe: `Table.keys(table)` and `Table.values(table)`

`Table.each` is the only way to walk a table. Two of its four uses only filter fields, or collect them into an array declared outside the loop:

- `define_scene` (`Shared/SystemHelpers.zak:36`);
- `_check_verbs` (`Shared/VerbHelpers.zak:36`).

With `keys` and `values`, both become a plain `for` loop that skips with `continue` instead of `return nil`. The order would be the one `Table.each` uses, sorted by field name. The gain is small, but nearly every language has these two.

## Recurring, but game helpers rather than stdlib

These patterns come from elm-adventure's own conventions, so they belong in its `Shared/` helpers:

- **Numbered objects**, the most repeated pattern overall, in 15 places. The names come from the scene JSON, so a helper like `numbered(self, "star", 1, 43)`, returning the array, fits better than a stdlib function.
  - 10 are `Table.get(self, String.format("star%d", [i]))` inside an `Array.range` loop (Nickel, QuickiePalOutside, AStreet, BookStore).
  - 5 are hand-written lists like `[self.slotSpot1, ..., self.slotSpot5]` (SheriffsOffice's drawers, Diner's spots and fireballs, PostOffice, QuickiePal).
- **`get_value(x, Table.get_default(x, field, default))`**, 9 times: a field that may be a function computing its value. A helper like `value_of(subject, "article", "a")` would cover it.
- **Optional hooks.** Both shapes come from a missing field being an error. Item 1 shortens them, and a helper like `call_hook(obj, "end_yack")` would fold the second.
  - `is_function(Table.get_default(obj, name, nil))` appears 6 times.
  - "Call it if it's there" appears 5 times: `start_taking_photo`, `done_taking_photo`, `end_yack`, `state_change`, `init`.

## Not worth it

- **Swap.** Only the ripple shuffle does one (`Delores/Note.zak:131-137`).
- **Concatenation.** `Array.append([radio], self.drawers(self))` (`Delores/Scenes/SheriffsOffice.zak:363`) already works as one, because the literal is a new array.
- **Taking the first n.** `Array.slice(a, 0, n)` reads fine.
- **Get or create.** `get_inventory` is the only case.
- **A bounds check before `Array.get`.** `Delores/Scenes/AStreet.zak:81-84` does by hand what `Array.get_default(array, index, nil)` already does.
- **Pairs read with `[0]` and `[1]`** (`[story, line]`, `[title, text]`). Structural unpacking (`Future.md`, section 2) is the fix, not a new function.
- **`Array.last`.** `a[Array.length(a) - 1]` already does it.

## Callbacks can't wait

A function passed to a native can't wait: it fails with `SuspendedNotAllowed`. 12 of the 35 `for` loops wait, through `Thread.wait_*` or a cutscene, so `Array.each` can't replace them. That's a point against the ToDo item "Drop `for .. in`".

The same limit applies to `any` and `find`, but a predicate has no reason to wait.

## Sorting

Carried over from `Array API Gaps.md`.

An array can hold values of any type, but Zak can only order some of them: `==` accepts any two values, while `<`, `<=`, `>` and `>=` only accept two numbers or two strings. Sorting doesn't need an order across all types, though. It can reuse the order `<` already has, plus a way out for everything else.

How other languages deal with it:

1. **They define an order across all types.**
   - Erlang and Elixir rank the types themselves, so any two values compare.
   - Python 2 ordered mixed types by type name, which was arbitrary, and Python 3 dropped it.
   - JavaScript's default `sort()` converts everything to strings, so `[10, 9, 1].sort()` gives `[1, 10, 9]`.
   - PHP converts between types loosely.
2. **They sort only what `<` can compare, and raise an error otherwise.** Python 3, Lua's `table.sort`, Ruby and Squirrel do this. Elm does the same at compile time: `List.sort` only accepts `comparable` values.
3. **They let the caller supply the order.** Every language in group 2 also has this, for tables, objects and custom orders: Python's `sorted(xs, key=fn)`, Lua's `table.sort(t, comp)`, Squirrel's `arr.sort(fn)`, Ruby's `sort_by`, Elm's `List.sortBy` and `List.sortWith`.

The proposal follows groups 2 and 3, with no new rules:

- **`Array.sort(array)`** sorts an array of all numbers or all strings, in the order `<` uses. Anything else gives the same `TypeError` `<` would give for that pair. Mixed types are rejected, not ordered by an invented rule.
- **A key function later, if needed**, for example `Array.sort_by(array, fn)`, where `fn` returns a number or a string. That sorts tables (game objects by name, say) without ever comparing tables directly.
- **It returns a new array.** Sorting derives a whole new array, so, by the same rule as `Array.slice` and `Random.shuffle`, it doesn't mutate. That's Elm's choice too. Python, JavaScript and Lua sort in place.

The evidence is thin:

- DeloresDev sorts twice (`arrayrsort`), in debug menus only, on lists of strings, in reverse order. Reverse order would need either an `Array.reverse`, which Zak doesn't have, or a comparator.
- The elm-adventure scripts never sort.

Wait for game code that needs sorting before designing it further.

## Strings

Carried over from `String API Gaps.md`. That survey left out `TranslationHelpers.dinky`: Zak has no translation system.

### Done

**`String.starts_with(string, prefix)` and `String.ends_with(string, suffix)`.** Their rules:

- The string being checked comes first, like every other `String` function.
- An empty prefix or suffix is always `true`, and one longer than the string is `false`, not an error.
- The check is case-sensitive: call `String.lower` first to ignore case.
- There's no position argument: `String.slice` covers that.

They cover Dinky's `strstartswith` and `strendswith`, and its `line[0] == '+'` checks, since `[ ]` only works on arrays in Zak. elm-adventure's `_check_verbs` uses them (`Shared/VerbHelpers.zak:37`, `44`).

Everything else Dinky does with strings already has a counterpart:

| Dinky | Zak |
|---|---|
| `sizeof` (on a string) | `String.length` |
| `format` | `String.format` |
| `is_string` | `is_string`, `type` |
| `strslice` | `String.slice` |
| `strsplit` | `String.split` |
| `strreplace` | `String.replace` |
| `strupper` | `String.upper` |

`strslice(filter, 0, -2)`, in debug code only, drops the last character with a negative end. In Zak that's `String.slice(s, 0, String.length(s) - 1)`.

### Left

- **`String.contains(string, part)`, a weak case.** Dinky uses `strfind` once, in `Newspaper.dinky:17`, and `strfindi` once, in the debug filter (case-insensitive). Both only check whether the part is there and never use the index. The port's Newspaper close-up does without it, and there's no debug menu.
  - If it's added, it would mirror `Array.contains` rather than be a `find`.
  - A case-insensitive check would be `String.contains(String.lower(a), String.lower(b))`.
- **Skip `chr`.** It turns a key code into a character, for the debug menu only, and key handling belongs to the host.

### Width and precision in `String.format`

`String.format` supports `%s`, `%d`, `%f`, `%x`/`%X` and `%%`, with no width or precision. There's a common syntax for both, C's `printf`: `%[flags][width][.precision]type`.

| Part | Meaning | Example | Result |
|---|---|---|---|
| width | minimum field width, padded with spaces on the left | `%5d` with 42 | `"   42"` |
| `-` flag | pad on the right instead (left-align) | `%-5d` with 42 | `"42   "` |
| `0` flag | pad with zeros instead of spaces | `%08x` with 255 | `"000000ff"` |
| `.precision` on `%f` | digits after the decimal point | `%.2f` with 3.14159 | `"3.14"` |
| `.precision` on `%s` | maximum number of characters | `%.3s` with "abcdef" | `"abc"` |
| combined | width and precision | `%6.2f` with 3.14159 | `"  3.14"` |

A few more flags exist (`+`, a space, `#`, `*`), but they're rarely used.

Who uses it:

- **The same syntax:** C, Squirrel (and so Dinky), Lua's `string.format`, Python's `%` operator, Ruby's `format`, Go's `fmt`, Java's `String.format`, PHP's `sprintf`, and the shell's `printf`.
- **The same ideas, a different syntax:** Python's `"{:08x}"` and C#'s `"{0,8:F2}"`.
- **None built in:** JavaScript (`toFixed`, `padStart`) and Elm core.

Zak already uses `%` directives, so extending them the printf way adds no new syntax. It's also what Squirrel and Lua, the languages closest to Zak, do.

There's almost no evidence for it:

| Source | Directives used |
|---|---|
| Dinky | `%d` ×10, `%s` ×6, `%08x` ×1 (only in the `dprintx` debug macro) |
| elm-adventure | `%s` ×41, `%d` ×17; no `%f`, `%x`, `%%` or width |

Two cases are likely to come up in game code eventually:

- **Precision on `%f`.** `%f` prints the full value today, so `0.1 + 0.2` shows as `"0.30000000000000004"`. `%.2f` is the usual fix, but Elm has no `toFixed`. Rounding to *n* digits correctly with floats is harder than it looks: `1.005` is stored as `1.00499…`. It would need a package like `myrho/elm-round`, or a careful hand-written version.
- **Zero-padded width on `%d`.** `%02d` is the usual way to show a timer or a clock (`"01:05"`). It's easy to implement.

If it's implemented, keep to a small printf subset: width, the `0` and `-` flags, and precision on `%f` only. Wait for game code that needs it.

## Truncating numbers

Carried over from `String API Gaps.md`. Dinky uses `as_int` 13 times:

- **5 turn a bool into a number.** Zak doesn't need that: it has real bools.
- **8 truncate a number** (volume steps, pixel snapping).

Zak has `Math.round`, and `//` rounds down (`x // 1`), so the only thing missing is truncation toward zero. That differs from rounding down only for negative numbers. elm-adventure uses `Math.round` twice and never `//`. Nothing to add for now.

## Suggested order

1. ✅ An optional default for `get_default`: the most call sites. Done.
2. `Table.merge`: small, with no open questions.
3. `Array.any` and `Array.find`, maybe with `Array.all`.
4. Adding to a set, once the name is settled.
5. `Table.keys` and `Table.values`, if the table side should be complete.
6. `Array.sort`, `String.contains`, and width and precision in `String.format`, when game code needs them.
