# Zak public API

A proposal to cut elm-zak's public API down to a minimum before it's published as a package. Once the decisions below are settled, the result gets documented in the package itself.

**Status:** a proposal. Nothing is implemented. Every decision below is settled; only the names of the data functions are deferred (see "Deferred"). "Order of work" lists the steps.

**Evidence:** the three exposed modules in `../elm-zak/src/Zak/`, and every use of them in the real embedders: the game (`src/`, 27 files), its tests (`tests/`), and the Try Zak playground (`../elm-zak/try/src/Main.elm`). Counts are from 2026-09-29, except the `Value` counts, which are from 2026-10-05.

## The problem

### Three modules, 35 names, no obvious entry point

| Module | Exports |
|---|---|
| `Zak.Interpreter` (11) | `run`, `runExpr`, `initialWorld`, `runIncremental`, `importSource`, `call`, `tick`, `drainLogs`, `drainEffects`, `allocCell`, `Error(..)` |
| `Zak.Runtime` (20) | `Value(..)`, `State`, `Env(..)`, `NativeValue(..)`, `RuntimeError(..)`, `Heap`, `ArrayHeap`, `Signal(..)`, `Outcome(..)`, `WaitCondition(..)`, `Thread(..)`, `ThreadId`, `LogLevel(..)`, `LogEntry`, `Effect`, `bindGlobal`, `dropPosition`, `mapOutcome`, `mapOutcomeResult`, `requireDone` |
| `Zak.Helpers` (4) | `formatError`, `describeRuntimeError`, `describeRuntimeErrorAt`, `toConsoleEntry` |

Doing anything needs all three: `Interpreter` for the functions, `Runtime` for the types, `Helpers` to show an error.

### `State` is a plain record, and embedders reach into it

The game does this in 25 places across 6 files (`Main`, `Engine.Actor`, `Engine.Load`, `Engine.Natives`, `Engine.Boot`, `Engine.Scene`). The playground does it in 4.

| Field | Used for |
|---|---|
| `heap`, `arrayHeap` | reading a table's fields or an array's items (`Engine.Load.readField`/`readArray`); stamping fields on a table (`Engine.Actor.stampActor`, `Engine.Natives.createActor`); building new tables (`Engine.Actor.buildPointTable`, `Engine.Boot.seedRoomData`); printing values in the playground |
| `globalFrameId` | reading a global (`Engine.Actor.callGlobal`/`queryGlobal`, `Engine.Natives.nextCharacterId`), writing one (`Engine.Actor.bindReservedGlobal`) |
| `pendingEffects` | a native queuing an effect for the host (`Engine.Load.pushEffect`) |
| `pendingLogs` | the host adding a log line (`Main.logError`) |
| `threads`, `nextThreadId` | stopping a room's local threads (`Engine.Scene.stopLocalThreads`, the thread mark in `enter_from`); counting running threads (playground) |
| `randomSeed` | reseeding at boot (`Main.reseedZakState`) |

After publishing, any internal change to `State` would break every user.

### Other problems

- **`Env` and `State` are two halves of one world.** Every entry point takes both, and `Env`'s frame id is the same number as `state.globalFrameId`. The game only opens `Env` once, in `Engine.Boot.attachAll`, to read the global frame.
- **Internals are exported that no embedder uses:** `Signal`, `Outcome`, `WaitCondition`, `Heap`, `ArrayHeap`, `mapOutcome`, `mapOutcomeResult`, `requireDone`. `allocCell` is used only to build tables by hand; `dropPosition` only by tests.
- **`Value` exposes implementation details:**
  - `VTable Int` and `VArray Int` are raw heap ids;
  - `VFunction` carries the AST and an `Env`;
  - there are three function constructors (`VFunction`, `VNative`, `VNativeThread`), where an embedder only ever wants to call one.

## What embedders need

Taken from the real uses above:

