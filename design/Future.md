# Future ideas

## ✅ 1. Let underscore identifier be special - DONE

Currently this is raises an error:

```
let _ = 123
let _ = 345

    -> “_” is already defined in this scope
```

We should allow the `_` be a throwaway value. This could pair nicely if we allow structural unpacking (see below).

## 2. Structural unpacking

Let unpack values from a collection, being an array or table:

```
let _, b = [1,2]
print(b)
 --> 2

let x, y = {x=1, y=2}
print(y)
 --> 2

# Or...

let [_, b] = [1,2]
let { x, y } = {x=1, y=2}
```

Notes:
* [Quirrel][q] allows this by using the `[a, b]` or `{x, y}` to specify the source data structure, which makes sense too since it communicates the intent better.
* Using `_` from point 1.

## 3. Expand String.format to use name look ups

Use a new name look up syntax to allow to pass a table as an argument.

```
String.format("I ate %{count}d apples and I feel %{status}s.", {count: 5, baz: false, status: "fine"})
```

Notes: 
* The `baz` field is ignored 
* The positions of the table fields are not significant while resolving the format string names

# 3a. Allow String.format to accept multiple arguments

We can implement native functions as variadic.

```
String.format("First %s, then %s", "this", "that")
```


## ❌ 4. Multiple variables declarations on the same line - REJECTED

A really little thing, today this isn't allowed:

```
let a=1, b=2, c=3
```

Could be superseded by structural unpacking, although is not really as clear. E.g.:

```
let a, b, c = [1,2,3]
```


# 5. Allow more types as table field names 

Allow specify a numeric index like Squirrel, with a array-like syntax: 

```
local tbl  = {
    some_slot = "foo"
    [99] = "Ninetynine"
}
```

This is more flexbile than that: https://developer.electricimp.com/squirrel/squirrel-guide/variables-collections#tables you can use various  types as keys. 

I think we need to implement this only if there's a real usage need. 


## 6. Conditional expression

There's no way to choose a value with a condition, because `if` is a statement. Today it takes a variable plus an `if`, or a function with two `return`s. It has to be syntax, not a function, because a function would evaluate both branches.

**Use cases in Delores** (as of 2026-10-29: `Delores/`, `Delores/Scenes/` and `Shared/` in elm-adventure, 32 files, about 8,700 lines, 328 `if` statements). 58 of them, about 18%, only choose between two values:

| Pattern | Count | Example |
|---|---|---|
| Two `return`s choosing a value | 25 | object property functions: `name`, `photo_name`, `for_story`, `icon` |
| The same call, one argument differs | 24 | 16 `Actor.say_line`, 4 `Actor.set_state`, 2 `Actor.face` |
| The same target assigned in both branches | 5 | `self.default_verb = "verb_use"` / `"verb_open"` |
| A default, then overridden | 4 | `let text = template`, then `if noun1 != nil: text = ...` |

- About 38 fit on one line in 100 characters or less: nearly all the returns, the `set_state` and `face` toggles, and most assignments. The other 20 or so are mostly `say_line` with two full dialogue lines (120 to 260 characters). Those read better as an `if` statement, whatever syntax we pick.
- The original Dinky scripts used `? :` about 65 times, and the port turned them into `if` statements. None is nested or chained. About 15 aren't needed in Zak: `x ? YES : NO` (a Zak condition is already a `Bool`) and `a ? a : default`.

The typical case, as it is today (`Vista.zak`):

```
name = function(self):
    if self.sploded:
        return "radioactive crater"
    end
    return "Edmund Mansion mansion"
end,
```

**Options considered:**

1. **C: `cond ? a : b`.** The most compact and the most familiar. But `?` is an obscure symbol for a script writer, and `:` already means "a block follows" (`if cond:`, `else:`, `function():`).
2. **Python: `a if cond else b`.** No new keyword, and only 4 characters longer than C. It reads out of order: the condition, which is evaluated first, sits in the middle.
3. **Make `if` itself an expression.** Fully (a block's value is its last statement), or restricted to one expression per branch: `if cond: a else: b end`. The full version needs a value for every block and a meaning for `return` / `break` inside a value. It would also break waits inside an `if`: `execStatement` can suspend a thread, `evalExpr` can't. The restricted version needs no new keyword and can span lines, but it's the longest on one line, and the typical case ends in `end end`. Its strengths, chains and multi-line branches, aren't needed: no Delores case uses them.
4. **Elm: `if cond then a else b`.**

The typical case with each:

```
name = function(self): return self.sploded ? "radioactive crater" : "Edmund Mansion mansion" end,
name = function(self): return "radioactive crater" if self.sploded else "Edmund Mansion mansion" end,
name = function(self): return if self.sploded: "radioactive crater" else: "Edmund Mansion mansion" end end,
name = function(self): return if self.sploded then "radioactive crater" else "Edmund Mansion mansion" end,
```

**Proposal: Elm's form.**

- It reads in order, as plain English, with no symbol to learn.
- `:` keeps a single meaning. The rule is: **`:` opens a block, `then` picks a value.** The statement has blocks closed by `end`; the expression has single expressions and no `end`.
- `else` is required, so a missing branch is a syntax error, not a silent `nil`.
- `else if` chains work with no extra rules.
- `?` stays free for null-safe access (`a?.b`) or `??`, if we ever need them. Dinky used `?.` a lot.
- It costs one reserved word, `then`. No `.zak` file in elm-adventure or elm-zak uses it as a name (as of 2026-10-29).
- It's 9 characters longer than C. About 34 of the 38 short cases still fit in 100 characters, against 37 for C.

**How it would work:**

- The parser treats `if … then … else …` as a primary expression. The `else` branch is a full expression, so it extends as far as it can: `if c then 1 else 2 + bonus` adds `bonus` only in the `else` branch (C and Python behave the same). Parentheses fix it.
- At the start of a statement, `if` always means the `if` statement. `if c then f() else g()` there is an error, not a second way to write a one-line `if` statement.
- Mixing up the two forms gets a targeted error: `let x = if c: a else: b end` says an `if` that produces a value uses `then`, and `if c then` as a statement says an `if` statement uses `:`.
- Like any expression, it can't span lines, so the long `say_line` cases stay `if` statements.
- One new `Expr` variant. The interpreter evaluates the condition, which must be a `Bool`, then only the chosen branch. A waiting call in a branch gets the usual "a waiting call must be a statement on its own" error.

**Side findings, with no language change:**

- 4 guard returns can use `and` today. `if not is_table(value): return false end` / `return "_is_actor" in value` becomes `return is_table(value) and "_is_actor" in value` (`ActorHelpers.zak:51`). The same goes for `SheriffsOffice.zak:204`, `IdleHelpers.zak:90`, and `Items.zak:266` (if `get_value` always returns a `Bool` there).
- Only 3 cases default a `nil` (`Items.zak:29`, `DoorHelpers.zak:117`, `InventoryHelpers.zak:194`): too few to justify `??` now.
- Most of the verbosity comes from the function wrapper, not the `if`. Dinky's `name = @expr` shorthand made a property one line. Even with a conditional expression, Zak still needs `function(self): return … end`. That's a separate idea, if it comes up.


## ✅ 7. Private `_` names in included files - DONE

**Done (2026-11-03),** as described under "How privacy works" below. `include` gives each file a frame of its own (`State.fileFrames`), `bindingEnv` decides where a top-level `let` / `const` binds, and reading or assigning another file's `_` name is a `PrivateName`. The host sees it as an `UndefinedName`, with a message naming the file. The guide covers it in `guide/language/Execution.md`, "Private names". Still open: host access to private names, which the save walk needs (below).

Keep a file's top-level `_underscored` names private to it, so `include` doesn't make them visible to the including script:

```
# In Helpers.zak
let _my_internal_function = function(): ...
let public_function = function(): ...

# In Boot.zak
include("Helpers.zak")

public_function(...)          # OK
_my_internal_function(...)    # Error: _my_internal_function is private to Helpers.zak
```

**How `include` worked before.** It ran the file's statements directly in the shared world frame (`state.globalFrameId`), so every top-level `let` of every included file landed in the same frame and was visible everywhere.

**How privacy works.** Running each file in its own frame and then copying the public names into the world frame doesn't work: it leaves two copies of every public variable, and the file's own functions would update their copy while other files read the other one. Instead, decide where each binding goes when the `let` runs:

- Each included file runs in its own frame, whose parent is the world frame.
- A top-level `let` / `const` whose name starts with `_` binds in the file frame. Any other name binds directly in the world frame, so there's only one copy.
- Functions defined in the file capture the file frame, so lookups go file frame → world frame: they see both their private names and all globals. Other files only see the world frame.
- The error should say why: "private to Helpers.zak", not just "undefined".
- Only top-level names: a `let` inside a function or block, a table field (`_id`, `_state`), and the throwaway `_` stay as they are.
- The state keeps each included file's frame, with its path (`fileFrames`). The error message uses it, and so will the save walk (below).
- Code the host runs directly (the root script, or a `Zak.run` snippet such as a compiled yack) stays in the world frame: only included files get one.
- A side benefit: two files can each have their own `_ladder`, with no `AlreadyDefined`.

That's one new frame per include, a check in `let` / `const`, and the error message. The interpreter change is small and contained.

**The game is ready (as of 2026-11-03).** `_` used to mean "engine-facing" too, inherited from Dinky, where `_enterRoom`, `_clickedAt` and similar are system callbacks. On 2026-10-15 elm-adventure had 42 top-level `_` names, many deliberately shared: Elm looked up the `_on_*` callbacks, `_verbs_for`, `_current_scene` and others by name. Since then:

- The engine hooks have plain names (`Input.on_click`, `Input.verb_menu`, `Game.on_yack_started`, ...). Elm reads no `_` global any more, only the `_id`, `_key` and `_scene_id` table fields, which privacy doesn't touch.
- The 9 helpers other files used lost their `_` (2026-11-03): `check_verbs`, `can`, `can_function`, `default_verb` and `replace_object_item` (VerbHelpers), `face_toward` (ActorHelpers), `base_door`, `base_drawer` and `set_door_state` (DoorHelpers). The VerbHelpers ones are internals shared between the Shared files, which file-level privacy can't express, so they're public now.

The other 37 `_` names are only used in their own file.

**Save games.** elm-adventure's `design/Save Games.md` plans the Zak side of a save as a walk of the world frame (`Zak.globals`). It isn't built yet. Private names would drop out of that walk, and some hold game state:

- reassigned at runtime, so only the name reaches the value: `_active_stories` and `_completed_stories` (Note), `_music_sid`, `_ambient_sid`, `_ambient_sound`, `_room_music_sid` and `_playing_pool` (SoundHelpers);
- changed in place: `_once_checks`, `_inventory`, `_photos_taken` and `_active_photos_taken`, lost too unless a public global also reaches them.

So the public API needs a way to list and set each file's private names, saved at a path like `Note.zak/_active_stories`. The alternative, "private names aren't saved", would push that state into public tables, a surprising rule.

**Docs.** `guide/language/Lexical.md` points to the new "Private names" section in `guide/language/Execution.md`, which doesn't name `include` (the guide doesn't cover it). `nativeInclude`, `globals` and `setGlobal` in `Zak.elm` say what a host can and can't reach.

