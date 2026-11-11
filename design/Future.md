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
* In a `for` too: `for [story, line] in bad_story` unpacks each element of an array of pairs. Going over a table's fields, with no brackets, is section 11.

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
- Most of the verbosity comes from the function wrapper, not the `if`. Dinky's `name = @expr` shorthand made a property one line. Even with a conditional expression, Zak still needs `function(self): return … end`. That's a separate idea: see section 9.


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

A function that only computes a value still needs the whole block form, `return` and `end` included. The first draft took Elm's backslash-arrow form, whose body is a single expression:

```
Array.filter(prices, function(p): return p <= 25 end)    # today
Array.filter(prices, \(p) -> p <= 25)
Array.map(prices, \(p) -> if p > 100 then "Expensive" else "Quite cheap")    # with section 6
```

**Use cases in Delores** (as of 2026-11-04: `Delores/` and `Shared/` in elm-adventure, 623 function literals):

| Body | Count | Where |
|---|---|---|
| A single `return expr` | 122 (20%) | 104 table fields (54 `can_*` verb guards, 20 `to_door`, ...), 10 `let`s, 8 call arguments |
| … of which `return nil` only | 16 | empty `exit` / `enter` hooks (side findings below) |
| `if … return a end`, then `return b` | 22 | property functions: `name`, `for_story`, `icon`, `photo_name`. Needs section 6 too |
| Anything else | 479 | |

- The call-argument case the draft starts from is rare: 8 of the 122 (3 `Array.filter`, 1 `Array.map`, 2 `Thread.wait_while`, 2 `door_trigger`). Most of the 72 functions passed as arguments are thread bodies (`Thread.start`, `Thread.with_input_off`, `Scene.start_thread`, `Cutscene.run`). They wait, so an expression can't replace them (below).
- The typical case is a verb guard in an object's table (`SheriffsOffice.zak:729`):

  ```
  can_open = function(self, noun2 = nil): return not self.open end,
  ```

- 51 of the 122 already fit on one line. The other 71 take three (`function(...):`, `return ...`, `end`) and would take one.
- Sections 6 and 9 add up. Section 6 found that most of a property function's length is the wrapper, not the `if`. With both, the 22 `if` / `return` property functions take one line too.

**Options considered:**

1. **Elm: `\(p) -> p <= 25`.** The shortest. But `\` is a symbol to learn, the objection section 6 made against `?`, and in code full of strings it reads like an escape. It only appears inside strings today, so the lexer has no clash.
2. **The keyword, then an arrow: `function(p) -> p <= 25`.** No new word, and it's visibly a function. 7 characters longer than option 1, but most of the saving comes from dropping `return`, `end` and the line breaks, which both do.
3. **A bare arrow: `(p) -> p <= 25`.** It looks like a parenthesized expression until the arrow, so the parser has to backtrack, and an error inside it is harder to report.
4. **`fn`, replacing `function` everywhere (section 10): `fn(p) -> p <= 25`.** Option 2 with the shorter keyword. Only one character longer than option 1, and still a word, not a symbol.

The typical case with each:

```
can_open = \(self, noun2 = nil) -> not self.open,
can_open = function(self, noun2 = nil) -> not self.open,
can_open = (self, noun2 = nil) -> not self.open,
can_open = fn(self, noun2 = nil) -> not self.open,
```

**Proposal: option 4, `fn(params) -> expr`.** Section 10's rename to `fn` is done (2026-11-11).

- It extends section 6's rule: **`:` opens a block, closed by `end`. The value forms, `then` and `->`, never use `:` and never need `end`.**
- No new concept to teach: a function's body is either a block or a single expression.
- The parser decides right after the parameter list's `)`: `:` starts a block, `->` an expression. No backtracking, no ambiguity.
- The arrow costs one new token, `->`, and no reserved word (`fn` is section 10's). Today `->` can only appear in a syntax error (`a -> b`), so no valid program changes meaning.
- With `fn`, option 1's one advantage, brevity, is down to a single character.

**How it would work:**

- The parser turns `fn(params) -> e` into `fn(params): return e end`. A parser-only change: closures, default parameters (all 54 verb guards use `noun2 = nil`), arity checks and error positions work as they do today.
- Parentheses are always required, even for one parameter, as in the block form. Parameter lists keep one grammar.
- The body is a full expression, so it extends as far as it can, like section 6's `else` branch. It ends at a `,`, `)` or `}` that isn't its own: `Array.filter(prices, fn(p) -> p <= 25)`. A function that returns a function needs no parentheses: `fn(a) -> fn(b) -> a + b`.
- Outside brackets, a newline ends it, as it ends any expression, so a long body keeps the block form.
- It can't wait. Its body is a `return`, and `return Thread.wait_for(1.0)` is already an error. So the rule is: this form computes a value, and anything that takes time keeps the block form. A waiting call here should get a message that says so, not the generic "a waiting call must be a statement on its own".
- Only an expression: an assignment isn't one, so `fn() -> count = count + 1` is a syntax error. So is `fn(p) -> return p`. Both get a targeted message.

**Docs.** `guide/language/Functions.md` gets the expression form. The `Thread.wait_while(fn(): return not door.open end)` examples in `guide/language/Threads.md` become `Thread.wait_while(fn() -> not door.open)`.

**Side findings, with no language change:**

- 16 of the single-return functions are empty, like `exit = function(self): return nil end` (13 `exit`, 2 `enter`, 1 `verb_look_at`). A scene's hooks are optional (elm-adventure's `Engine.Callback`), so the `exit` and `enter` ones can probably go. `verb_look_at` needs a look first: returning `nil` there may override a default.

**Prior art:**

- **Elm:** `\p -> p <= 25`, the first draft's form.
- **Python:** `lambda p: p <= 25`. A keyword, and a single expression only, like this proposal.
- **Java:** `(p) -> p <= 25`, option 3's form. JavaScript, Dart and C# write it with `=>`.
- **Lua:** `function(p) return p <= 25 end` is the only form, as in Zak today.


## ✅ 10. `fn` instead of `function` - DONE

**Done (2026-11-11),** as described below, in both repos. `Zak.Internal.Parser.functionLiteral` reads `fn`, and `function` stays a reserved word: `Parser.rejectFunctionKeyword` reports "“function” is now “fn”" on the word itself. The guide's stdlib signatures name an `fn` parameter `f`. The VS Code grammar highlights `fn` (0.2.1). The counts below are as of 2026-11-04; the design docs keep `function` where they show old code.

Replace the `function` keyword with `fn`, in both forms: the block, `fn(params): … end`, and section 9's expression, `fn(params) -> expr`.

```
let point = fn(x, y):
    return { x = x, y = y }
