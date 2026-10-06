# Zak public API

The open questions about the public `Zak` module, left over from the API refactor (2026-10-05). The package docs in `src/Zak.elm` describe what's implemented. The full proposal and the reasons behind it are in this file's git history. Errors have their own file, "Zak Errors.md".

An item that would change a signature or remove a name has to be settled before the package is published. After that, it can only change in a major release.

## Before publishing

### The names of the data functions

`getField` reads one field, but `fields` (not `getFields`) reads them all, and `items` is the same for an array. The names don't line up. They're good enough for v1, but renaming them later is a breaking change.

### How `init` reports broken natives

A `nativeExpression` that fails to parse or evaluate is left undefined, and `init` queues a `Log LogError` naming it. Nothing stops the host from booting, and its tests still pass. The stricter option is `init : List ( String, Native ) -> Result (List BrokenNative) World`, which lists every broken native with its error. Switching to it changes `init`'s signature.

### Whether a thread takes its kind from the thread that starts it

Today it doesn't. The kind is picked at each start, so a plain `Thread.start` inside a global thread starts a local one. If threads inherited their kind (or their group, see "The thread model" below), helpers started by a thread would be stopped along with it. Switching to that after publishing would change what existing scripts do, so it has to be decided now. The suggestion is to keep today's rule: it's what's implemented, and it's easy to explain.

## Later

### The thread model

For v1, there are two kinds of thread. A script decides whether a thread is local or global when it starts it: `Thread.start` makes a local thread, and `Thread.start_global` a global one. The host has one way to act on that: `stopLocalThreads`. That fits the game, which stops local threads on a room change. A host whose threads need more than one boundary can't express that, for example a level and a dialog inside it. Whether "local" is the right word is also still open.

#### Named groups

This is the preferred way forward. A script names a group when it starts a thread, as in `Thread.start(fn, "dialog")`, and the host stops a group with `Zak.stopThreads : String -> World -> World`. Inside the interpreter, the thread's `isGlobal : Bool` becomes a `group : String`.

Today's two kinds become two built-in groups:

- `Thread.start(fn)` puts the thread in the default group, `"local"`;
- `Thread.start_global(fn)` is the same as `Thread.start(fn, "global")`, and stays as a shorthand;
- `stopLocalThreads` is `stopThreads "local"`.

So groups can be added without breaking anything, and a thread with no group keeps today's safe default. Two questions are open:

- **Groups don't nest, but boundaries do.** Leaving a level should also stop the threads of a dialog inside it, but `stopThreads "local"` leaves `"dialog"` running. With flat groups, the host stops each group it knows about. That's probably fine, since the host knows its own boundaries. Nested group names, or a thread in several groups, would be much more machinery for an unclear gain.
- **Whether `"global"` is reserved.** As an ordinary group, a host could call `stopThreads "global"`, which is useful for a reset, but then "global" is a convention, not a guarantee. Reserving it keeps the meaning, at the cost of a special case.

#### Leaving grouping to the host (set aside)

`start_global` would go away, and the host would track the threads it cares about. It's the most flexible option, but it costs more than it saves:

- **Zak still needs a host function.** The host can't stop a thread by id today, so `stopLocalThreads` would be traded for a `Zak.stopThread : Int -> World -> World`, not removed.
- **Every start has to be recorded.** The game would add a wrapper, say `Room.start(fn)`, that calls `Thread.start` and saves the id in a list it stops on a room change. Even storing the list is awkward, because a native expression can't see script globals (see "A native expression only sees natives" below).
- **The safe default flips.** A thread that doesn't go through the wrapper is silently global: one a script author forgot, one in a helper file, or any Zak code written without this host in mind. It leaks into the next room, and nothing reports it. Keeping the safe default means tracking the global threads instead and stopping all the others, which needs yet another host function to list the running threads.
- **Threads started by threads go untracked,** unless every script follows the convention.

Removing `start_global` would also be a breaking change.

### A native expression only sees natives

A `nativeExpression` closes over the natives' frame, so it can't read the scripts' globals or any global the host sets with `setGlobal`. The game's `Actor.current()` and `Scene.current()` had to become Elm natives because of this. The package docs describe two workarounds: declare the global as a `nativeConstant Nil` first, or read it from an Elm native. Letting native expressions see the world's own globals would remove the need for either.

### Comparing functions crashes

`==` on two `Value`s holding functions crashes, because Elm can't compare functions. The package docs warn about it on `FunctionRef`. The fix would be a function store: `FunctionRef` would hold an id, as `TableRef` does, instead of the function itself.
