module Zak.Thread exposing (natives)

{-| `wait_for`/`join` — the two primitives that actually suspend the
*calling* thread, kept in their own module since, unlike `start`/`start_global`, neither needs
to call back into `Zak.Interpreter` (no `callFunction`/`execBlock`
involved) — they just construct a `Suspended` value directly and hand it
back, so they're free of the circular-import constraint that keeps
`start`/`start_global` living in `Zak.Interpreter` itself (see that
module's own doc for the full reasoning).

Deliberately doesn't have a frame-counted `wait_frames(n)`-style sibling:
`wait_for(seconds)` covers waiting, so a whole-number, tick-counted wait
isn't a first-class primitive.

Module itself is named `Zak.Thread` to match the Zak-visible namespace it
feeds directly: `Thread.wait_for(...)`, `Thread.start(...)`, etc.

`wait_while` (below) lives here too, even though it's a `NativeZakExpr`
(pure Zak source, not Elm) with no circular-import constraint of its own
— kept alongside `wait_for`/`join` rather than off in some separate
module, since Zak-visible-wise it's just a third `Thread.*` primitive,
and splitting modules by "does this need `callFunction`" rather than "is
this part of the `Thread` namespace" would be organizing around an
implementation accident, not what a reader of this namespace actually
wants grouped together.

Exposes `natives`, merged by `Zak.Interpreter` alongside its own
`start`/`start_global` into one `Thread` namespace table
(`Thread.wait_for(...)`, `Thread.start(...)`, ...) — see
`Zak.Interpreter`'s own `threadNatives` doc for why that wrapping has
to happen there, one level up from `natives` here, rather than in this
module.
-}

import Dict exposing (Dict)
import Zak.Runtime exposing (NativeValue(..), Outcome(..), RuntimeError(..), State, Value(..), WaitCondition(..))


natives : Dict String NativeValue
natives =
    Dict.fromList
        [ ( "wait_for", NativeThreadFunction waitFor )
        , ( "join", NativeThreadFunction join )
        , ( "wait_while", NativeZakExpr waitWhileSource )
        ]


{-| `Thread.wait_while(predicate)` — suspends the current thread, calling
`predicate()` (with no arguments) once per tick, until it returns `false`
— a condition, re-evaluated every iteration, with a suspend in between.
Zak has no macros, so the condition has to be `predicate` (a
zero-argument closure the caller supplies, called fresh each iteration)
rather than a bare expression: `Thread.wait_while(function(): return
is_busy(x) end)`, not `Thread.wait_while(is_busy(x))` (which would
evaluate the condition once, up front, and wait on a frozen `Bool`
forever).

**Deliberately host-agnostic.** Host-specific waits (on whatever state
an embedder's own natives expose) belong to the embedder, built on
`wait_while`, not to `Zak.Thread` (core language) — and an embedder's
natives can't contribute to this same `"Thread"` namespace table anyway
(`Zak.Interpreter`'s own natives-merge is a shallow, first-argument-wins
`Dict.union`). Rather than build cross-module merge machinery just to get
shorter names, this ships the one primitive that's genuinely
core-language (a predicate is just a value, no host knowledge needed to
call one), and leaves shorter convenience wrappers to the embedder.

**`Thread.wait_for(0)` inside the loop, not some smaller/larger interval**
— this resumes on the very next tick (`Zak.Interpreter.tick`'s own
`elapsed + dt >= seconds` check is immediately true once `seconds = 0`),
giving real per-tick polling, the tightest cadence available.

Implemented as a `NativeZakExpr` (the same "don't implement what the
language can already express" technique `Zak.Math.abs` already uses),
not a raw Elm `NativeFunction`/`NativeThreadFunction` — `while` +
`Thread.wait_for` are both already real, tested primitives (including
suspending from inside a `while` loop body and resuming mid-iteration
across multiple ticks — see `Test.Zak.Thread`'s own coverage), so there's
nothing here that needs new interpreter machinery. Argument-count
checking (exactly one required parameter) and a non-callable `predicate`
(`NotAFunction`) both come free from ordinary Zak function-call handling
— no hand-written `WrongArgCount`/type-check branch needed the way
`waitFor`/`join` below (real `NativeFunction`s) require.
-}
waitWhileSource : String
waitWhileSource =
    """
    function(predicate):
        while predicate():
            Thread.wait_for(0)
        end
        return nil
    end
    """


{-| `Thread.wait_for(seconds)` — suspend the current thread until at least
`seconds` of elapsed tick time (summed `dt` across `Zak.Interpreter.tick`
calls) have passed. `seconds` may be fractional.
-}
waitFor : State -> List Value -> Result RuntimeError ( Outcome Value, State )
waitFor state args =
    case args of
        [ VNumber seconds ] ->
            Ok ( Suspended (Seconds seconds) (\s -> Ok ( Done VNil, s )), state )

        [ other ] ->
            Err (TypeError { expected = "Number", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| `Thread.join(thread_id)` — suspend the current thread until the thread
named by `thread_id` (a value previously returned by `Thread.start`/
`Thread.start_global`) is no longer running. The one generic "wait on
something else" primitive kept in this pass — host-specific wait
conditions are left to the embedder (see `wait_while`) rather than
folded in here.

`thread_id` must already be a whole number — the same `NotAnInteger`-style
strictness `Array`'s own index arguments already have — but an *unknown*
id (already finished, or never valid) isn't an error: it means "that
thread isn't running," so this resolves immediately (`Suspended` with a
wait condition that's already satisfied on the very next tick, rather
than a hard failure) — matching the spirit of `Array.get_default`'s
"soften a missing lookup, not a wrong type" split.

Known characteristic (bounded, not a bug that hangs anything):
resolving this wait condition can lag the joined thread's own actual
completion by one extra `tick` depending on thread-id ordering — see
`Zak.Interpreter.tick`'s own doc for the full mechanism and why it's left
as is.
-}
join : State -> List Value -> Result RuntimeError ( Outcome Value, State )
join state args =
    case args of
        [ VNumber idFloat ] ->
            let
                rounded =
                    round idFloat
            in
            if toFloat rounded == idFloat then
                Ok ( Suspended (ThreadRunning rounded) (\s -> Ok ( Done VNil, s )), state )

            else
                Err (NotAnInteger { index = idFloat })

        [ other ] ->
            Err (TypeError { expected = "Number", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })
