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


# 6. Ternary operator or if/else variant

We currently don't have a way to return a value from a `if/else` construct. We have various options (quoting from memory):

* Classic C-style op: pred `?` when-true `:` when-false
* Python: when-true `if` pred `else` when-false
* Elm: `if` pred `then` when-true `else` when-false
 
Python's version is stronger for Zak because we don't introduce new keywords and reads well. Elm version is clearer


## 7. Private `_` names in included files

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

**How `include` works today.** It runs the file's statements directly in the shared world frame (`state.globalFrameId`), so every top-level `let` of every included file lands in the same frame and is visible everywhere.

**How privacy would work.** Running each file in its own frame and then copying the public names into the world frame doesn't work: it leaves two copies of every public variable, and the file's own functions would update their copy while other files read the other one. Instead, decide where each binding goes when the `let` runs:

- Each included file runs in its own frame, whose parent is the world frame.
- A top-level `let` / `const` whose name starts with `_` binds in the file frame. Any other name binds directly in the world frame, so there's only one copy.
- Functions defined in the file capture the file frame, so lookups go file frame → world frame: they see both their private names and all globals. Other files only see the world frame.
- The error should say why: "private to Helpers.zak", not just "undefined".

That's one new frame per include, a check in `let` / `const`, and the error message. The interpreter change is small and contained.

**The real cost: `_` already means "engine-facing".** This is inherited from Dinky, where `_enterRoom`, `_clickedAt` and similar are system callbacks. In elm-adventure (as of 2026-10-15), 42 top-level names start with `_`, and many are deliberately shared:

- The engine looks them up by name from Elm: `_inventory_view`, `_verbs_for`, `_create_hover_name`, `_drag_sentence`, the `_on_*` callbacks (`_on_object_clicked`, `_on_verb_chosen`, `_on_enter_scene`, `_on_trigger`, `_on_actor_arrived`, `_on_item_dropped`, `_on_animation_trigger`), and the reserved `_current_scene` / `_current_actor`. The host reads the world frame, so all of these would disappear.
- Other files use them: `_base_door` (in 4 files), `_check_verbs`, `_call_verb`, `_default_verb`, `_face_toward`, `_base_actor`.

So the game would need to rename every engine hook and shared-internal name (e.g. `_on_object_clicked` → `on_object_clicked`) before privacy is turned on, along with the Elm code that refers to them. Table fields like `_id`, `_key` and `_state` aren't affected: this only applies to top-level names.

**Prior art:**

- **Dart:** an `_name` is private to its library, enforced by the language. The closest match to this idea.
- **Python:** `from m import *` skips `_name`s, but `m._name` still reaches them. Only a convention.
- **Go:** an initial capital letter means exported, lowercase means unexported. A naming rule, like this idea.
- **Lua:** a top-level `local` is private to its file, and globals are shared. A keyword, not a naming rule.

**Open question:** should `_` mean "private" (Dart-style)? If so, the game's naming has to be cleaned up first, and engine hooks need a different marker (e.g. `on_*` with no underscore). If `_` stays for engine hooks, a Lua-style keyword avoids the clash, but adds new syntax.


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

