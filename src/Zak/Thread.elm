module Zak.Thread exposing (natives)

{-| `wait_for`/`join` — the two primitives that actually suspend the
*calling* thread, kept in their own module (named after Python's own
`threading` module) since, unlike `start`/`start_global`, neither needs
to call back into `Zak.Interpreter` (no `callFunction`/`execBlock`
involved) — they just construct a `Suspended` value directly and hand it
back, so they're free of the circular-import constraint that keeps
`start`/`start_global` living in `Zak.Interpreter` itself (see that
module's own doc for the full reasoning).

Named in Zak's own snake_case convention, not Dinky's original camelCase
(`breakhere`/`breaktime`/`breakwhile*`) — see `design/Dinky Findings.md`'s
own coroutine findings for why these exist at all. `wait_for`/`join` were
themselves `yield_time`/`yield_while_running` earlier in this redesign —
"yield" was chosen first, deliberately away from the reference engine's
own "break" (Zak already uses `break`/`Break` for loop-exit, an unrelated,
much more common meaning than the SCUMM-family "pause this script's
time-slice" one the original name carries) — then renamed again, further
still, once "wait for this many seconds"/"join this thread" turned out to
read more directly than "yield" did for either one. See
`design/Zak Built-in Functions.md`'s own naming notes for the full history
of both renames.

Deliberately doesn't have a frame-counted `yield_here(n)`-style sibling
(`breakhere`'s own would-be port): checked directly against the real
DeloresDev `.dinky` source (49 files) before deciding, and `breakhere` is
used **zero** times anywhere in the actual game, versus `breaktime` at
166 uses — real precedent didn't support keeping a whole-number,
tick-counted wait primitive as a first-class citizen, so it was dropped
rather than ported unexamined. `wait_for(seconds)` alone covers every
real "wait" case this reference material actually shows.

Module itself is named `Zak.Thread` (not the elder `Zak.Threading`, which
this replaced) to match the Zak-visible namespace it feeds directly:
`Thread.wait_for(...)`, `Thread.start(...)`, etc — see
`design/Zak Built-in Functions.md`'s own "Decided: `Threading` renamed to
`Thread`" note for why.

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
`predicate()` (with no arguments) once per tick, until it returns `false`.
Real Dinky's own `breakwhile($a)` macro (`Dinky-Grammar.md:409`) expands
to exactly this shape, `while($a) { breaktime(0.5) }` — a condition,
re-evaluated every iteration, with a suspend in between. Zak has no
macros, so `$a` (an arbitrary expression, re-inlined verbatim on every
loop pass) becomes `predicate` (a zero-argument closure the caller
supplies, called fresh each iteration) — the closest a callable-only
language can get to the same idiom: `Thread.wait_while(function(): return
Actor.walking?(delores) end)`, not `Thread.wait_while(Actor.walking?(delores))`
(which would evaluate the condition once, up front, and wait on a frozen
`Bool` forever).

**Deliberately game-agnostic, unlike the two named siblings real Dinky
also has (`breakwhilewalking`/`breakwhiletalking`).** This project's own
`Actor.walking?`/`Actor.talking?` live in `Engine.Actor` (game-specific),
not `Zak.Thread` (core language) — and the two modules can't both
contribute to this same `"Thread"` namespace table (`Zak.Interpreter`'s
own natives-merge is a shallow, first-argument-wins `Dict.union`; no two
sources have ever shared a namespace key in this codebase). Rather than
build new cross-module merge machinery just to get shorter names, this
ships the one primitive that's genuinely core-language (a predicate is
just a value, no `Actor` knowledge needed to call one), and leaves
`Actor.wait_while_walking`-style convenience wrappers for whenever real
ported content actually wants that exact shorter spelling repeatedly —
see `design/Zak Built-in Functions.md`'s own "Thread" section for the
fuller writeup of this decision.

**`Thread.wait_for(0)` inside the loop, not some smaller/larger interval**
— confirmed this resumes on the very next tick (`Zak.Interpreter.tick`'s
own `elapsed + dt >= seconds` check is immediately true once `seconds =
0`), giving real per-tick polling, the same granularity the reference
engine's own native `breakwhilewalking`/`breakwhiletalking` presumably
have (unlike the generic `breakwhile($a)` macro's own coarser 0.5s
poll — this project only has the one primitive, so it uses the tighter
cadence rather than guessing at which real callers wanted which).

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
something else" primitive kept in this pass — see `design/Dinky
Findings.md`'s note on why game-specific wait conditions (is this actor
still walking, still talking, ...) are deliberately deferred rather than
folded in here.

`thread_id` must already be a whole number — the same `NotAnInteger`-style
strictness `Array`'s own index arguments already have — but an *unknown*
id (already finished, or never valid) isn't an error: it means "that
thread isn't running," so this resolves immediately (`Suspended` with a
wait condition that's already satisfied on the very next tick, rather
than a hard failure) — matching the spirit of `Array.get_default`'s
"soften a missing lookup, not a wrong type" split.

Known, confirmed characteristic (bounded, not a bug that hangs anything):
resolving this wait condition can lag the joined thread's own actual
completion by one extra `tick` depending on thread-id ordering — see
`Zak.Interpreter.tick`'s own doc for the full mechanism, why it's left as
is, and the thin real-precedent question around `join` as a first-class
suspend primitive at all (`threadrunning` in the real DeloresDev source
is only ever a plain boolean check, never a blocking wait).
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
