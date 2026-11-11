# Future ideas

An idea is removed once implemented. The others keep their numbers, which other docs refer to.

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
* Using the throwaway `_`.
* In a `for` too: `for [story, line] in bad_story` unpacks each element of an array of pairs. Going over a table's fields, with no brackets, is section 11.

## 3. Expand String.format to use name look ups

Use a new name look up syntax to allow to pass a table as an argument.

```
String.format("I ate %{count}d apples and I feel %{status}s.", {count: 5, baz: false, status: "fine"})
```

Notes: 
* The `baz` field is ignored 
* The positions of the table fields are not significant while resolving the format string names
* Since `String.format` became variadic (2026-11-11), the values come after the format, so the table is the one value after it, and an `%{...}` placeholder reads its fields. Mixing `%{...}` and plain placeholders in one format needs a rule of its own.

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
4. **`fn`, replacing `function` everywhere (done on 2026-11-11): `fn(p) -> p <= 25`.** Option 2 with the shorter keyword. Only one character longer than option 1, and still a word, not a symbol.

The typical case with each:

```
can_open = \(self, noun2 = nil) -> not self.open,
can_open = function(self, noun2 = nil) -> not self.open,
can_open = (self, noun2 = nil) -> not self.open,
can_open = fn(self, noun2 = nil) -> not self.open,
```

**Proposal: option 4, `fn(params) -> expr`.** The rename to `fn` is done (2026-11-11).

- It extends section 6's rule: **`:` opens a block, closed by `end`. The value forms, `then` and `->`, never use `:` and never need `end`.**
- No new concept to teach: a function's body is either a block or a single expression.
- The parser decides right after the parameter list's `)`: `:` starts a block, `->` an expression. No backtracking, no ambiguity.
- The arrow costs one new token, `->`, and no reserved word (`fn` already is one). Today `->` can only appear in a syntax error (`a -> b`), so no valid program changes meaning.
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


## 11. `for` over tables

`for` only goes over arrays. A table's fields can only be visited with `Table.each`, a callback, so that loop can't wait, `break`, `continue`, or `return` from the enclosing function. Letting `for` go over a table, with both the field's name and its value, removes the need for `Table.each`. `Array.each` is already gone (2026-11-11): `for` did everything it did on arrays.

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
- Nothing called `Array.each`, before it was removed.
- One array loop needs an index: the shuffle's swap (`Delores/Note.zak:132`), which loops over `Array.range`.

**Options considered:**

1. **Two names in the `for`: `for key, value in table:`.** Needs no other feature. `for _, value in table` covers the value-only case, with the throwaway `_`.
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
- Then `Table.each` goes, with its tests and guide entries. `guide/language/Threads.md` names it among the callbacks that can't wait.
- StdLib Improv's item 5, `Table.keys` and `Table.values`, goes too: its only two use cases are `Table.each` calls that this covers.

**Docs.** `guide/language/Statements.md`'s `for` section, and `guide/language/Tables.md`, which today sends a reader to `Table.each` to go through a table.

**Prior art:**

- **Lua:** `for k, v in pairs(t)`, through a function that walks the table.
- **Python:** `for k in d` gives the keys, `for k, v in d.items()` both.
- **Go:** `for k, v := range m`, and `for k := range m` for the keys alone.
- **Squirrel:** `foreach (k, v in t)`, and `foreach (v in t)` for the values alone.

## 12. Variadic Zak functions

The natives already take any number of arguments: `Debug.log*(value, ...)`, `Debug.assert(condition, message, ...)`, `String.format(format, ...)`, and elm-adventure's `Actor.say_line(actor, line, ...)`. A function written in Zak can't: its parameters, defaults included, set a fixed maximum. This is the same idea, for Zak functions.

**No hurry (2026-11-11).** Nothing in elm-adventure needs it today. The only candidate is the `print` helper (`shared/Helpers.zak`), which forwards one message to `Debug.log` and has no callers; `error`, the other one, was replaced by direct asserts. The forwarding case that does exist, `Actor.say_line(Delores, headline_text.lines)` (`delores/Scenes/AStreet.zak:88`), is handled by the native accepting its lines as one array. Implement it when a helper or a wrapper needs it.

**Proposal: two halves, one `...`.**

1. **A rest parameter: `fn(format, ...values)`.**

    ```
    let log_scene = fn(scene, format, ...values):
        ...
    end
    ```

    - `values` is a new array of the extra arguments, `[]` when there are none, a fresh one on every call.
    - Last, and only one.
    - It can follow defaults, `fn(a, b = 1, ...rest)`: the arguments fill the named parameters first, in order, and `rest` gets what's left after all of them.
    - No default of its own: `...values = [1]` is a syntax error, since it's always an array anyway.
    - `..._` accepts extra arguments and drops them, from the throwaway rule.
    - The function needs at least its required parameters, and has no maximum.
    - It's the notation the guide already uses for the natives: `Debug.log(value, ...)` could read `Debug.log(value, ...values)`.

2. **Spreading an array into a call: `f(a, ...array)`.**

    Without it, the rest parameter is half a feature: a wrapper can collect its extra arguments, but not hand them on to a variadic native.

    ```
    let warn = fn(format, ...values):
        Debug.log_warning("[game] " ++ format, ...values)
    end
    ```

    - `...expr` must be an `Array`, or it's a `TypeError`. Its elements become separate arguments.
    - **The last argument only.** That covers forwarding, and mirrors the rest parameter. It can be loosened later if a use shows up.
    - It works the same for a Zak function and a native: the arguments are a flat list before the call.
    - Rejected: a native `Function.apply(f, array)`. No new syntax, but it reads poorly, and the `...` token is needed for the rest parameter anyway.

**Why both:** one symbol, one meaning, both ways: collecting the arguments in a parameter list, spreading them in a call. Structural unpacking (section 2) could take it too, later: `let [first, ...rest] = items`.

**How it would work:**

- The lexer: a new `...` symbol. It doesn't clash with `.` field access, since it's only read in a parameter list or an argument list.
- The AST: `FunctionLiteral (List ( String, Maybe Expr )) Block` gets an optional rest name, and so does the `Closure` it makes. A call argument can be marked as spread.
- `callFunctionCell`: with a rest name, no maximum arity, and the extra arguments go into a new array (`allocArrayCell`), bound like any other parameter.
- Evaluating a call's arguments: a spread one is replaced by the array's elements.
- `WrongArgCount` reads "expected 2 arguments, got 1", one count. For a function with defaults it already means "at least 2", and a rest parameter makes that more common. Worth a look while there: "expected at least 2 arguments" for a function that has no maximum.
- The guide: `guide/language/Functions.md` gets a section after "Default parameter values", on taking any number of arguments and on spreading. The stdlib signatures could switch from `...` to `...values`.

**Open: the natives that accept a lone array.** Once spreading exists, `Actor.say_line(actor, lines)` could be `Actor.say_line(actor, ...lines)`, and the array form could go: one rule instead of a special case. Probably, but to think about when this is implemented. It's a change to the game, not to Zak.

**Prior art:**

- **JavaScript:** `function f(a, ...rest)` and `f(...array)`, the same token both ways.
- **Python:** `def f(a, *args)` and `f(*items)`.
- **Lua:** `function f(a, ...)`, the extra arguments read through `...` itself, or `{...}` for a table of them.
- **Squirrel:** `function f(a, ...)`, the extra arguments in the implicit `vargv` array.
