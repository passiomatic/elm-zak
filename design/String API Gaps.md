# String API gaps

String operations used by the Dinky scripts in DeloresDev (49 `.dinky` files, ~11.8k lines) that the current `String` API doesn't cover yet. Survey done on 2026-10-13.

Uses in `TranslationHelpers.dinky` are left out: Zak has no translation system.

Everything else Dinky does with strings already has a Zak counterpart: `sizeof` (on a string) → `String.length`, `format` → `String.format`, `is_string` → `type(x)`, `strslice` → `String.slice`, `strsplit` → `String.split`, `strreplace` → `String.replace`, and `strupper` → `String.upper`. Two small differences, both in debug code only: `strslice(filter, 0, -2)` (DebugHelpers.dinky:76) uses a negative end to drop the last character, which in Zak is `String.slice(s, 0, String.length(s) - 1)`; and the `dprintx` macro uses a field width (`%08x`), which Zak's `%x` doesn't support.

The elm-adventure port has no string stand-ins: `registerVerbs`' warnings, which check table keys for a `verb_` prefix, were ported once `String.starts_with`/`String.ends_with` existed, and the other code that needs these gaps (the ending credits, the debug menu) hasn't been ported yet.

## Gaps

| Dinky | Uses | Where | What it does |
|---|---|---|---|
| `strstartswith` | 1 + 2 hidden | VerbHelpers.dinky:222; `line[0] == '+'` / `'-'` (Ending.dinky:24, 28) | Prefix check |
| `strendswith` | 2 | VerbHelpers.dinky:222 (×2) | Suffix check: skips `_text` / `_desc` keys when registering verbs |
| `strfind` | 1 | Newspaper.dinky:17 | Only checks whether `"$"` is in the text (`== null`); the index itself is never used |
| `strfindi` | 1 | DebugHelpers.dinky:16 | Case-insensitive "contains" for the debug filter |
| `chr` | 1 | DebugHelpers.dinky:86 | Key code → character. Debug only, and it depends on how the host reports keys. |

The "hidden" uses read one character with `[0]` to test a prefix. Zak's `[ ]` only works on arrays, so those are really `starts_with` checks.

## Suggested priority

1. ✅ **`String.starts_with` / `String.ends_with`** — DONE as `String.starts_with(string, prefix)` and `String.ends_with(string, suffix)`. The string being checked comes first, like every other `String` function. An empty prefix/suffix is always `true`, one longer than the string is `false` (not an error), and the check is case-sensitive (`String.lower` first to ignore case). No position argument: `String.slice` covers that. Dinky's VerbHelpers.dinky:222 becomes `String.starts_with(key, "verb_") and not String.ends_with(key, "_text") and not String.ends_with(key, "_desc")`, and Ending.dinky's `sizeof(line) > 0 && line[0] == '+'` becomes `String.starts_with(line, "+")`.
2. **`String.contains(string, part)`**, 2 uses, one of them debug only, so a weak case. Neither use needs the index, only whether `part` is there, so it would mirror `Array.contains` rather than be a `find`. A case-insensitive check would be `String.contains(String.lower(a), String.lower(b))`.
3. **Skip `chr`.** It's for the debug menu, and key handling belongs to the host.

## Proposal: width and precision in `String.format`

`String.format` supports `%s`, `%d`, `%f`, `%x`/`%X` and `%%`, with no width or precision. There's a common syntax for both: C's `printf`.

```
%[flags][width][.precision]type
```

| Part | Meaning | Example | Result |
|---|---|---|---|
| width | minimum field width, padded with spaces on the left | `%5d` with 42 | `"   42"` |
| `-` flag | pad on the right instead (left-align) | `%-5d` with 42 | `"42   "` |
| `0` flag | pad with zeros instead of spaces | `%08x` with 255 | `"000000ff"` |
| `.precision` on `%f` | digits after the decimal point | `%.2f` with 3.14159 | `"3.14"` |
| `.precision` on `%s` | maximum number of characters | `%.3s` with "abcdef" | `"abc"` |
| combined | width and precision | `%6.2f` with 3.14159 | `"  3.14"` |

There are a few more flags (`+` always shows the sign, a space pads positive numbers, `#` adds a prefix like `0x`, `*` takes the width from an argument), but they're rarely used.

Who uses it:

- **The same syntax:** C, Squirrel (and therefore Dinky), Lua's `string.format`, Python's `%` operator, Ruby's `format`, Go's `fmt` (which adds `%v`), Java's `String.format`, PHP's `sprintf`, and the shell's `printf`.
- **Same ideas, different syntax:** Python's newer `"{:08x}"` / `"{:.2f}"` uses the same width and precision rules inside braces. C#'s `"{0,8:F2}"` puts the alignment after a comma and the format after a colon.
- **None built in:** JavaScript uses `toFixed(2)` and `padStart(8, "0")` instead, and Elm core has nothing.

Zak already uses `%` directives, so extending them the printf way adds no new syntax, and it's what Squirrel and Lua (the languages closest to Zak) do.

The evidence is close to none:

| Source | Directives used |
|---|---|
| Dinky | `%d` ×10, `%s` ×6, `%08x` ×1 (only in the `dprintx` debug macro) |
| elm-adventure port | `%s` ×37, `%d` ×4, `%%` ×2 (no `%f` at all) |

Two cases are likely to come up in game code eventually:

- **Precision on `%f`.** `%f` prints the full value today, so `0.1 + 0.2` shows as `"0.30000000000000004"`. `%.2f` is the usual fix, but Elm has no `toFixed`, and rounding to *n* digits correctly with floats is harder than it looks (`1.005` is stored as `1.00499…`). It would need either a package like `myrho/elm-round` or a careful hand-written version.
- **Zero-padded width on `%d`.** `%02d` is the usual way to show a timer or clock (`"01:05"`). It's easy to implement.

If it's implemented, keep to a small printf subset: width, the `0` and `-` flags, and precision on `%f` only. Wait for game code that needs it before doing so.

## Outside strings

`as_int` is used 13 times. 5 uses turn a bool into a number, which Zak doesn't need since it has real bools. The other 8 truncate a number (volume steps, pixel snapping). `Math` has `round` but no `floor` or truncate, which might deserve its own look later.