1. **Setting up and running:** create a world with host natives, run source into it, include a file from inside a native (the host's own `include`), call a function or a global by name, tick threads, reseed randomness.
2. **Moving data between host and script:**
   - reading a table's field, all of its fields, an array's items, or a global;
   - creating a table, setting a field, setting a global.
3. **Channels out of the interpreter:** natives emit effects for the host to collect, and logs go out the same way. The queue has to live in the world, since a native only receives the world.
4. **Threads:** count them, and stop the local ones started before a given point (a room change).
5. **Errors:** show one, with or without the source text; let a native raise one (a type error, a wrong argument count).
6. **Writing natives:** a function, a table of natives, Zak source, a constant.

## Decisions

| # | Topic | Decision |
|---|---|---|
| 1 | `World` | **Settled:** one opaque type named `World`, merging `Env` and `State`. The name is already used internally (`initialWorld`), and a clash with a host's own `World` type is avoided by writing `Zak.World`. |
| 2 | Modules | **Settled:** one public module, `Zak`, covering both embedding and writing natives. The internals keep their own copies of the shared types, and `Zak` converts at the boundary (see "Module layout"). This replaces an earlier `Zak` / `Zak.Native` split, which Elm would have forced into three modules. |
| 3 | `Value` | **Settled:** not opaque. Plain constructors, with only the references opaque (see "Why `Value` isn't opaque"). |
| 4 | Errors | **Settled:** `RuntimeError(..)` stays public, constructors included. Since its names become public API, two are renamed: `Import*` becomes `Include*` (with `include`), and `AtPosition` becomes `WithPosition`, the wrapper that pairs another error with the position where it happened. |
| 5 | Threads | **Settled:** `threadCount`, and `stopLocalThreads`, which stops local threads immediately, with no mark (see "Threads"). |
| 6 | Argument order | **Settled:** the world goes last everywhere, natives included. Checked against real code in "World last, checked against real code". |
| 7 | Names | **Settled:** `runIncremental` becomes `run`. The one-shot `run` becomes `runOnce` and, like `runExpr`, is no longer public: only elm-zak's own tests use them. `NativeZakExpr` becomes `nativeExpression`, and the native constructors share a `native` prefix. |
| – | Logs | **Settled:** logs are effects (below). |
| – | Randomness | **Settled:** `Zak.reseed`. |
| – | Calling | **Settled:** `call` only, with no `callGlobal`. |
| – | Including | **Settled:** `Zak.include`, not `import_`. The game renames its script-level `import` native to match. |
| – | Broken natives | **Settled for now:** `init` keeps its signature, and logs a `Log LogError` for each `nativeExpression` that fails to parse or evaluate (see "Writing natives"). |
| – | Console mapping | **Settled:** dropped. Hosts map `LogLevel` to `console` methods themselves. |
| – | Internal modules | **Settled:** every current module moves under `Zak.Internal.*`, and the standard library under `Zak.Internal.Library.*` (see "Module layout"). |

## Proposal

Everything below is in the one public module, `Zak`. Its documentation groups the functions into sections: running, data, effects, errors, writing natives.

### Embedding

```elm
type World -- opaque

-- running
init    : List ( String, Native ) -> World
run     : String -> World -> Result Error ( Value, World )
include : String -> String -> World -> Result RuntimeError ( Value, World )
call    : Value -> List Value -> World -> Result Error ( Value, World )
tick    : Float -> World -> ( List RuntimeError, World )
reseed  : Int -> World -> World

-- data
getGlobal : String -> World -> Maybe Value
setGlobal : String -> Value -> World -> World
newTable  : List ( String, Value ) -> World -> ( Value, World )
getField  : String -> Value -> World -> Maybe Value
setField  : String -> Value -> Value -> World -> World
fields    : Value -> World -> Maybe (Dict String Value)
items     : Value -> World -> Maybe (List Value)

-- threads (see "Threads")
threadCount      : World -> Int
stopLocalThreads : World -> World

-- effects (see "Logs are effects")
emitEffect  : String -> List Value -> World -> World
takeEffects : World -> ( List Effect, World )

-- errors
errorToString : String -> Error -> String
```

- `run` runs source into an existing world: the host loads several files one after another, and each sees what the earlier ones defined. There's no public one-shot version. The game's tests call the one-shot `run` only 4 times (`Test.Engine.Natives`, `Test.Engine.Actor`), and can write `Zak.init natives |> Zak.run source` instead.
- **`include`, not `import_`.** It works like a C include: it runs the file's source into the same global scope, with no module object and no aliasing. Like today's `importSource`, it skips a path that was already included, which also guards against cycles. So it's really an "include once". The two `ImportNotFound`/`ImportParseError` constructors become `IncludeNotFound`/`IncludeParseError`, since `RuntimeError(..)` is now public.
- **`include` versus `run`.** Both run source into a world. `include` is for natives: it remembers paths, and fails with a `RuntimeError`, like any other native. `run` is for the host: it fails with an `Error`, which can also be a syntax error.
- **`include` takes two `String`s in a row** (path, then source). They're easy to swap by mistake, but it has one caller in the game. A record isn't worth it yet.
- **`call` is the only way to call a function.** The host gets the function first, with `getGlobal` or `getField`, then calls it. A `callGlobal` shortcut would favor one of the two places functions come from: the game calls globals (`Engine.Actor.callGlobal`/`queryGlobal`) and table fields (`Engine.Scene.zakHook`'s `enter`/`exit`, verbs through `callVerb`). A missing function is a `Maybe` the host handles, which the game already does, with its own message.
- **`emitEffect` queues `Effect name args`** for the host, which takes it back with `takeEffects`. The two names pair up, and the name says what's emitted. It replaces the game's `Engine.Load.pushEffect`. A `Table` or `Array` argument is queued as a reference, not a copy: the host sees its contents as they are when it handles the effect, not as they were when it was emitted.
- **No console mapping.** Today's `Zak.Helpers.toConsoleEntry` maps a `LogLevel` to a browser `console` method name (`LogWarning` to `"warn"`, and so on). It's dropped: it would tie a package that makes no assumptions about its host to a browser API, and a host that needs it can write the five-case `case` on `LogLevel(..)` itself.
- `reseed` takes an `Int` (the game passes milliseconds) rather than a `Random.Seed`, so `elm/random` stays out of the public signatures.
- Every function that gives back a world gives it back second: `( Value, World )`, `( List Effect, World )`, and now `( List RuntimeError, World )` from `tick`. Today `tick` returns the other way round.

### Writing natives

```elm
type Native -- opaque

nativeFunction   : (List Value -> World -> Result RuntimeError ( Value, World )) -> Native
nativeTable      : List ( String, Native ) -> Native
nativeExpression : String -> Native
nativeConstant   : Value -> Native
```

- **A `native` prefix on the four constructors.** In a separate `Zak.Native` module they would have been `function`, `table`, `expression` and `constant`. Inside `Zak`, a bare `table` would read like `newTable`, which builds a table *value*. The prefix keeps the two apart.
- **`nativeExpression` is a native written in Zak:** one Zak expression, usually a function literal, evaluated once when the world is created. It's parsed as an expression (`Parser.parseExpr`), not a program, so `"let x = 1"` or several statements don't work. The name says so; `NativeZakExpr` did too, but "Zak" is redundant inside `Zak`. The game uses it 11 times (9 in `Engine.Actor`, plus `Engine.Natives` and `Engine.Scene`), and elm-zak's `Math.abs` is one.
- **A broken `nativeExpression` is logged, not silently dropped.** Today, an expression that fails to parse or evaluate leaves its native undefined, and a script calling it gets an `UndefinedName` with no hint about the cause. Instead, `init` queues a `Log LogError` naming the native's full path (`Actor.state`) and the error, with the line and `^` that `errorToString` produces. The host sees it on its first `takeEffects`. The native itself still stays undefined.
  - This is the cheapest fix: `init`'s signature doesn't change, and the interpreter already reports its "shadows a const" warning the same way. But nothing stops the host from booting, and tests still pass.
  - The stricter alternative was `init : List ( String, Native ) -> Result (List BrokenNative) World`, listing every broken native with its source and error. Switching to it later changes `init`'s signature, so it would be a major release.
- **`nativeTable`, not a "namespace".** A group of natives becomes an ordinary table at runtime (`Interpreter.resolveNative` allocates a `VTable`), and the language guide never calls `Math`, `Array` and the rest namespaces.
- **Natives raise `RuntimeError` constructors directly**, now that they're public. That replaces the planned `typeError` and `wrongArgCount` helpers.
- **No thread natives yet.** `NativeThreadFunction` has no users outside elm-zak. Adding a function to `Zak` later is a minor release.

### `Value`

Plain constructors, with opaque references and one function type:

```elm
type Value
    = Nil
    | Bool Bool
    | Number Float
    | String String
    | Array ArrayRef
    | Table TableRef
    | Function FunctionRef
```

`TableRef`, `ArrayRef` and `FunctionRef` are defined in `Zak` without exposing their constructors, so hosts can't make them up. `FunctionRef` wraps the interpreter's own function value, closures and natives alike (see "Module layout").

### Logs are effects

Today there are two queues, `pendingLogs` and `pendingEffects`, drained separately (`drainLogs`, `drainEffects`). They're the same mechanism: plain data a native queues in the world, which the host takes out later and turns into whatever it wants, usually a `Cmd`. The interpreter never acts on either. What differs is who defines the item:

- a **log** is defined by the language: Zak's own `Debug.log*` natives, and the interpreter itself (the "shadows a const" warning). Its shape is fixed: a level and a message;
- any other effect is defined by the **host**: a name it chooses (`say_line`, `enter_scene`) and its arguments, which elm-zak never looks inside.

So one queue, with one variant for each:

```elm
type Effect
    = Log LogLevel String
    | Effect String (List Value)

takeEffects : World -> ( List Effect, World )
```

- **Not encoded as `Effect "log" [ level, message ]`**, which would reserve a magic name, return the level and message untyped, and drop logs silently in a host that forgets `"log"`.
- **Order is kept** across logs and effects. Today "log, effect, log" comes back as two lists, and the order between them is lost.
- **The host routes each variant.** The game sends `Effect` to `Engine.Load.toWorldChange` and `Log` to its `logToConsole` port; the playground shows logs in its own panel; tests inspect them.
- **The host stops writing into the queue.** `Main.logError` pushes the game's own engine errors into `pendingLogs` today, to keep one ordered stream; those would live in the game's model instead.
- **Thread errors stay separate.** `tick` returns the errors of failed threads: they're results, not something a script asked for.

Everything else (`Signal`, `Outcome`, the thread machinery, the heap) becomes internal. The package's own tests can still import the internal modules (see "Module layout").

### Threads

Scripts start threads with `Thread.start` (local) or `Thread.start_global`, and `tick` advances them. The host needs two more things, both taken from the 3 places where the game and the playground read thread fields directly today.

```elm
threadCount      : World -> Int
stopLocalThreads : World -> World
```

- **`threadCount`** tells a host whether there's anything to advance, so it can stop calling `tick` on every frame while nothing is running. The playground uses it to subscribe to animation frames only while threads are running (`Dict.isEmpty state.threads` today), and to show "N threads still running" (`Dict.size`).
- **`stopLocalThreads`** stops every thread started with `Thread.start`, and keeps those started with `Thread.start_global`. The game calls it on a room change, as TWP's `exitRoom` does ("stop all local threads"). It's the first policy elm-zak attaches to the local/global distinction: until now, `isGlobal` was recorded on each thread but never acted on.
- **It stops threads immediately, with no mark.** `Scene.enter_from` calls it directly, while the native is running. Threads started afterwards are kept automatically, such as the autoclose thread in `exit_scene_from_door`. This matches DeloresDev's synchronous `enterRoom`: "the old room's local threads stop before the script's next line".
  - **It replaces a mark.** Today `enter_from` puts `state.nextThreadId` into the `enter_scene` effect, and `Main` later drops the local threads whose id is below it (`Scene.stopLocalThreads`). That approach would have made thread ids, and the fact that they only grow, part of the public API. It also let the old room's threads run once more within the same `tick`, between the request and the effect being applied.
  - **One difference from today:** the old room's local threads are gone by the time its exit hook runs. In TWP, and in the game today, the exit hook runs first. This matters only if an exit hook interacts with those threads, for example with `join`.
  - **The thread that calls it isn't affected,** even if it's local. That's the language's existing rule for `Thread.stop`: only a suspended thread can be stopped, and a thread ends itself by returning (guide, "Threads"). Today's mark approach differs here: the calling thread would be dropped at its next wait. No script relies on that. `exit_scene_from_door` runs from verb bodies, which aren't threads, and `Boot.zak`'s thread ends right after `enter_from`. The transition commented out in `Boot.zak` (blinds down, wait, `enter_from`, blinds up) needs the calling thread to survive.
- **Thread ids stay hidden.** Scripts still get a thread's id as a `Number` from `Thread.start`, for `Thread.stop` and `join`, but the host never handles one.
- **No other thread control for now.** The real code gives no reason to stop *all* threads, list them, or report which thread failed in `tick`'s errors. The playground just throws the world away when it resets.

### World last, checked against real code

Decision 6 was settled after checking that the signatures still read well with the world last. Here is `Engine.Natives.createActor` today:

```elm
createActor : State -> List Value -> Result RuntimeError ( Value, State )
createActor state args =
    case args of
        [ VString name, (VTable cell) as table ] ->
            let
                id =
                    nextCharacterId state

                fields =
                    Dict.get cell state.heap |> Maybe.withDefault Dict.empty

                stamped =
                    fields
                        |> Dict.insert "_id" (Load.idValue id)
                        |> Dict.insert "_key" (VString name)

                state1 =
                    { state | heap = Dict.insert cell stamped state.heap }
                        |> Runtime.bindGlobal nextCharacterIdName (Load.idValue (id + 1))
            in
            Ok
                ( table
                , Load.pushEffect "create_actor" [ Load.idValue id, VString name, table ] (Runtime.bindGlobal name table state1)
                )
        ...
```

And with the proposal:

```elm
createActor : List Value -> World -> Result RuntimeError ( Value, World )
createActor args world =
    case args of
        [ String name, (Table _) as table ] ->
            let
                id =
                    nextCharacterId world
            in
            Ok
                ( table
                , world
                    |> Zak.setField "_id" (Load.idValue id) table
                    |> Zak.setField "_key" (String name) table
                    |> Zak.setGlobal nextCharacterIdName (Load.idValue (id + 1))
                    |> Zak.setGlobal name table
                    |> Zak.emitEffect "create_actor" [ Load.idValue id, String name, table ]
                )
        ...
```

- **Updates chain with `|>`**, which is the main gain. `Random.step : Generator a -> Seed -> ( a, Seed )` in `elm/random` uses the same order.
- **`setField key value table world` mirrors `Dict.insert key value dict`**, with the world added at the end.
- **Chaining two calls that return a `Result`** still means unpacking the tuple (`Result.andThen (\( _, w ) -> ...)`). Putting the world first wouldn't change that.

## Module layout

Today all 12 modules live side by side in `src/Zak/`, and 3 of them are exposed. Nothing in a module's name says whether a host may use it.

**The proposal:** one public module, `Zak`, sits on top. Every current module becomes internal and moves under `Zak/Internal/`. The folder marks the boundary: anything under `Zak.Internal` is never listed in `exposed-modules`, and hosts never see it. `Zak` holds no interpreter logic of its own. It defines the public types, converts at the boundary, and calls into the internals.

### Internal modules

| Today | Becomes | Responsibility |
|---|---|---|
| `Zak.Lexer` | `Zak.Internal.Lexer` | Source text to lexemes |
| `Zak.Parser` | `Zak.Internal.Parser` | Lexemes to AST |
| `Zak.AST` | `Zak.Internal.AST` | The syntax tree |
| `Zak.Runtime` | `Zak.Internal.Runtime` | The runtime model: the internal `Value` and `RuntimeError`, `State`, `NativeValue`, the heaps, the effect queue, the thread types, `Signal`/`Outcome` |
| `Zak.Interpreter` | `Zak.Internal.Interpreter` | Evaluation, calls, the thread scheduler (`tick`), `include`, the `Array`/`Table` built-ins and `Thread.start`. It keeps `runOnce` and `runExpr` for elm-zak's own tests |
| `Zak.Debug`, `Zak.Globals`, `Zak.Math`, `Zak.Random`, `Zak.String`, `Zak.Thread` | `Zak.Internal.Library.*` | The standard library: one module per built-in table (plus `Globals` for `type`) |
| `Zak.Helpers` | `Zak.Internal.ErrorMessage` | Error text, behind `Zak.errorToString`. The console mapping (`toConsoleEntry`) is dropped |

### Who imports whom

Each module imports only modules from the rows above it:

1. `Zak.Internal.AST`, `Zak.Internal.Lexer`, `Zak.Internal.Parser`
2. `Zak.Internal.Runtime`
3. `Zak.Internal.Library.*`
4. `Zak.Internal.Interpreter`
5. `Zak.Internal.ErrorMessage`
6. **`Zak`**

### The shared types exist twice

Elm can't re-export a type's constructors: `type alias Value = Internal.Value` in `Zak` would hide `Nil`, `Number` and the rest. So a type whose constructors are public has to be **defined** in a public module. Only `Zak` is public, and it sits at the top, above the interpreter. So the internals can't use the public types; they keep their own.

| Public, in `Zak` | Internal twin | Direction |
|---|---|---|
| `Value` (`Nil`, `Number`, `Table TableRef`, …) | `Value` in `Runtime` (`VNil`, `VNumber`, `VTable Int`, `VFunction`, `VNative`, …) | both ways |
| `RuntimeError` (22 constructors) | `RuntimeError` in `Runtime` | both ways: natives raise it, the interpreter returns it |
| `Error`, `Effect`, `LogLevel` | their counterparts in `Interpreter` and `Runtime` | outward only |

- **`Zak` converts at the boundary,** with private functions. Arguments going into a native and a value coming back out, `call`, the data functions, `takeEffects` and errors. The conversion is shallow, because tables and arrays are references, so it costs next to nothing at runtime.
- **The conversions have to stay private,** which is why there's one public module. Split into `Zak` and `Zak.Native`, both would need the conversions, and Elm has no package-private visibility: one module would have had to expose them to users. Keeping the public types in their own module instead would have needed a third public module, there only because of Elm.
- **Adding an error kind means touching both copies.** The conversions are exhaustive `case` expressions, so forgetting one is a compile error, not a silent bug.
- **Internal names stay as they are** (`VString`, `VTable`…), so the two copies of `Value` never look alike in the source. The internal `RuntimeError` gets the same renames as the public one (`Include*`, `WithPosition`).
- **Functions stay where they are.** `FunctionRef` privately wraps the internal function value (`VFunction`, `VNative`, `VNativeThread`), closures included. Nothing needs to move into a function store.
- **`==` on a `Value` holding a function still crashes**, as it does today, because Elm can't compare functions. That isn't a regression.
- **`World` wraps `State` (`type World = World State`)** instead of aliasing it. `State` is a record, and an alias of a record would expose its fields again. `Native` wraps `NativeValue` the same way.
- **`RuntimeError` carries two more types:** `WithPosition` carries a position, and `IncludeParseError` a parse error. `Zak` exposes them as aliases: `type alias Position = { row : Int, col : Int }` and `type alias ParseError = List Parser.DeadEnd`.
- **The standard library doesn't use the public API for natives.** It sits below the interpreter, which installs it, and `Thread`'s natives suspend, which the public API doesn't offer. So it keeps building `NativeValue`s directly.

elm-zak's tests (`tests/Test/Zak/*.elm`) keep testing the internals directly. Only their imports change.

## Why `Value` isn't opaque

Decision 3 keeps plain constructors. The alternative was considered: with an opaque `Value`, hosts would build values with functions (`Zak.number 3`) and read them back with accessors (`Zak.toString : Value -> Maybe String`).

**Against:**

- **Natives lose pattern matching.** That's how they check their arguments today: 23 argument-list patterns (`[ VString name, VTable cell ] ->`) and 16 `case` branches on `Value` in the game's `src/`. Without constructors these become chains of `Maybe`s, or a decoder-style helper (`args2 string table`), which is a second API to design and document.
- **Pattern matching lets the compiler check every case.** With accessors, a missing case doesn't show up until runtime.
- **Tests get wordier.** The game's tests use the constructors about 340 times (`VNumber` 146, `VString` 106, `VNil` 42, `VBool` 31, `VTable` 15). `Ok (Number 3)` becomes `Ok (Zak.number 3)`. `==` still works.
- **The API gets bigger:** roughly 4 constructors, 6 accessors and a `typeName`, instead of zero.

**For:**

- **New value kinds without a major release.** In Elm, adding a constructor to a public type is a breaking change. With an opaque `Value`, a new kind of value (integers, host data) is only a minor release. But a new kind of value changes the language itself, which probably calls for a major release anyway.

**Decision:** plain constructors with opaque references. The references already hide what changes (heap layout, ids, closures). The constructors only fix the set of value kinds, and that set is part of the language.

## Deferred

- **The names of the data functions.** `getField` reads one field, but `fields` (not `getFields`) reads them all, and `items` is its array counterpart. The names don't line up, but they're good enough for v1.

## Migration cost, once decided

- **elm-zak itself:**
  - the current modules move under `Zak/Internal/`, and `Zak.Helpers` becomes `Zak.Internal.ErrorMessage`, without `toConsoleEntry`;
  - `Zak` is written on top of the internals: the public types, the private conversions, and the functions above;
  - `threadCount` and `stopLocalThreads`;
  - `pendingLogs` and `pendingEffects` merge into one queue;
  - `Interpreter.resolveNative` logs a broken `nativeExpression` instead of dropping it silently;
  - `ImportNotFound`/`ImportParseError` are renamed to `IncludeNotFound`/`IncludeParseError`, and `AtPosition` to `WithPosition` (in `Runtime`, `Interpreter`, `Helpers` and 5 test modules);
  - `exposed-modules` in `elm.json` lists only `Zak`.
- **The game:**
  - the 25 direct `State` accesses listed above;
  - taking one effect queue and splitting it by variant, instead of `drainLogs` and `drainEffects`; `Main.logError` keeping its messages in the model;
  - the 28 natives, which move to arguments first and world last;
  - `Scene.enter_from` calls `Zak.stopLocalThreads` and drops the thread mark from the `enter_scene` effect; `Main`'s `ChangeRoom` handler no longer stops threads, and `Scene.stopLocalThreads` goes away;
  - the `import` native (`Engine.Boot.importNative`) renamed to `include`, along with its 13 calls in the game's one `.zak` file that uses it;
  - renaming the constructors (`VNumber` to `Number`, and so on) in `src/` and the tests;
  - its own `LogLevel` to `console` method mapping in `Main`, replacing `Zak.Helpers.toConsoleEntry`;
  - `AtPosition` renamed to `WithPosition` (`Main`, and one test in `Test.Engine.Scene`);
  - `runIncremental` calls renamed to `run`; the tests' 4 one-shot `run` calls become `init` followed by `run`;
  - imports in 4 source modules and 9 test modules, all now importing `Zak` alone.
- **The playground:** one file, including its own `LogLevel` to `console` method mapping, and `threadCount` in place of `state.threads`.
- **elm-zak's own tests:** unaffected in substance, since they can keep using internal modules.

## Order of work

Each step leaves elm-zak's tests, and the game, passing.

1. **Internal changes, still under today's module names:**
   - the single effect queue;
   - the `Include*` and `WithPosition` renames;
   - logging broken `nativeExpression`s;
   - `threadCount` and `stopLocalThreads`.

   The game follows along with small edits, since it still uses today's API.
2. **The new layout:**
   - move the modules under `Zak/Internal/`;
   - write `Zak`, with the public types, the private conversions and the functions above;
   - list only `Zak` in `exposed-modules`.
3. **The playground,** first: one file, and it exercises most of the embedding API.
4. **The game:** the larger migration listed above, including `enter_from` moving to `stopLocalThreads`.
