# Zak public API

The open questions about the public `Zak` module, left over from the API refactor (2026-10-05). The package docs in `src/Zak.elm` describe what's implemented. The full proposal and the reasons behind it are in this file's git history. Errors have their own file, "Zak Errors.md".

An item that would change a signature or remove a name has to be settled before the package is published. After that, it can only change in a major release.

## Before publishing

### The names of the data functions

`getField` reads one field, but `fields` (not `getFields`) reads them all, and `items` is the same for an array. The names don't line up. They're good enough for v1, but renaming them later is a breaking change.

### How `init` reports broken natives

A `nativeExpression` that fails to parse or evaluate is left undefined, and `init` queues a `Log LogError` naming it. Nothing stops the host from booting, and its tests still pass. The stricter option is `init : List ( String, Native ) -> Result (List BrokenNative) World`, which lists every broken native with its error. Switching to it changes `init`'s signature.

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

`==` on two `Value`s holding functions crashes, because Elm can't compare functions. The package docs warn about it on `FunctionRef`. The fix would be a function store: `FunctionRef` would hold an id, as `TableRef` does, instead of the function itself.