**The name stays `include`.** Public names still land in the shared world, with no table to reach them through.

**Prior art:**

- **Dart:** an `_name` is private to its library, enforced by the language. The closest match to this idea.
- **Python:** `from m import *` skips `_name`s, but `m._name` still reaches them. Only a convention.
- **Go:** an initial capital letter means exported, lowercase means unexported. A naming rule, like this idea.
- **Lua:** a top-level `local` is private to its file, and globals are shared. A keyword, not a naming rule.

**Settled:** `_` means "private" (Dart-style). The clash with engine hooks, which made a Lua-style keyword worth considering, is gone (above). What's left is the save API.


## 8. Enums

elm-adventure's `Helpers.zak` has 37 string constants (`const FRONT = "Front"`, `const OPEN = "open"`, ...). They exist so a typo in the *name* (`OPNE`) is an undefined-name error. Could an `enum` concept do better?

**What constants catch, and what they don't.** They catch a mistyped constant name. They don't catch:

- **Using the string directly.** The game already does this: `Actor.set_state(self, "off")` (`Alleyway.zak:169`), `"open"`/`"closed"` (`MainStreet.zak:58, 61`), `"open"` (`SystemHelpers.zak:204`). A typo there (`"opne"`) only fails when the engine gets it.
- **Using the wrong group.** Everything is a string, so `Actor.face(actor, EASE_IN)` is accepted until the engine decodes it.

