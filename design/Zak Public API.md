# Zak public API

A proposal to cut elm-zak's public API down to a minimum before it's published as a package. Once the decisions below are settled, the result gets documented in the package itself.

**Status:** a proposal. Nothing is implemented. One point is agreed (logs are effects, below); the next step is decision 1.

**Evidence:** the three exposed modules in `../elm-zak/src/Zak/`, and every use of them in the real embedders: the game (`src/`, 27 files), its tests (`tests/`), and the Try Zak playground (`../elm-zak/try/src/Main.elm`). All counts below are from 2026-09-29.

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

1. **Setting up and running:** create a world with host natives, run source into it, import a file from inside a native (the host's own `import`), call a function or a global by name, tick threads, reseed randomness.
2. **Moving data between host and script:**
   - reading a table's field, all of its fields, an array's items, or a global;
   - creating a table, setting a field, setting a global.
3. **Channels out of the interpreter:** natives emit effects for the host to collect, and logs go out the same way. The queue has to live in the world, since a native only receives the world.
4. **Threads:** count them, and stop the local ones started before a given point (a room change).
5. **Errors:** show one, with or without the source text; let a native raise one (a type error, a wrong argument count).
6. **Writing natives:** a function, a namespace, Zak source, a constant.

## Proposal: two modules

### `Zak`: embedding

It centres on an opaque `World`, which replaces both `Env` and `State`:

```elm
init       : List ( String, Native ) -> World
run        : String -> World -> Result Error ( Value, World )
call       : Value -> List Value -> World -> Result Error ( Value, World )
callGlobal : String -> List Value -> World -> Result Error ( Value, World )
tick       : Float -> World -> ( World, List Error )

-- data
getGlobal : String -> World -> Maybe Value
setGlobal : String -> Value -> World -> World
newTable  : List ( String, Value ) -> World -> ( Value, World )
getField  : String -> Value -> World -> Maybe Value
setField  : String -> Value -> Value -> World -> World
fields    : Value -> World -> Maybe (Dict String Value)
items     : Value -> World -> Maybe (List Value)

-- effects (see "Logs are effects")
takeEffects : World -> ( List Effect, World )

errorToString : String -> Error -> String
```

### `Zak.Native`: writing natives

```elm
function  : (List Value -> World -> Result Error ( Value, World )) -> Native
namespace : List ( String, Native ) -> Native
source    : String -> Native
constant  : Value -> Native
emit      : String -> List Value -> World -> World
import_   : String -> String -> World -> Result Error ( Value, World )
typeError, wrongArgCount, ...
```

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
    | Function Function
```

### Logs are effects (agreed)

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

Everything else (`Signal`, `Outcome`, the thread machinery, the heap) becomes internal. The package's own tests can still import the internal modules; only `exposed-modules` in `elm.json` changes.

## Decisions to settle

1. **An opaque `World`, merging `Env` and `State`.** This is the one that makes the rest possible. It's also the most expensive for the game: its 25 direct accesses become accessor calls. Decide this first.
2. **Two modules (`Zak` and `Zak.Native`), or one.**
3. **`Value`:** transparent constructors with opaque references (as above), or fully opaque with accessors.
4. **Errors:** an opaque `Error` with `errorToString`, or keep the `RuntimeError(..)` constructors public.
   - Natives raise them today.
   - The game's tests match on them 80 times.
5. **Threads:** which thread control belongs in the public API.
   - A count (the playground).
   - "Stop the local threads started before this mark" (the game's room change, with the mark taken in `Scene.enter_from`).
6. **The native signature:** keep `State -> List Value -> …`, or move to arguments first and world last, the usual Elm order. That's a mechanical change to the game's 28 natives either way.
7. **Naming:**
   - `run`, `runIncremental` and `runExpr` versus a single `run`. The one-shot `run` is used heavily by the game's tests, and `runExpr` only by elm-zak's own tests.
   - `NativeZakExpr` versus `source`.

## Migration cost, once decided

- **The game:**
  - the 25 direct `State` accesses listed above;
  - taking one effect queue and splitting it by variant, instead of `drainLogs` and `drainEffects`; `Main.logError` keeping its messages in the model;
  - the 28 natives (if the signature changes);
  - imports in 4 source modules and 9 test modules.
- **The playground:** one file.
- **elm-zak's own tests:** unaffected in substance, since they can keep using internal modules.
