# Garbage collection

Does Zak need a garbage collector? Measured on 2026-10-29 against the real Delores scripts. **Short answer: not now.** The heap leaks, but slowly, and it costs no speed.

**Status (2026-10-30):** scope frames are now freed when their scope ends (see [Freeing frames](#freeing-frames-done)). That cuts the heap's growth by about 90%. Tables, arrays and closures are still never freed.

## What leaks

Before frame freeing, nothing was ever freed. `allocCell`, `allocArrayCell` and `allocFunction` (`Zak.Internal.Runtime`) only insert into the heaps. Garbage comes from two sources:

1. **Scope frames.** `execBlock` allocates a frame every time a block runs: every function call, every `if` branch taken, every loop iteration.
2. **Tables, arrays and closures.** Every literal allocates one, for example the array in `String.format("%s %s", [label, name])`.

The heaps are Elm `Dict`s, so the cost is memory, plus lookups getting slightly slower (O(log n)) as the heap grows.

## Measurements

These are the numbers before frame freeing. [Freeing frames](#freeing-frames-done) has the numbers after.

**Method.** A Node worker booted Delores with the real engine natives and ran simulated frames at 60 fps. It replayed the part of `Main`'s `AnimationFrame` loop that runs Zak code: motors and `Game.on_actor_arrived`, scene effects, `Cutscene.settle`, `Zak.tick` and `Conversation.update`. A bot player clicked a scene object every 4 seconds, as `Main.leftClick` does. It also picked dialogue choices in turn and skipped cutscenes. A patched copy of elm-zak counted frame allocations and walked what's reachable from the world frame.

**Right after boot, 93% of the heap is already garbage.** Boot leaves about 27,400 cells: 22,838 frames and tables, 2,207 arrays and 2,389 functions. Only about 2,000 are reachable from the world frame. Nearly all the rest are frames from the `define_*` calls.

**Growth during play depends on the scene:**

| Scene | Clicking | Idle |
|---|---|---|
| SheriffsOffice | ~12 cells/s | ~11 cells/s |
| Nickel | ~11 cells/s | ~5 cells/s |
| Diner | ~4.5 cells/s | ~4 cells/s |
| QuickiePalOutside | ~4 cells/s | ~4 cells/s |
| MainStreet | ~2.7 cells/s | ~2.5 cells/s |
| Alleyway | ~1.8 cells/s | ~1.9 cells/s |
| Bank | ~1.5 cells/s | ~1.4 cells/s |

(Per second of game time.)

**Two hours of clicking in Nickel**, one of the fastest-growing scenes:

- The heap went from about 27,000 to 109,000 cells, about 41,000 an hour.
- 90% of the growth is scope frames, 7% arrays, 3% tables and closures.
- What's reachable from the world frame stayed flat at about 2,000 cells. After 2 hours, about 98% of the heap is garbage.
- JS memory after a forced collection went from 24.1 to 37.4 MB: **about 6.6 MB an hour**, or about 160 bytes per cell.
- **No slowdown.** The Zak side of the frame loop took about 0.22 ms per frame, both at 23,000 cells and at 99,000.

**What doesn't leak:**

- **Hover text and the inventory row.** They're queries (`Engine.queryGlobal`, `Engine.queryField`) that run on every mouse move or frame. `Main` keeps only their logs and throws away the world they return, so nothing they allocate is kept.
- **Save games.** The design in elm-adventure's `design/Save Games.md` walks the globals, not the raw heap, so garbage never ends up in a save.

**Limits of the measurement:**

- The probe skipped trigger zones, animation-triggered handlers and waiting for animations to finish. Scripts that wait on an animation may have stalled, so their allocations could be undercounted.
- The reachable count can't see the frames of suspended threads, but there were never more than 10 threads.
- The player is a bot. One click every 4 seconds, all session long, is probably more than a real player does.

## What it means

A 3-hour session of nonstop clicking costs about 20 MB, with no effect on speed. For a browser game, that's not worth fixing now.

## Freeing frames (done)

Done on 2026-10-30, as step 1 below describes:

- `Interpreter.withFrame` makes every scope frame (a block, a call's parameters, a `for` loop's variable). It frees the frame when the scope ends: right away, or, if the body waits, when the resumed body finishes.
- `Interpreter.captureEnv` marks a frame captured when a `function` literal is evaluated in it. A captured frame is kept (`State.capturedFrames`).
- Reading or writing a variable through a frame that isn't in the heap is an `InternalError` ("scope frame N was freed while still in use"). Before, `lookupVar` and `assignVar` skipped a missing frame and `defineVar` recreated it, so a frame freed too early would have given silently wrong values.

**Results** (the same probe, 2 hours of clicking in Nickel):

| | Before | After |
|---|---|---|
| Heap cells right after boot | 22,838 | 3,296 |
| Growth over 2 h, all heaps | ~82,000 cells | ~8,600 cells (−89%) |
| JS memory growth over 2 h | +13.3 MB | +4.3 MB (about 2 MB an hour) |
| Zak time per 30 s of game | ~390 ms | ~370 ms |

A second run went through all 14 scenes, with about 900 clicks, without any freed-frame error.

**What still leaks:**

- **Arrays**, two thirds of what's left, mostly from `String.format(..., [a, b])`.
- **Captured frames**, even once their closure is gone. That's about 2,200 frames at boot, and about 60 an hour after.
- **The frames of a thread stopped while waiting.** `stopThreads` drops its continuation, so the frames of the blocks it was inside are never freed. That's a few frames per stop, and a click that cancels the selected actor's action is one.
- **Tables and closures.**

## If it ever needs fixing

**1. Free frames when their block ends.** Done: see [Freeing frames](#freeing-frames-done). This handles about 90% of the growth. A frame can only outlive its block in two ways:

- **A closure captured it.** Evaluating a `function` literal stores the current `Env` chain.
- **A thread suspended inside it.** The continuation holds the `Env`.

So: when evaluating a function literal, mark the frames in its `Env` chain as captured. When `execBlock` finishes with `Done`, remove its frame unless it's marked. When it finishes with `Suspended`, wrap the continuation so the frame is removed when the resumed block finishes.

Cost: one `Dict.remove` per block, plus a walk up the chain per function literal. No public API change. The risk is contained: a frame freed too early shows up as an "undefined name" error, which tests catch quickly.

**2. Mark-and-sweep, for tables, arrays and closures.** The algorithm is simple; finding the roots is the hard part. There are two blind spots:

- **Suspended threads.** Their continuations are Elm functions, which can't be inspected. Since a wait can only be a statement on its own, no half-evaluated expression holds values at a suspension point. Everything live is reachable from the `Env`s of the active blocks, so `Suspended` could collect those `Env`s as it bubbles up and carry them next to the continuation. That's mechanical, but it touches every place that wraps a continuation.
- **Values the host keeps.** The public API hands out table, array and function references. If the host stores one across ticks, the collector can't see it and would free a live value. This needs a public API decision: references held by the host are only valid until the next collection, or there's an explicit pin/unpin API, or collection only runs when the host asks for it (for example on a scene change), at a moment it promises not to hold any references.

A full pass is O(live + heap). Run on a scene change, or every few thousand allocations, it costs a few milliseconds now and then, not a per-frame cost.

**Reference counting is a poor fit.** It needs a count update on every assignment, through persistent `Dict`s, and Zak code is full of cycles: tables holding methods that capture `self`, and objects that refer to each other.

**Recommendation:** step 1 is done, and step 2 isn't justified by these numbers. Its host-references question is the only part that would affect the public API.

## Running the probe again

The probe lived in a scratch folder and isn't in either repo. To rebuild it:

- **A copy of elm-zak's `src/`** with:
  - a `framesAllocated` counter in `State`, incremented where `withFrame` allocates;
  - a `Zak.heapStats` that returns the three heap sizes plus a reachability walk from `globalFrameId`, following `VTable` / `VArray` / `VFunction` values and closures' `Env` chains.
- **A `Platform.worker`** compiled with elm-adventure's `elm.json`, its source directories pointed at elm-adventure's `src/` and the patched copy. It builds the world as `Main.startPlaying` does (including `soundLengths`), runs `Boot.run`, then plays frames on request through a port and reports `heapStats`.
- **A Node script** that passes it every `.zak`, `.json` and `.yack` file under `Delores/` and `Shared/` as flags, steps it 30 seconds of game time at a time, and logs the heap sizes, the wall time and `process.memoryUsage().heapUsed` after `global.gc()` (run with `node --expose-gc`).