end

can_open = fn(self, noun2 = nil) -> not self.open,
Array.filter(prices, fn(p) -> p <= 25)
```

**Why:**

- 6 characters fewer on each of the 626 function literals in the game (as of 2026-11-04), most visibly on the verb guards in objects' tables.
- It's still a word you can say, not a symbol, as section 6 prefers. Zak's keywords are already short: `let`, `const`.
- It reads like the math notation `f(x)`.
- It makes section 9's expression form as short as Elm's `\`, with no symbol to learn.

**What stays.** The value is still a function: `type(f)` is `"function"`, `is_function` keeps its name, `String.from` shows `<function>`, and the guide calls it a function. Only the keyword changes.

**Costs:**

- `fn` becomes reserved. It's the natural name for a function parameter, and both repos use it as one: twice in the game (`start_routine = function(self, fn)`, `SheriffsOffice.zak:191`; `let fn = Table.get_default(noun1, verb)`, `SystemHelpers.zak:402`) and 17 times in the guide's stdlib signatures (`Array.map(array, fn)`, `Table.each(table, fn)`). They need another name, such as `f` or `callback`. Elm code that uses `fn` isn't affected.
- `function` explains itself to a newcomer. `fn` has to be learned, once.
- Zak code to convert, counted as `function(` (as of 2026-11-04):

  | Where | Count |
  |---|---|
  | elm-adventure scripts (`Delores/`, `Shared/`) | 626 |
  | elm-adventure tests (Zak in Elm strings) | 301 |
  | elm-adventure guide and design docs | 68 |
  | elm-adventure `src` | 3, 2 of them code the yack compiler generates (`Engine/Yack/Compiler.elm`) |
  | elm-zak tests | 227 |
  | elm-zak guide | 58 |
  | elm-zak design docs | 28 |
  | elm-zak `src` | 13, in doc comments and examples |

**How:**

- One spelling, no alias. Switch everything at once and convert the code with a script, as planned for `String.format` (section 3a).
- The script rewrites Zak code only: `.zak` and `.yack` files, the Zak snippets in the tests, and the code the yack compiler generates. Markdown and doc comments get a manual pass, since `function(...)` also appears in prose.
- In the interpreter, the keyword is in `Zak.Internal.Parser` (`L.keyword "function"`) and the reserved words in `Zak.Internal.Lexer`.
- `function` stays reserved for a while, with a targeted syntax error, "`function` is now `fn`", so an older script or a Dinky port gets a clear message, not a confusing parse error.
- The rename comes first, on its own, in both repos. Then section 9's arrow form, then section 6's conditional. Each step stays small, and the rename changes no behavior.

**Prior art:**

- **Rust, Zig, Gleam:** `fn` for every function.
- **Clojure:** `fn` for an anonymous function.
- **Elixir:** `fn p -> p <= 25 end`, an anonymous function with `fn` and `->`, closed by `end`.
- **Lua, JavaScript:** the full `function`, as Zak today.


## 11. `for` over tables

`for` only goes over arrays. A table's fields can only be visited with `Table.each`, a callback, so that loop can't wait, `break`, `continue`, or `return` from the enclosing function. Letting `for` go over a table, with both the field's name and its value, removes the need for `Table.each`. `Array.each` can go with it: `for` already does everything it does on arrays.

```
for key, value in object:
    Table.set(copy, key, value)
end
```

**Use cases in Delores** (as of 2026-11-10: `Delores/` and `Shared/` in elm-adventure):

| Where | Uses |
|---|---|
| `check_verbs` (`Shared/VerbHelpers.zak:36`) | the name and the value |
| `Table.merge` (`Shared/Helpers.zak:11`) | the name and the value |
| `define_scene` (`Shared/SystemHelpers.zak:36`) | the value only (`function(_, value)`) |

- Those are the only three `Table.each` calls. None uses the name alone.
- Nothing calls `Array.each`.
- One array loop needs an index: the shuffle's swap (`Delores/Note.zak:132`), which loops over `Array.range`.

**Options considered:**

1. **Two names in the `for`: `for key, value in table:`.** Needs no other feature. `for _, value in table` covers the value-only case, with the throwaway `_` (section 1).
2. **Unpacking (section 2): `for [key, value] in Table.pairs(table):`.** More general, but it needs section 2 and a `Table.pairs` that builds a `[key, value]` array for every field. Heavy for the common case.
3. **No new syntax: `for key in Table.keys(table):`,** then `Table.get(table, key)` in the body. `Table.keys` and `Table.values` are a stdlib idea already (`design/StdLib Improv.md`, item 5). It adds a lookup to every pass, and the name and the value are never side by side.

**Proposal: option 1.**

- **One name gives the field's name:** `for key in table`. That matches `in`, which already checks a table's field names (`"_is_actor" in value`).
- **Two names give the name and the value:** `for key, value in table`.
- **Order:** sorted by field name, as `Table.each` does today.
- **Changes during the loop:** the field names are read once, when the loop starts. A field removed partway through is skipped, and one added isn't visited. Each value is read when its turn comes, which is the closest to how an array is read afresh on every pass.
- **Everything a `for` allows works:** waiting, `break`, `continue`, and a `return` that leaves the enclosing function. That's the real gain over `Table.each`.
- **Anything else** than an array or a table is a `TypeError`, as today.
- **Not now: `for index, element in array`.** The same rule, "where, then what", but the evidence is one loop. Wait for a use.

**Unpacking is a separate thing.** Section 2's `for [story, line] in bad_story` unpacks each *element* of an array of pairs (StdLib Improv's "pairs read with `[0]` and `[1]`"). Two names without brackets go over a *table's fields*. The brackets keep the two apart, so `for a, b` never has to guess which one is meant.

**How it would work:**

- The parser: `For String Expr Block` gets an optional second name.
- The interpreter: `execFor` gets a table branch next to the array one. Its loop resumes after a wait through a closure that holds where it is, so the table branch keeps its list of field names the same way.
- The game: the three `Table.each` calls become `for` loops. `Table.merge` becomes `for key, value in other: Table.set(table, key, value) end`.
- Then `Array.each` and `Table.each` go, with their tests and guide entries. `guide/language/Threads.md` names both among the callbacks that can't wait.
- StdLib Improv's item 5, `Table.keys` and `Table.values`, goes too: its only two use cases are `Table.each` calls that this covers.

**Docs.** `guide/language/Statements.md`'s `for` section, and `guide/language/Tables.md`, which today sends a reader to `Table.each` to go through a table.

**Prior art:**

- **Lua:** `for k, v in pairs(t)`, through a function that walks the table.
- **Python:** `for k in d` gives the keys, `for k, v in d.items()` both.
- **Go:** `for k, v := range m`, and `for k := range m` for the keys alone.
- **Squirrel:** `foreach (k, v in t)`, and `foreach (v in t)` for the values alone.