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

Still open: **owners don't nest, but boundaries can.** Leaving a level should also stop the threads of a cutscene inside it, but they have different owners. With flat owners the host stops each owner it knows about, which is probably fine, since the host knows its own boundaries.

### A native expression only sees natives

A `nativeExpression` closes over the natives' frame, so it can't read the scripts' globals or any global the host sets with `setGlobal`. The game's `Actor.current()` and `Scene.current()` had to become Elm natives because of this. The package docs describe two workarounds: declare the global as a `nativeConstant Nil` first, or read it from an Elm native. Letting native expressions see the world's own globals would remove the need for either.

### Comparing functions crashes

`==` on two `Value`s holding functions crashes, because Elm can't compare functions. The package docs warn about it on `FunctionRef`. The fix would be a function store: `FunctionRef` would hold an id, as `TableRef` does, instead of the function itself.
