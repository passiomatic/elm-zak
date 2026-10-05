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

For v1, there are two kinds of thread. A script decides whether a thread is local or global when it starts it: `Thread.start` makes a local thread, and `Thread.start_global` a global one. The host has one way to act on that: `stopLocalThreads`. That fits the game, which stops local threads on a room change. A host whose threads need more than one boundary can't express that, for example a level and a dialog inside it. Two alternatives were set aside:

- **Named groups.** A script names a group when it starts a thread, as in `Thread.start(fn, "dialog")`. The host stops a group with `Zak.stopThreads "dialog" world`. It's more general, but it adds to both the language and the API.
- **Leaving grouping to the host.** `start_global` goes away. A native records the ids of the threads it cares about, and stops them. It's the most flexible option, but every host has to do that work itself.

Named groups could be added without breaking anything, since `stopLocalThreads` and `start_global` could stay. Removing `start_global` would be a breaking change. Whether "local" is the right word is also still open.

### A native expression only sees natives

A `nativeExpression` closes over the natives' frame, so it can't read the scripts' globals or any global the host sets with `setGlobal`. The game's `Actor.current()` and `Scene.current()` had to become Elm natives because of this. The package docs describe two workarounds: declare the global as a `nativeConstant Nil` first, or read it from an Elm native. Letting native expressions see the world's own globals would remove the need for either.

### Comparing functions crashes

`==` on two `Value`s holding functions crashes, because Elm can't compare functions. The package docs warn about it on `FunctionRef`. The fix would be a function store: `FunctionRef` would hold an id, as `TableRef` does, instead of the function itself.