**The constants are three different things** (as of 2026-10-19):

| Group | Constants | Closed set? |
|---|---|---|
| Directions, scene effects, easing | `FRONT`, `BACK`, ...; `FX_FADE_IN`, ...; `LINEAR`, `EASE_IN`, ... | yes: the engine accepts exactly these (`Engine.Direction`, `Engine.SceneFx`, `Engine.Curve`) |
| Object states | `OPEN`, `CLOSED`, `ON`, `OFF`, `GONE`, `HERE` | no: a state is any name an object defines; these are just the common ones |
| Colors | `COLOR_*` | no: they're values with names |

So an enum would only fit the first group, 12 constants.

**Three ways it could work:**

1. **No language change: group with tables.** Works today, and a missing field is already an error:

   ```
   const Direction = { front = "Front", back = "Back", left = "Left", right = "Right" }

   Actor.face(actor, Direction.front)
   Actor.face(actor, Direction.frnot)   # error: Direction has no field frnot
   ```

   Catches typos like `const` does, groups related values, and makes them easy to find. Doesn't stop raw strings or wrong groups, and fields can still be reassigned.
2. **`enum` as syntax for named constants**, like Squirrel and GDScript: `enum Direction: Front, Back, Left, Right end`. Just a shorter way to write option 1: the values are still plain strings or numbers, so it catches nothing new.
3. **A real enum type.** `Direction.Front` is a new kind of value, different from any string: `==` matches only itself, `type()` reports `"Direction"`, `String.from` shows `"Direction.Front"`, and a function expecting a direction can reject a string or another enum's value. The only option that catches raw strings and wrong groups, and by far the most expensive: a new `Value` variant through the interpreter, equality and display; a breaking change to the public `Zak.Value` type; and every engine native that takes a direction, effect or curve has to decode enum values instead of strings.

**Prior art:**

- **Lua:** no enums; plain strings or tables of constants (option 1).
- **Squirrel:** `enum`, as compile-time named constants (option 2).
- **GDScript:** named integers plus a dictionary (options 1 and 2).
- **Ruby:** symbols (`:open`), interned strings of their own type. A lighter option 3.
- **Python:** the `enum` module, a library, close to option 3.
- **Elm:** custom types, the full option 3, checked at compile time.

**Is it worth it?** Not now. In a dynamic language even option 3 catches the mistake at runtime, at the same moment the engine already rejects an unknown string. The gain is a better error message, at the cost of a new value type and a breaking API change, for 12 constants, with no bug from a mistyped one found so far.

Cheaper steps that get most of the benefit:

1. Make the engine's error for an unknown value list the valid ones ("`"Frnot"` isn't a direction: expected Front, Back, Left or Right"). Catches raw strings and wrong groups, with no language change.
2. Optionally group the closed sets as tables (`Direction.front`, `Fx.fade_in`, `Ease.ease_in`).
3. Replace the few raw `"open"`/`"off"` literals in the scenes with the constants, so the code doesn't mix both styles.

Revisit option 3 if bugs from wrong strings show up. Ruby-style symbols would probably be the lightest way to give these values their own type.


[q]: https://quirrel.io/doc/coming-from/squirrel.html

## 9. Simpler lambda functions

Instead of today's:

    Array.filter(prices, function(p): return p <= 25 end)

We could have: 

    Array.filter(prices, \(p) -> p <= 25)

or, coupled with a Elm-like ternary op:

    Array.map(prices, \(p) -> if p > 100 then "Expensive" else "Quite cheap")

The `\(args) -> expr` only holds an expression, so no `return` required. 

The backslash-arrow combo comes from Elm.