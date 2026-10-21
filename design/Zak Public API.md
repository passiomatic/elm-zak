# Zak public API

The open questions about the public `Zak` module, left over from the API refactor (2026-10-05). The package docs in `src/Zak.elm` describe what's implemented. The full proposal and the reasons behind it are in this file's git history. Errors have their own file, "Zak Errors.md".

An item that would change a signature or remove a name has to be settled before the package is published. After that, it can only change in a major release.

## Before publishing

### The names of the data functions

`getField` reads one field, but `fields` (not `getFields`) reads them all, and `items` is the same for an array. The names don't line up. They're good enough for v1, but renaming them later is a breaking change.

### How `init` reports broken natives

A `nativeExpression` that fails to parse or evaluate is left undefined, and `init` queues a `Log LogError` naming it. Nothing stops the host from booting, and its tests still pass. The stricter option is `init : List ( String, Native ) -> Result (List BrokenNative) World`, which lists every broken native with its error. Switching to it changes `init`'s signature.

Since 2026-10-20, `init` logs a native it ignores the same way: one the standard library already has. A host's `nativeTable` named like a standard namespace (`Thread`, `Array`) adds its fields to it, so the engine can offer `Thread.with_input_off` next to `Thread.start`; it can't replace a standard function. Before, the standard library's namespace won whole and the host's was dropped without a word, so an engine native could only go in a namespace of its own. The stricter option above would list these too.

### Effects and waits named by strings

Proposed (2026-10-20), not decided. A host tells its own effects and waits apart by matching strings: `Effect String (List Value)` and `Wait String (List Value)`. A native queues `emitEffect "say_line" [ id, text ]`, and the host matches `( "say_line", [ Number id, String text ] )` back into its own type. The engine does this for over thirty effects (`Engine.toWorldChange`) and for its waits (`Engine.Actor.stillWaiting`, which also turns the name back into a type by a reverse lookup). A misspelled name or a misshapen argument list is only caught at run time, where the compiler could catch both.

The proposal: let the host pick the types, as type parameters.

```elm
type Effect effect
    = Log LogLevel String
    | Effect effect

type Wait wait
    = Wait wait

emitEffect : effect -> World effect wait -> World effect wait
tick : (wait -> World effect wait -> Bool) -> Float -> World effect wait -> ( List Error, World effect wait )
nativeWaitingFunction : (List Value -> World effect wait -> Result Problem ( wait, World effect wait )) -> Native effect wait
```

A native would queue the host's own value, `emitEffect (ActorSay id text) world`, and wait on one, `Ok ( WhileWalking id, world )`. The host decodes nothing: the engine's natives could queue its `WorldChange`s directly, so `toWorldChange` goes away, and `stillWaiting` becomes a plain `case`. A host with no effects or waits of its own uses `World Never Never`.

**Why it's strings now.** A waiting thread keeps its wait inside the interpreter's `State` (`Runtime.Host`), and so do the queued effects (`pendingEffects`). A type parameter on either makes `State` take it, and the interpreter's own `Value` holds natives that take `State` (`VNative`), so `Value` takes it too (no longer true since the function store, 2026-10-21: see "Comparing functions crashes"), and from there every type and function that mentions a value or the state: the heap, environments, threads, `Outcome`, `NativeValue`, the interpreter, and every standard-library module. It's mechanical, but it touches most of the package. Elm can't hide the parameter: a stored closure would need the host's state, which brings it back. `Wait` was shaped like `Effect` on purpose, so the two stay consistent; this changes both or neither.

**What changes for a host.** `World` and `Native` take the two parameters. The public `Value` does too, as long as `FunctionRef` holds a runtime function; with the function store (see "Comparing functions crashes") it holds an id instead, and `Value` stays as it is. The standard library's natives are polymorphic (`Native effect wait`), so they fit any host. A host keeps its own signatures short with an alias, `type alias World = Zak.World EngineEffect EngineWait`.

**One parameter or two.** Two, as above, keeps effects and waits apart, so `tick`'s answer can't be asked about an effect. One (`World host`) is shorter, but the host's single type then mixes effects and waits, and each side has to handle the other's cases as impossible. Two is the better fit; the alias makes the length moot.

## Later

### The thread model

Decided (2026-10-08): every thread has an owner, a `ThreadOwner` the host names (Zak defines none). A thread started with `Thread.start` gets the owner of the code that starts it, so a thread's descendants share its owner, and `Zak.stopThreads` stops them all. Code the host runs directly uses the owner set with `Zak.setThreadOwner`. `Thread.start_global` and `Zak.stopLocalThreads` were removed: a host that wants a "start this under another owner" primitive adds its own native calling `Zak.startThread`, which gives back the new thread's id (since 2026-10-09) so a script can `Thread.join` it. The package docs describe it.

Decided (2026-10-20), so a host can implement what its scripts wait on in Elm, instead of copying its state into the world for Zak code to poll (the engine had to, for a character walking or a cutscene ending):

- **Waits the host defines.** `Zak.nativeWaitingFunction` builds a native that gives back a `Wait` (a name and arguments, shaped like `Effect`) instead of a result, and the script that called it waits there. `Zak.tick` now takes the host's answer for those waits, `Wait -> World -> Bool`, true while a wait is still on. A wait is first checked on the next tick, and the call gives back `nil`. No result value yet: a waiting call can only be a statement of its own, so a value couldn't be used; resuming with one, and waiting in a `let`, assignment or `return`, come together if something needs them.
- **A thread exists from its first instruction.** It's registered before its body runs, so `hasThreads` and `join` count it during its first run, and it can be stopped then.
- **Stopping a running thread counts.** `Thread.stop` and `Zak.stopThreads` drop a running thread too, which then ends at its next wait. It used to be put back there, so stopping the running thread did nothing. It can't end at once: a thread only stops running at a wait (a call that's a statement of its own), so there's nowhere else for it to end.

Still open: **owners don't nest, but boundaries can.** Leaving a level should also stop the threads of a cutscene inside it, but they have different owners. With flat owners the host stops each owner it knows about, which is probably fine, since the host knows its own boundaries.

### A native expression only sees natives

A `nativeExpression` closes over the natives' frame, so it can't read the scripts' globals or any global the host sets with `setGlobal`. The game's `Actor.current()` and `Scene.current()` had to become Elm natives because of this. The package docs describe two workarounds: declare the global as a `nativeConstant Nil` first, or read it from an Elm native. Letting native expressions see the world's own globals would remove the need for either.

### Comparing functions crashes

`==` on two `Value`s holding functions crashed, because Elm can't compare functions, and the package docs warned about it on `FunctionRef`.

Fixed (2026-10-21) with a function store: a function lives in its own heap, `functionHeap`, and both the interpreter's `VFunction` and the public `FunctionRef` hold its id, as `VTable` and `TableRef` do. Two consequences:

- **In Zak, a function is `==` to itself,** as a table is, where before no function was equal to anything, itself included. Two functions built from the same source are still different functions.
- **No `Value` holds an Elm function any more,** so the game type parameter of the TWP-like model (elm-adventure's `design/TWP-like Model.md`) stops at the interpreter's state and its functions: `Value`, the heaps of tables and arrays, and environments don't take it.

A function allocates when it's created, once per evaluation of a function literal, as a table literal allocates a table; with no garbage collection, closures built in a loop grow the heap, as tables already do.
