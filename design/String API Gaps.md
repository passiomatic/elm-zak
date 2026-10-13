# String API gaps

String operations used by the Dinky scripts in DeloresDev (49 `.dinky` files, ~11.8k lines) that the current `String` API doesn't cover yet. Survey done on 2026-10-13.

Uses in `TranslationHelpers.dinky` are left out: Zak has no translation system.

Everything else Dinky does with strings already has a Zak counterpart: `sizeof` (on a string) → `String.length`, `format` → `String.format`, `is_string` → `type(x)`, `strslice` → `String.slice`, `strsplit` → `String.split`, `strreplace` → `String.replace`, and `strupper` → `String.upper`. Two small differences, both in debug code only: `strslice(filter, 0, -2)` (DebugHelpers.dinky:76) uses a negative end to drop the last character, which in Zak is `String.slice(s, 0, String.length(s) - 1)`; and the `dprintx` macro uses a field width (`%08x`), which Zak's `%x` doesn't support.

The elm-adventure port has no string stand-ins yet, because the code that needs these gaps (verb registration from table keys, the ending credits, the debug menu) hasn't been ported.

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

## Outside strings

`as_int` is used 13 times. 5 uses turn a bool into a number, which Zak doesn't need since it has real bools. The other 8 truncate a number (volume steps, pixel snapping). `Math` has `round` but no `floor` or truncate, which might deserve its own look later.
