module Zak.Interpreter exposing
    ( Error(..)
    , run
    , runExpr
    , initialWorld
    , runIncremental
    , include
    , tick
    , drainEffects
    , call
    , allocCell
    )

{-| Evaluates a `Zak.AST` tree produced by `Zak.Parser`, against the
runtime value model `Zak.Runtime` defines. There are two tiers of
unconditional built-ins, for two different reasons:

`Array`/`Table` are unconditional in *every* entry point below, including
`runExpr` — a real technical necessity, not a preference: `.field`/`.field
= value`/`[index]`/`[index] = value` need to share their actual
implementation with `Table.get`/`Table.set`/`Array.get`/`Array.set` (see
`getTableField`/`setTableField`/`getArrayIndex`/`setArrayIndex` below),
and that sharing only works if both live in the same module as this
evaluator — see `builtinNatives` below.

`Math`/`String`/`Debug`/`Globals` (the `Debug` namespace table, plus the
bare global `type`) are
unconditional only in `run`/`initialWorld`/`runIncremental`, deliberately
*not* in `runExpr` — see `stdlibNatives` below for why, and why this split
is a design choice about what a "real program" should be able to assume
rather than a technical constraint the way `Array`/`Table`'s is.

Anything beyond those two tiers (any host-specific native like a
hypothetical `walk_to`/`say_line`) is supplied by the caller as native
functions passed into `run`, grouped under `NativeValue` so a whole group
of related natives can be seeded as one namespace table (`Math.cos(1)`)
instead of flooding the global scope with every individual name.
-}

import Array exposing (Array)
import Dict exposing (Dict)
import Random
import Set
import Zak.AST exposing (AssignTarget(..), BinaryOp(..), Block, Expr(..), PathSegment(..), Position, PositionedStatement, Statement(..), UnaryOp(..))
import Zak.Debug as ZakDebug
import Zak.Globals as Globals
import Zak.Math as Math
import Zak.Parser as Parser
import Zak.Random as ZakRandom
import Zak.Thread as Thread
import Zak.Runtime
    exposing
        ( Effect(..)
        , Env(..)
        , LogLevel(..)
        , NativeValue(..)
        , Outcome(..)
        , RuntimeError(..)
        , Signal(..)
        , State
        , Thread(..)
        , ThreadId
        , Value(..)
        , WaitCondition(..)
        , mapOutcome
        , mapOutcomeResult
        , requireDone
        )
import Zak.String as ZakString


{-| `Value`, `RuntimeError`, `NativeValue`, `Env`, `State`, `Signal`,
`Outcome`, `WaitCondition`, `ThreadId`, `Thread` all live in `Zak.Runtime`
now (imported above) — see that module's own doc for why. `Error` stays
here: it's only ever the return type of `run`/`runExpr`/`runIncremental`
below, never something a native module needs.
-}
type Error
    = SyntaxError Parser.Error
    | RuntimeError RuntimeError


{-| Chains a suspend-capable computation the same way `Result.andThen`
chains a plain one — `Result.andThen`'s `Outcome`-aware counterpart. If
the input already finished (`Done value`), runs `f` immediately, same as
`Result.andThen` always does. If it's still `Suspended`, `f` can't run
yet — instead, wraps `f` into the suspended value's own `resume`
continuation, so it runs automatically the moment whatever's still being
waited on resumes, however many times that takes. Every place in this
module that used to write `Result.andThen (\\( signal, state1 ) -> ...)`
against a `Result RuntimeError ( Signal, State )` now writes `andThenOutcome
(\\signal state1 -> ...)` against the `Outcome`-wrapped equivalent instead —
same shape, suspension handled once, here, rather than at every call site.
-}
andThenOutcome :
    (a -> State -> Result RuntimeError ( Outcome b, State ))
    -> Result RuntimeError ( Outcome a, State )
    -> Result RuntimeError ( Outcome b, State )
andThenOutcome f result =
    result
        |> Result.andThen
            (\( outcome, state ) ->
                case outcome of
                    Done value ->
                        f value state

                    Suspended cond resume ->
                        Ok ( Suspended cond (\s -> andThenOutcome f (resume s)), state )
            )



-- ENTRY POINTS


{-| Parse and run a whole program, returning the value of its last `return`
(or `VNil` if it never returns — same convention as a function body).
Literally `initialWorld` followed by one `runIncremental` call, discarding
the trailing `State` — a single-shot program never needs to hand its
`Env`/`State` back to the caller the way `runIncremental` does, since
there's no "next script" to run against them. Unlike `runExpr`, this is a
real program, so it gets `stdlibNatives` (`Math`/`String`/`Debug`/`type`)
seeded automatically too — see `initialStateFull`, which `initialWorld`
itself seeds with.
-}
run : Dict String NativeValue -> String -> Result Error Value
run natives source =
    let
        ( env, state ) =
            initialWorld natives
    in
    runIncremental env state source
        |> Result.map Tuple.first


{-| Parse and evaluate a single expression — a lighter-weight entry point
than `run`, useful whenever a whole program isn't needed (e.g. testing
arithmetic, comparisons, or a call in isolation). Deliberately bare:
`Array`/`Table` are still seeded (see `initialState`), but `Math`/
`String`/`Debug`/`type` are not — a single already-scoped expression
doesn't need the same "real program" guarantee `run`/`initialWorld` do,
and a caller that wants them here can still pass them in explicitly via
`natives`.
-}
runExpr : Dict String NativeValue -> String -> Result Error Value
runExpr natives source =
    case Parser.parseExpr source of
        Err parserError ->
            Err (SyntaxError parserError)

        Ok expression ->
            evalExpr globalEnv (initialState natives) expression
                |> Result.map Tuple.first
                |> Result.mapError RuntimeError


{-| Bootstraps a persistent world scope: allocates one frame chained under
`globalEnv` — the "world" frame every loaded script's top-level `let`s
will land in — and returns it alongside the seeded `State`. Used for
loading several scripts incrementally (one file at a time), threading the
returned `( Env, State )` through `runIncremental` once per loaded file —
and also by `run` itself, which is just one `initialWorld` call followed
by one `runIncremental` call.

Exposed (rather than kept private to `run`) because `runIncremental` is
meant to be called more than once against the *same* frame — once per
script, as scripts arrive over real time (e.g. HTTP fetches resolving one
after another in a browser) — so the caller has to be the one holding
`Env`/`State` between calls; the interpreter has no way to wait for "the
next script" itself. `run` only ever needs one such call, so it never has
to see `Env`/`State` at all — its own signature hides both.

Seeded with `initialStateFull`, not `initialState`, since `runIncremental`
never reseeds natives itself (see its own doc): this is the only place a
world loaded incrementally (or via `run`) gets `Math`/`String`/`Debug`/
`type` at all.
-}
initialWorld : Dict String NativeValue -> ( Env, State )
initialWorld natives =
    let
        ( frameId, state1 ) =
            allocCell (initialStateFull natives)
    in
    ( Env frameId (Just globalEnv), { state1 | globalFrameId = frameId } )


{-| Runs one more script's top-level statements into an existing world
scope from `initialWorld` (or a previous `runIncremental` call) — so a
`let` in this file can see every earlier file's globals, and a later
file's can see this one's. Uses `execStatements` directly, not
`execBlock` — deliberately: `execBlock` would allocate yet another fresh
frame per call, isolating each file's globals from every other's the same
way two separate `run` calls would (see `initialWorld`'s own doc). A
`let` for a name an earlier script already defined is `AlreadyDefined`,
the same rule one script's own redeclared `let` already hits, just
extended to the whole loaded world.

A top-level script suspending at all (e.g. calling `Thread.wait_for`
directly, not from inside a `Thread.start`-spawned body) is
`SuspendedNotAllowed` — a root-VM-can't-suspend constraint (see `Zak.Runtime.Outcome`'s doc): only
`Thread.start`/`Thread.start_global` ever let a
script's own statements actually run as a suspend-capable thread, and
those two natives fully absorb whatever their spawned body
does (registering it with `State.threads` if it suspends) before
returning here, so a `Suspended` reaching all the way out to
`runIncremental` never happens for a *correctly* written top-level
script — only for one that calls a suspending native directly, which is
exactly the case this should reject.
-}
runIncremental : Env -> State -> String -> Result Error ( Value, State )
runIncremental env state source =
    case Parser.parseProgram source of
        Err parserError ->
            Err (SyntaxError parserError)

        Ok program ->
            runProgramInto env state program
                |> Result.mapError RuntimeError


{-| The shared "run this block's own top-level statements into `env`,
collapsing an unexpected top-level suspend into `SuspendedNotAllowed`"
core both `runIncremental` and `include` (below) are built from —
factored out once `include` needed the exact same collapsing logic
but a `RuntimeError`-only result (a native mid-execution has no
`Error`/`SyntaxError` channel to report through, only `RuntimeError`).
-}
runProgramInto : Env -> State -> Block -> Result RuntimeError ( Value, State )
runProgramInto env state program =
    execStatements env state program
        |> Result.andThen
            (\( outcome, state1 ) ->
                case outcome of
                    Done signal ->
                        signalValue signal |> Result.map (\value -> ( value, state1 ))

                    Suspended _ _ ->
                        Err SuspendedNotAllowed
            )


{-| `include(path)`'s own core (the embedder's own `include` native is the
thin, host-specific wrapper around this: it resolves `path` to `source`,
a lookup this module deliberately knows nothing about). Splices `source`'s own
top-level statements into the shared *world* frame, not `env`'s (whatever
that happens to be at the call site) — `state.globalFrameId`, stamped
once by `initialWorld`, is what every top-level `let` across every
included file needs to land in, matching `runIncremental`'s own
existing "every file sees every other file's globals" behavior, just
triggered from inside a running script instead of the embedder's own
external loop.

Idempotent: including the same `path` twice is a silent no-op (`state.
includedFiles`) rather than a second, redundant run — the same
`AlreadyDefined` a second literal run would hit anyway for every `let` it
already declared, and (not incidentally) the entire guard against an
include cycle: if `A` includes `B` includes `A`, `A` is already marked
included by the time `B`'s own `include("A")` runs, so it resolves to
`VNil` instead of looping.
-}
include : String -> String -> State -> Result RuntimeError ( Value, State )
include path source state =
    if Set.member path state.includedFiles then
        Ok ( VNil, state )

    else
        case Parser.parseProgram source of
            Err parserError ->
                Err (IncludeParseError path parserError)

            Ok program ->
                runProgramInto (Env state.globalFrameId (Just globalEnv))
                    { state | includedFiles = Set.insert path state.includedFiles }
                    program


{-| Calls an already-resolved `Value` (e.g. a function field the
embedder read off some Zak table, not something evaluated from source
here) as a function — the embedder-facing entry point around the
otherwise-internal `callFunction`, for exactly the case `run`/
`runIncremental` don't cover: invoking a Zak closure the embedder already
has a handle on, outside of running a whole program. Named `call`, not
something host-specific like `callVerb` — this module stays host-agnostic
regardless of *why* an embedder wants to call a value.

Same `Outcome`-collapsing `runIncremental` itself already does: a bare
call can never suspend (`Suspended _ _ -> SuspendedNotAllowed`) — a value
that wants to suspend has to already be a thread's own body, started via
`Thread.start(...)` from *inside* whatever script produced this `Value`
in the first place. `callFunction` itself is deliberately not exposed
directly: every other public entry point in this module already commits
to this same "top-level calls can't suspend" contract, and exposing the
raw `Outcome`/`RuntimeError` pair here would let a caller route around
it.
-}
call : State -> Value -> List Value -> Result Error ( Value, State )
call state callee args =
    callFunction state callee args
        |> Result.mapError RuntimeError
        |> Result.andThen
            (\( outcome, state1 ) ->
                case outcome of
                    Done value ->
                        Ok ( value, state1 )

                    Suspended _ _ ->
                        Err (RuntimeError SuspendedNotAllowed)
            )


{-| The global scope: frame 0, with no parent. Fixed by construction —
`initialState` always allocates the first frame at id 0.
-}
globalEnv : Env
globalEnv =
    Env 0 Nothing


{-| Seeds the global frame with `builtinNatives` merged with `natives`
(resolving each `NativeNamespace` into a real heap-allocated `VTable`, and
each `NativeZakExpr` by parsing and evaluating it, along the way), plus
`true`/`false`/`nil`. `natives` is whatever the embedder chooses to
wire up — merged in *after* `builtinNatives` so a caller can never shadow
`Array`/`Table` this way (`Dict.union` prefers its first argument's
keys), the same protection `true`/`false`/`nil` already get below. A
*script* can still shadow `Array`/`Table` locally with its own `let`,
same as any other global — this only stops a native-Elm-code caller from
redefining what they mean for every script it runs.

Used directly by `runExpr`, which deliberately stops here (no
`stdlibNatives`) — see `initialStateFull` for the version `run`/
`initialWorld` use instead.
-}
initialState : Dict String NativeValue -> State
initialState natives =
    seedState (Dict.union builtinNatives natives)


{-| Same as `initialState`, but also seeds `stdlibNatives`
(`Math`/`String`/`Debug`/`type`) — the full standard library, not just
`Array`/`Table`. Used by `run` and
`initialWorld` (and, through it, `runIncremental` — see that pair's own
docs), which are meant to run a complete, real program rather than a
single already-scoped expression. Precedence is `builtinNatives` over
`stdlibNatives` over caller `natives`, same "nothing a caller passes in
can shadow the guaranteed built-ins" rule `initialState` already
enforces for `Array`/`Table`, just extended one tier further.
-}
initialStateFull : Dict String NativeValue -> State
initialStateFull natives =
    seedState (Dict.union builtinNatives (Dict.union stdlibNatives natives))


{-| `true`/`false`/`nil` are const in frame 0, so a bare `true = ...`
reaching all the way down to this frame is a `ConstReassigned` error
rather than silently repointing what every later `true` in the program
means — the typo-guard the original `const` open point named as a
motivating case. `natives` (`Array`/`Table`/`Math`/... ) deliberately
stay out of `constNames` for now, not because they're any less
"built-in" than `true`/`false`/`nil`, just a smaller, more conservative
first step. This only blocks *reassignment*: a script's own
`let true = ...` in a nested scope still shadows the built-in exactly as
before — that's a new binding in a child frame, `defineVar`
never even looks at frame 0's `constNames`.
-}
seedState : Dict String NativeValue -> State
seedState natives =
    let
        ( resolvedNatives, state1 ) =
            resolveNatives
                { heap = Dict.empty
                , arrayHeap = Dict.empty
                , constNames = Dict.empty
                , nextId = 1
                , threads = Dict.empty
                , nextThreadId = 0
                , pendingEffects = []
                , randomSeed = Random.initialSeed 0

                -- Both placeholder-zero here -- neither means anything until
                -- `initialWorld` allocates the real world frame right after
                -- this and stamps its own id into `globalFrameId`; nothing
                -- reads either field before that happens.
                , globalFrameId = 0
                , includedFiles = Set.empty
                }
                natives

        globals =
            resolvedNatives
                |> Dict.insert "true" (VBool True)
                |> Dict.insert "false" (VBool False)
                |> Dict.insert "nil" VNil
    in
    { state1
        | heap = Dict.insert 0 globals state1.heap
        , constNames = Dict.insert 0 (Set.fromList [ "true", "false", "nil" ]) state1.constNames
    }


{-| `Math`/`String`/`Debug`/`Random`/the bare global (`type`) — the rest
of the standard library beyond `Array`/`Table`. Unlike `builtinNatives` below, nothing about these
needs to share implementation with any dedicated syntax, so there's no
*technical* reason they couldn't live in a caller-supplied `natives` dict
instead — they're unconditional here purely as a design choice about
what a "real program" (`run`/`initialWorld`/`runIncremental`) should be
able to assume, deliberately not extended to `runExpr` (see that
function's own doc). Precedence mirrors `Zak.Math`/`Zak.Globals`/
`Zak.String`/`Zak.Debug`/`Zak.Random`'s own declaration order; none of
the five share any keys, so the order doesn't actually matter today.
-}
stdlibNatives : Dict String NativeValue
stdlibNatives =
    Dict.union (Dict.union Math.natives Globals.natives) ZakString.natives
        |> Dict.union threadNatives
        |> Dict.union ZakDebug.natives
        |> Dict.union ZakRandom.natives


{-| One `Thread` namespace table holding all four threading primitives: `wait_for`/`join`
(`Zak.Thread`, neither of which needs to call back
into this module) plus `start`/`start_global` (defined
directly below, since spawning a thread means running its closure
argument via `callFunction`/`execBlock` — exactly the kind of sharing
that keeps `Array`/`Table`'s own natives living in this module too, per
this module's own top-of-file doc; putting these two in `Zak.Thread`
instead would need `Zak.Thread` to import `Zak.Interpreter`, and
`Zak.Interpreter` already imports `Zak.Thread` for the other two — a
real circular import, not a style preference).
The wrapping happens here, one level up from `Zak.Thread.natives`
itself, specifically so it covers all four together — wrapping only
`Zak.Thread.natives` would leave `start`/`start_global`
stranded outside the namespace, since they're merged in from a different
module entirely.

Merged into `stdlibNatives` since this is exactly as unconditional (in
`run`/`initialWorld`/`runIncremental`, not `runExpr`) as `Math`/`String`/
`Debug`/`type` already are, for the same reason: nothing about scripting
threads is a technical necessity the way `Array`/`Table`'s sharing is,
it's a "what a real program should be able to assume" design choice.
-}
threadNatives : Dict String NativeValue
threadNatives =
    Dict.singleton "Thread"
        (NativeNamespace
            (Thread.natives
                |> Dict.insert "start" (NativeFunction (start False))
                |> Dict.insert "start_global" (NativeFunction (start True))
            )
        )


{-| `Thread.start(closure)` / `Thread.start_global(closure)` — spawns
`closure` (called with zero arguments) as an independent, suspend-capable
thread: its body runs *immediately*, synchronously, right here, up to its
own first suspend point or completion — *before* this call itself returns anything. If the body suspends partway
through, the resulting `Thread` (see `Zak.Runtime`'s own doc) is
registered under a freshly-allocated id in `state.threads`, to be resumed
later by `tick`; if the body runs to completion without ever suspending,
nothing gets registered at all — there's nothing left to resume. Either
way, this call's *own* result is always `Done (VNumber threadId)` — the
new thread's id, handed back so a caller can pass it to
`join` later — never `Suspended`: starting a thread is not
running one, so the caller of `start` itself is never blocked by
it, regardless of what the spawned body goes on to do.

`isGlobal` is threaded straight onto the resulting `Thread` record as a
bare marker — see that type's own doc for why this pass doesn't yet
define any actual difference in scheduling behavior for a global thread.
-}
start : Bool -> State -> List Value -> Result RuntimeError ( Value, State )
start isGlobal state args =
    case args of
        [ closure ] ->
            let
                threadId =
                    state.nextThreadId

                state1 =
                    { state | nextThreadId = threadId + 1 }
            in
            callFunction state1 closure []
                |> Result.map
                    (\( outcome, state2 ) ->
                        case outcome of
                            Done _ ->
                                ( VNumber (toFloat threadId), state2 )

                            Suspended waitCondition resume ->
                                ( VNumber (toFloat threadId)
                                , { state2
                                    | threads =
                                        Dict.insert threadId
                                            (Thread { waitCondition = waitCondition, elapsed = 0, resume = resume, isGlobal = isGlobal })
                                            state2.threads
                                  }
                                )
                    )

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| The once-per-frame scheduler step: advances every currently-suspended
thread's own wait condition by `dt` (seconds since the last `tick`),
resuming any whose condition is now satisfied. Each thread gets at most
one `resume` call per `tick`, never more, so a thread that resumes and
immediately suspends again on a condition that's *already* satisfied
still only advances one step this frame, picking up the rest on the next
`tick` instead of looping here.

A thread whose `resume` call errors is dropped from `threads` (there's
nothing sensible left to do with a thread whose own body raised a runtime
error) and its error is collected in the returned list, rather than
silently discarded or allowed to stop every *other* thread this frame
from being ticked too.

**The fold walks the `threads` snapshot taken when this `tick` started,
but a thread can be removed mid-pass** — `Thread.stop`, called by a
thread resumed earlier in the same pass. So each thread is first checked
against `stateAcc`'s own `threads`, and skipped if it's gone; otherwise
the `StillWaiting` branch would write a stopped thread straight back in,
or `ReadyToResume` would run it. The opposite case is deliberate: a
thread that stops *itself* (or its caller) while being resumed here is
re-registered at its next suspend, which is exactly what makes
`Thread.stop` a no-op on a running thread (see `Zak.Thread.stop`).

**Known, confirmed latency: `Thread.join` can resolve one full tick later
than the thread it's joining actually finishes, depending on thread-id
ordering.** `Dict.foldl` visits `threads` in ascending key order (=
creation order, since ids are a monotonic counter), all within this one
fold pass, and `checkWaitCondition`'s `ThreadRunning` case checks the
target's membership against `stateAcc` -- the *same in-progress*
accumulator. So: if the joining thread's own id is *lower* than the
target's (i.e. the joiner was created first -- an entirely ordinary
pattern, e.g. a long-running thread later joining on some shorter task it
spawns), it gets checked *before* the target is processed and removed
later in this same pass, and only notices the target is gone on the
*next* `tick` -- one extra frame of latency (~16ms at 60fps), never a
permanent stall. The opposite ordering (joiner id > target id) resolves
the same tick, since the target gets removed from `stateAcc` earlier in
the pass.

Left as-is deliberately (bounded, one-tick latency, real use is very
unlikely to notice it) -- if this ever needs fixing, resolve time-based
waits first in one pass, then re-check every `ThreadRunning` condition
against the now-settled `threads`, looping until stable within the same
`tick` call; alternatively, reconsider whether `join` should be a
first-class suspend primitive at all, versus exposing an
`is_running`-style boolean query and letting scripts build blocking on
it with a `wait_for` + poll loop.
-}
tick : Float -> State -> ( State, List RuntimeError )
tick dt state =
    Dict.foldl
        (\threadId (Thread thread) ( stateAcc, errorsAcc ) ->
            if not (Dict.member threadId stateAcc.threads) then
                ( stateAcc, errorsAcc )

            else
                case checkWaitCondition dt thread.elapsed thread.waitCondition stateAcc of
                    StillWaiting newElapsed ->
                        ( { stateAcc | threads = Dict.insert threadId (Thread { thread | elapsed = newElapsed }) stateAcc.threads }
                        , errorsAcc
                        )

                    ReadyToResume ->
                        case thread.resume stateAcc of
                            Ok ( Done _, state1 ) ->
                                ( { state1 | threads = Dict.remove threadId state1.threads }, errorsAcc )

                            Ok ( Suspended waitCondition resume, state1 ) ->
                                ( { state1
                                    | threads =
                                        Dict.insert threadId
                                            (Thread { waitCondition = waitCondition, elapsed = 0, resume = resume, isGlobal = thread.isGlobal })
                                            state1.threads
                                  }
                                , errorsAcc
                                )

                            Err error ->
                                ( { stateAcc | threads = Dict.remove threadId stateAcc.threads }, error :: errorsAcc )
        )
        ( state, [] )
        state.threads


{-| Hands back every `Effect` queued in `state.pendingEffects` since the
last `drainEffects` call, oldest first, and clears the queue. Two kinds
share the queue (see `Zak.Runtime`'s `Effect`): a `Log` from a
`Debug.log*` call (`Zak.Debug`) or an interpreter warning, and an
`Effect` from a host-specific native (defined by the embedder, outside
this package entirely, passed in as one of `initialWorld`'s own
`natives`). One queue keeps their relative order.

Same "call this yourself, repeatedly, threading `State` through" contract
`tick` already has for `threads`, not something that drains on its own.
Unlike `tick`, this never fails and never needs a `dt`: it's a plain
read-and-clear, not a scheduler step. The embedder is expected to call it
after every `run`/`runIncremental`/`call`/`tick` that could have run a
native, and turn each item into its own `Cmd` (a `Log` into a
`console.*` call via a port, say) — nothing in this module does that
itself, on purpose, and it never inspects an `Effect`'s name or arguments
(see `Zak.Runtime`'s own `pendingEffects` doc for why).
-}
drainEffects : State -> ( List Effect, State )
drainEffects state =
    ( state.pendingEffects, { state | pendingEffects = [] } )


type WaitCheck
    = StillWaiting Float
    | ReadyToResume


checkWaitCondition : Float -> Float -> WaitCondition -> State -> WaitCheck
checkWaitCondition dt elapsed waitCondition state =
    case waitCondition of
        Seconds seconds ->
            if elapsed + dt >= seconds then
                ReadyToResume

            else
                StillWaiting (elapsed + dt)

        ThreadRunning otherThreadId ->
            if Dict.member otherThreadId state.threads then
                StillWaiting elapsed

            else
                ReadyToResume


{-| `Array`/`Table`, always present in *every* entry point — including
`runExpr` — regardless of what `natives` supplies. Unlike `stdlibNatives`
above, this one's unconditional-everywhere status is a real technical
necessity, not a design choice: see this module's own top-of-file doc for
why.

`Array` is a small set sourced from Elm's own `Array` module (not Elm's
`List`) — `length`, `is_empty`, `get`, `get_default`, `set`, `push`,
`append`, `pop`, `contains`, `clone`, `each`, `map`, `indexed_map`,
`filter`, `foldl`, `foldr`.
Every function that mutates (`set`, `push`, `append`) always mutates — no
separate copy-returning sibling (see "Arrays" in the language reference
for the full rule).
`Array.remove`/`remove_value` was considered and deliberately deferred:
it's unclear whether it should remove the first matching value or every
matching value. `Table` covers what dot syntax structurally
can't (a field name that's a runtime value rather than a literal
identifier, `get`/`set`) plus a way to test/soften the hard error a
missing field raises (`contains`/`get_default`) — kept in lockstep with
`Array`'s own `contains`/`get_default`/`clone` rather than only fixing one
side. Neither `is_empty` nor `contains` uses the stdlib's older `?`-suffix
predicate convention — that convention is still valid Zak grammar for a
script's own functions, just no longer used by the stdlib itself (see
"Identifiers and reserved words" in the language reference).
-}
builtinNatives : Dict String NativeValue
builtinNatives =
    Dict.fromList
        [ ( "Array"
          , NativeNamespace
                (Dict.fromList
                    [ ( "length", NativeFunction arrayLength )
                    , ( "is_empty", NativeFunction arrayIsEmpty )
                    , ( "get", NativeFunction arrayGet )
                    , ( "get_default", NativeFunction arrayGetDefault )
                    , ( "set", NativeFunction arraySet )
                    , ( "push", NativeFunction arrayPush )
                    , ( "append", NativeFunction arrayAppend )
                    , ( "pop", NativeFunction arrayPop )
                    , ( "contains", NativeFunction arrayContains )
                    , ( "clone", NativeFunction arrayClone )
                    , ( "each", NativeFunction arrayEach )
                    , ( "map", NativeFunction arrayMap )
                    , ( "indexed_map", NativeFunction arrayIndexedMap )
                    , ( "filter", NativeFunction arrayFilter )
                    , ( "foldl", NativeFunction arrayFoldl )
                    , ( "foldr", NativeFunction arrayFoldr )
                    , ( "range", NativeFunction arrayRange )
                    ]
                )
          )
        , ( "Table"
          , NativeNamespace
                (Dict.fromList
                    [ ( "get", NativeFunction tableGet )
                    , ( "get_default", NativeFunction tableGetDefault )
                    , ( "set", NativeFunction tableSet )
                    , ( "contains", NativeFunction tableContains )
                    , ( "clone", NativeFunction tableClone )
                    , ( "each", NativeFunction tableEach )
                    ]
                )
          )
        ]


{-| Resolves a whole `Dict String NativeValue` into the `Dict String Value`
that actually gets seeded into a scope frame — threading `State` through so
each `NativeNamespace` along the way can allocate its own heap cell.
-}
resolveNatives : State -> Dict String NativeValue -> ( Dict String Value, State )
resolveNatives state natives =
    Dict.foldl
        (\name native ( acc, st ) ->
            case resolveNative st native of
                ( Just value, st1 ) ->
                    ( Dict.insert name value acc, st1 )

                ( Nothing, st1 ) ->
                    ( acc, st1 )
        )
        ( Dict.empty, state )
        natives


resolveNative : State -> NativeValue -> ( Maybe Value, State )
resolveNative state native =
    case native of
        NativeFunction fn ->
            ( Just (VNative fn), state )

        NativeThreadFunction fn ->
            ( Just (VNativeThread fn), state )

        NativeNamespace fields ->
            let
                ( resolvedFields, state1 ) =
                    resolveNatives state fields

                ( id, state2 ) =
                    allocCell state1
            in
            ( Just (VTable id), { state2 | heap = Dict.insert id resolvedFields state2.heap } )

        NativeZakExpr source ->
            -- `source` is fixed Zak source written alongside a native
            -- (e.g. in Zak.Math, or by the host), not script input. If it
            -- fails to parse or evaluate, that native is simply left
            -- undefined (`Nothing`): a script calling it gets the usual
            -- `UndefinedName`, rather than threading another error case
            -- through every caller of `run`/`runExpr` for a bug in the
            -- native's own source. Evaluating a self-contained function
            -- literal here (before frame 0 is fully populated) is safe:
            -- it only captures `globalEnv`, it doesn't look anything up
            -- in it until the function is actually called later.
            case Parser.parseExpr source of
                Err _ ->
                    ( Nothing, state )

                Ok expr ->
                    case evalExpr globalEnv state expr of
                        Ok ( value, state1 ) ->
                            ( Just value, state1 )

                        Err _ ->
                            ( Nothing, state )

        NativeConstant value ->
            ( Just value, state )



{-| The value a block's final signal stands for. A `break`/`continue` can
never get this far (the parser only accepts them inside a `while`/`for`
body, and the loop absorbs them), so those two are an `InternalError`,
an interpreter bug, rather than a made-up value.
-}
signalValue : Signal -> Result RuntimeError Value
signalValue signal =
    case signal of
        Returning value ->
            Ok value

        Normal ->
            Ok VNil

        Breaking ->
            Err (InternalError "a break signal escaped its enclosing loop: the parser only accepts break inside a while/for body")

        Continuing ->
            Err (InternalError "a continue signal escaped its enclosing loop: the parser only accepts continue inside a while/for body")



-- STATEMENTS / BLOCKS


{-| Runs a `Block` in its own fresh scope frame, chained under `parentEnv` —
this is the one place a new scope gets created, used uniformly for an `if`
branch, a `while` body, a function call, and the top-level program alike.
-}
execBlock : Env -> State -> Block -> Result RuntimeError ( Outcome Signal, State )
execBlock parentEnv state statements =
    let
        ( frameId, state1 ) =
            allocCell state
    in
    execStatements (Env frameId (Just parentEnv)) state1 statements


{-| Runs each statement in turn, tagging any `RuntimeError` that comes out
of it with *that statement's own* position (`Zak.Runtime.WithPosition`, via
`tagPosition` below) before it propagates any further — the one place in
this whole module position-tagging happens at all. Because this function
is exactly what runs recursively for every nested block too (an `if`
branch, a `while`/`for` body, a function call's body — see `execBlock`),
a statement failing ten calls deep still gets tagged with its own real
position, by the innermost `execStatements` call to ever see the error,
*before* it bubbles up through every enclosing one — each of which also
calls `tagPosition`, but `tagPosition` is a deliberate no-op on an
already-tagged error, so the innermost, most useful position is the one
that survives, not the outermost/least specific one.
-}
execStatements : Env -> State -> Block -> Result RuntimeError ( Outcome Signal, State )
execStatements env state statements =
    case statements of
        [] ->
            Ok ( Done Normal, state )

        positioned :: rest ->
            execStatement env state positioned.statement
                |> Result.mapError (tagPosition positioned.position)
                |> andThenOutcome
                    (\signal state1 ->
                        case signal of
                            Normal ->
                                execStatements env state1 rest

                            -- Returning/Breaking/Continuing all stop the
                            -- rest of *this* block from running and
                            -- propagate up unchanged — it's whatever calls
                            -- execBlock (execWhile, callFunction, ...) that
                            -- decides whether to absorb it or keep
                            -- propagating it further.
                            _ ->
                                Ok ( Done signal, state1 )
                    )


{-| Wraps `error` in `WithPosition position error` — but only if it isn't
already wrapped. This is what makes "the innermost failure's position
wins" in `execStatements` above actually true: without the guard, every
enclosing `execStatements` call would re-wrap an already-positioned error
with its *own*, less specific position on the way back up, and the
outermost statement in the whole call chain would win instead of the one
that actually failed.
-}
tagPosition : Position -> RuntimeError -> RuntimeError
tagPosition position error =
    case error of
        WithPosition _ _ ->
            error

        _ ->
            WithPosition position error


{-| Every case but the last (`ExprStatement (Call ...)`) can never itself
suspend, so it just runs to `Done` immediately, same as before this module
supported suspension at all. Only a bare top-level call statement can
actually preserve and propagate a `Suspended` result — see
`Zak.Runtime.Outcome`'s own doc for why that's the one place this pass
wires it up, and `evalExpr`'s `Call` case (used by every *other* case
here, via `evalExpr`) for what happens if a suspending native is called
from anywhere else instead (a `SuspendedNotAllowed` error, not silent
wrong behavior).
-}
execStatement : Env -> State -> Statement -> Result RuntimeError ( Outcome Signal, State )
execStatement env state statement =
    case statement of
        Let "_" valueExpr ->
            discard env state valueExpr

        Const "_" valueExpr ->
            discard env state valueExpr

        Let name valueExpr ->
            evalExpr env state valueExpr
                |> Result.andThen (\( value, state1 ) -> defineVar env state1 name value)
                |> Result.map (\state1 -> ( Done Normal, warnIfShadowsConst env name state1 ))

        Const name valueExpr ->
            evalExpr env state valueExpr
                |> Result.andThen (\( value, state1 ) -> defineVar env state1 name value)
                |> Result.map (\state1 -> ( Done Normal, markConst env (warnIfShadowsConst env name state1) name ))

        Assign target rhsExpr ->
            evalExpr env state rhsExpr
                |> Result.andThen (\( value, state1 ) -> execAssign env state1 target value)
                |> Result.map (\state1 -> ( Done Normal, state1 ))

        If condExpr thenBlock maybeElseBlock ->
            evalExpr env state condExpr
                |> Result.andThen
                    (\( condValue, state1 ) ->
                        case condValue of
                            VBool True ->
                                execBlock env state1 thenBlock

                            VBool False ->
                                case maybeElseBlock of
                                    Just elseBlock ->
                                        execBlock env state1 elseBlock

                                    Nothing ->
                                        Ok ( Done Normal, state1 )

                            _ ->
                                Err (TypeError { expected = "Bool", got = condValue })
                    )

        While condExpr body ->
            execWhile env state condExpr body

        For loopVar collectionExpr body ->
            execFor env state loopVar collectionExpr body

        Break ->
            Ok ( Done Breaking, state )

        Continue ->
            Ok ( Done Continuing, state )

        Return maybeExpr ->
            case maybeExpr of
                Nothing ->
                    Ok ( Done (Returning VNil), state )

                Just returnExpr ->
                    evalExpr env state returnExpr
                        |> Result.map (\( value, state1 ) -> ( Done (Returning value), state1 ))

        ExprStatement (Call calleeExpr argExprs) ->
            evalExpr env state calleeExpr
                |> Result.andThen
                    (\( calleeValue, state1 ) ->
                        evalExprList env state1 argExprs
                            |> Result.andThen
                                (\( argValues, state2 ) ->
                                    callFunction state2 calleeValue argValues
                                        |> Result.map (\( outcome, state3 ) -> ( mapOutcome (\_ -> Normal) outcome, state3 ))
                                )
                    )

        ExprStatement valueExpr ->
            evalExpr env state valueExpr
                |> Result.map (\( _, state1 ) -> ( Done Normal, state1 ))


execWhile : Env -> State -> Expr -> Block -> Result RuntimeError ( Outcome Signal, State )
execWhile env state condExpr body =
    evalExpr env state condExpr
        |> Result.andThen
            (\( condValue, state1 ) ->
                case condValue of
                    VBool True ->
                        execBlock env state1 body
                            |> andThenOutcome
                                (\signal state2 ->
                                    case signal of
                                        Returning _ ->
                                            -- propagates past this loop, all the way to the
                                            -- enclosing function call (or the top level)
                                            Ok ( Done signal, state2 )

                                        Breaking ->
                                            -- absorbed here: stop looping, resume normally
                                            -- with whatever comes after this while statement
                                            Ok ( Done Normal, state2 )

                                        -- Continuing and Normal do the same thing at this
                                        -- point: the body already stopped early (Continuing)
                                        -- or ran to completion (Normal), either way it's time
                                        -- to re-check the condition and possibly loop again
                                        _ ->
                                            execWhile env state2 condExpr body
                                )

                    VBool False ->
                        Ok ( Done Normal, state1 )

                    _ ->
                        Err (TypeError { expected = "Bool", got = condValue })
            )


{-| `let _ = expr` / `const _ = expr`: evaluates `expr` for its effects
and throws the value away. Nothing is bound, so repeating it in the same
scope is never `AlreadyDefined`, and the parser already rejects any read
of `_` (`Zak.Parser.rejectThrowaway`).
-}
discard : Env -> State -> Expr -> Result RuntimeError ( Outcome Signal, State )
discard env state valueExpr =
    evalExpr env state valueExpr
        |> Result.map (\( _, state1 ) -> ( Done Normal, state1 ))


{-| Drops the throwaway name `_` from a list of fresh bindings (a call's
parameters), so it's never stored in a frame.
-}
withoutThrowaway : List ( String, Value ) -> List ( String, Value )
withoutThrowaway =
    List.filter (\( name, _ ) -> name /= "_")


{-| `for loopVar in collectionExpr: ... end` — `collectionExpr` is evaluated
once, up front, to fix *which* array is being iterated (re-evaluating it
every pass isn't something most dynamic languages do either); iteration
itself is live, per `execForLoop` below.
-}
execFor : Env -> State -> String -> Expr -> Block -> Result RuntimeError ( Outcome Signal, State )
execFor env state loopVar collectionExpr body =
    evalExpr env state collectionExpr
        |> Result.andThen
            (\( collectionValue, state1 ) ->
                case collectionValue of
                    VArray id ->
                        execForLoop env state1 loopVar id body 0

                    _ ->
                        Err (TypeError { expected = "Array", got = collectionValue })
            )


{-| Live iteration: re-reads the array's *current* contents from `arrayHeap`
on every pass (rather than a snapshot taken once at loop start), so a
`push`/`set` from within the body is visible to later iterations, as in
most dynamic languages. A deliberately revisitable choice, not a
permanent one.

Each pass gets a *fresh* frame holding just `loopVar` (mirroring how
`callFunction` binds parameters in their own frame before running the
body), with `execBlock` then giving the body itself its own nested frame
underneath that — so a `let` inside the body never collides with `loopVar`,
the same separation a function's own parameters and its body's `let`s have.
-}
execForLoop : Env -> State -> String -> Int -> Block -> Int -> Result RuntimeError ( Outcome Signal, State )
execForLoop env state loopVar id body index =
    let
        contents =
            arrayContents state id
    in
    if index >= Array.length contents then
        Ok ( Done Normal, state )

    else
        case Array.get index contents of
            Nothing ->
                -- unreachable: index < Array.length contents was just checked
                Ok ( Done Normal, state )

            Just element ->
                let
                    ( frameId, state1 ) =
                        allocCell state

                    loopVarEnv =
                        Env frameId (Just env)

                    state2 =
                        { state1 | heap = Dict.insert frameId (Dict.fromList (withoutThrowaway [ ( loopVar, element ) ])) state1.heap }
                in
                execBlock loopVarEnv state2 body
                    |> andThenOutcome
                        (\signal state3 ->
                            case signal of
                                Returning _ ->
                                    Ok ( Done signal, state3 )

                                Breaking ->
                                    Ok ( Done Normal, state3 )

                                _ ->
                                    execForLoop env state3 loopVar id body (index + 1)
                        )


{-| `Taylor.a.b.c = 99` (an `AssignTarget (Name "Taylor") [ FieldSegment
"a", ... ]`) or `matrix[0][1] = 99` (`IndexSegment` steps), freely mixed
(`Taylor.items[0] = key`): with no path, this is a bare-name reassignment
(only ever reachable when `base` is a `Name`, per `exprToAssignTarget`'s
own invariant — nothing else parses with an empty path); with one, every
step but the last must already resolve to the right kind of value to take
the *next* step on (a table for a `.field` step, an array for a `[index]`
step — no auto-vivification of these intermediate steps, see "Tables" in
the reference manual). The *last* step is different for a `.field` step
specifically: it creates the field if it doesn't already exist, the same
targeted-edit-mutates rule `Array.set`/`Array.push` already follow, rather
than requiring it to already be there — a last `[index]` step still has to
be in-bounds, though, since arrays don't grow via assignment (only via
`Array.push`).

`base` is resolved via `evalExpr`, not a bare `lookupVar`, so a path
assignment's own base can be *any* expression, not just a name —
`current_player().health = 100` resolves `current_player()` like any
other call before writing through it (see `AssignTarget`'s own doc in
`Zak.AST`). For the plain `Name` case this is
no behavior change at all: `evalExpr`'s own `Name` branch is exactly
`lookupVar` plus the same `UndefinedName` wrapping this used to do by
hand.
-}
execAssign : Env -> State -> AssignTarget -> Value -> Result RuntimeError State
execAssign env state (AssignTarget base segments) value =
    case ( base, segments ) of
        ( Name name, [] ) ->
            assignVar env state name value

        _ ->
            evalExpr env state base
                |> Result.andThen (\( baseValue, state1 ) -> setPath env state1 baseValue segments value)


setPath : Env -> State -> Value -> List PathSegment -> Value -> Result RuntimeError State
setPath env state target segments value =
    case segments of
        [ FieldSegment field ] ->
            setTableField state target field value

        FieldSegment field :: rest ->
            getTableField state target field
                |> Result.andThen (\innerValue -> setPath env state innerValue rest value)

        [ IndexSegment indexExpr ] ->
            evalExpr env state indexExpr
                |> Result.andThen
                    (\( indexValue, state1 ) -> setArrayIndex state1 target indexValue value)

        IndexSegment indexExpr :: rest ->
            evalExpr env state indexExpr
                |> Result.andThen
                    (\( indexValue, state1 ) ->
                        getArrayIndex state1 target indexValue
                            |> Result.andThen (\innerValue -> setPath env state1 innerValue rest value)
                    )

        [] ->
            -- unreachable: execAssign only calls setPath with a non-empty
            -- segment list (an empty one is a bare-name assignment,
            -- handled directly by execAssign without involving this
            -- function at all).
            Err (TypeError { expected = "Array or Table", got = target })


{-| Converts a Zak `Number` to the `Int` an array index needs — but only if
it already has no fractional part. Zak has no separate Integer type, so
`2.0` and `2` are indistinguishable (both are just the `Float` value
`2.0`) and pass through fine, but a genuinely fractional value like `2.5`
is a `NotAnInteger` error rather than being silently rounded or truncated
to a neighboring slot: a stray fractional value reaching an index is far
more likely to be an arithmetic mistake (`/` where `//` was meant) than a
deliberate choice.
-}
wholeNumberIndex : Float -> Result RuntimeError Int
wholeNumberIndex indexFloat =
    let
        rounded =
            round indexFloat
    in
    if toFloat rounded == indexFloat then
        Ok rounded

    else
        Err (NotAnInteger { index = indexFloat })


{-| Shared by the `[index]` assignment-target step above, the `Index`
expression case below, *and* the `Array.get`/`Array.set` natives further
down — not just the same bounds-check and error, the literal same
function: `[index]`/`[index] = value` and `Array.get`/`Array.set` are two
spellings of the exact same operation (see this module's own doc for why
that sharing lives here rather than in a separate module).
-}
getArrayIndex : State -> Value -> Value -> Result RuntimeError Value
getArrayIndex state target indexValue =
    case ( target, indexValue ) of
        ( VArray id, VNumber indexFloat ) ->
            wholeNumberIndex indexFloat
                |> Result.andThen
                    (\index ->
                        let
                            contents =
                                arrayContents state id
                        in
                        case Array.get index contents of
                            Just value ->
                                Ok value

                            Nothing ->
                                Err (IndexOutOfBounds { index = indexFloat, length = Array.length contents })
                    )

        ( VArray _, _ ) ->
            Err (TypeError { expected = "Number", got = indexValue })

        ( _, _ ) ->
            Err (TypeError { expected = "Array", got = target })


setArrayIndex : State -> Value -> Value -> Value -> Result RuntimeError State
setArrayIndex state target indexValue value =
    case ( target, indexValue ) of
        ( VArray id, VNumber indexFloat ) ->
            wholeNumberIndex indexFloat
                |> Result.andThen
                    (\index ->
                        let
                            contents =
                                arrayContents state id
                        in
                        if index >= 0 && index < Array.length contents then
                            Ok { state | arrayHeap = Dict.insert id (Array.set index value contents) state.arrayHeap }

                        else
                            Err (IndexOutOfBounds { index = indexFloat, length = Array.length contents })
                    )

        ( VArray _, _ ) ->
            Err (TypeError { expected = "Number", got = indexValue })

        ( _, _ ) ->
            Err (TypeError { expected = "Array", got = target })


{-| Shared by the `.field`/assignment-target step above, the `FieldAccess`
expression case below, *and* the `Table.get`/`Table.set` natives further
down — same relationship `getArrayIndex`/`setArrayIndex` have with
`Array.get`/`Array.set`: not just the same error, the literal same
function.
-}
getTableField : State -> Value -> String -> Result RuntimeError Value
getTableField state target field =
    case target of
        VTable id ->
            Dict.get id state.heap
                |> Maybe.andThen (Dict.get field)
                |> Result.fromMaybe (UndefinedField field)

        _ ->
            Err (NotATable target field)


setTableField : State -> Value -> String -> Value -> Result RuntimeError State
setTableField state target field value =
    case target of
        VTable id ->
            let
                tableFields =
                    Dict.get id state.heap |> Maybe.withDefault Dict.empty
            in
            Ok { state | heap = Dict.insert id (Dict.insert field value tableFields) state.heap }

        _ ->
            Err (NotATable target field)



-- EXPRESSIONS


evalExpr : Env -> State -> Expr -> Result RuntimeError ( Value, State )
evalExpr env state expression =
    case expression of
        StringLiteral s ->
            Ok ( VString s, state )

        NumberLiteral n ->
            Ok ( VNumber n, state )

        Name name ->
            lookupVar env state name
                |> Result.fromMaybe (UndefinedName name)
                |> Result.map (\value -> ( value, state ))

        ArrayLiteral items ->
            evalExprList env state items
                |> Result.map
                    (\( values, state1 ) ->
                        let
                            ( id, state2 ) =
                                allocArrayCell state1 (Array.fromList values)
                        in
                        ( VArray id, state2 )
                    )

        TableLiteral fields ->
            evalFieldExprs env state fields
                |> Result.map
                    (\( fieldValues, state1 ) ->
                        let
                            ( id, state2 ) =
                                allocCell state1
                        in
                        ( VTable id, { state2 | heap = Dict.insert id (Dict.fromList fieldValues) state2.heap } )
                    )

        FunctionLiteral params body ->
            Ok ( VFunction params body env, state )

        FieldAccess targetExpr field ->
            evalExpr env state targetExpr
                |> Result.andThen
                    (\( targetValue, state1 ) ->
                        getTableField state1 targetValue field
                            |> Result.map (\value -> ( value, state1 ))
                    )

        Index targetExpr indexExpr ->
            evalExpr env state targetExpr
                |> Result.andThen
                    (\( targetValue, state1 ) ->
                        evalExpr env state1 indexExpr
                            |> Result.andThen
                                (\( indexValue, state2 ) ->
                                    getArrayIndex state2 targetValue indexValue
                                        |> Result.map (\value -> ( value, state2 ))
                                )
                    )

        Call calleeExpr argExprs ->
            -- A suspend from here can't go anywhere (this is a nested
            -- expression, not a bare top-level statement -- see
            -- `execStatement`'s `ExprStatement (Call ...)` case, the one
            -- place that *can* propagate one), so `requireDone` turns an
            -- unexpected `Suspended` into a clear error instead of being
            -- silently dropped.
            evalExpr env state calleeExpr
                |> Result.andThen
                    (\( calleeValue, state1 ) ->
                        evalExprList env state1 argExprs
                            |> Result.andThen
                                (\( argValues, state2 ) ->
                                    callFunction state2 calleeValue argValues
                                        |> Result.andThen
                                            (\( outcome, state3 ) ->
                                                requireDone outcome |> Result.map (\value -> ( value, state3 ))
                                            )
                                )
                    )

        Unary op operandExpr ->
            evalExpr env state operandExpr
                |> Result.andThen
                    (\( operandValue, state1 ) ->
                        evalUnary op operandValue |> Result.map (\result -> ( result, state1 ))
                    )

        Binary And leftExpr rightExpr ->
            evalShortCircuit env state False leftExpr rightExpr

        Binary Or leftExpr rightExpr ->
            evalShortCircuit env state True leftExpr rightExpr

        Binary In leftExpr rightExpr ->
            evalExpr env state leftExpr
                |> Result.andThen
                    (\( leftValue, state1 ) ->
                        evalExpr env state1 rightExpr
                            |> Result.andThen
                                (\( rightValue, state2 ) ->
                                    evalIn state2 leftValue rightValue |> Result.map (\result -> ( result, state2 ))
                                )
                    )

        Binary op leftExpr rightExpr ->
            evalExpr env state leftExpr
                |> Result.andThen
                    (\( leftValue, state1 ) ->
                        evalExpr env state1 rightExpr
                            |> Result.andThen
                                (\( rightValue, state2 ) ->
                                    evalBinary op leftValue rightValue |> Result.map (\result -> ( result, state2 ))
                                )
                    )


{-| `and`/`or` short-circuit: the right operand is only evaluated if the
left one didn't already decide the answer. `shortCircuitsOn` is the Bool
value that stops evaluation early (`False` for `and`, `True` for `or`).
-}
evalShortCircuit : Env -> State -> Bool -> Expr -> Expr -> Result RuntimeError ( Value, State )
evalShortCircuit env state shortCircuitsOn leftExpr rightExpr =
    evalExpr env state leftExpr
        |> Result.andThen
            (\( leftValue, state1 ) ->
                case leftValue of
                    VBool b ->
                        if b == shortCircuitsOn then
                            Ok ( VBool b, state1 )

                        else
                            evalExpr env state1 rightExpr
                                |> Result.andThen
                                    (\( rightValue, state2 ) ->
                                        case rightValue of
                                            VBool _ ->
                                                Ok ( rightValue, state2 )

                                            _ ->
                                                Err (TypeError { expected = "Bool", got = rightValue })
                                    )

                    _ ->
                        Err (TypeError { expected = "Bool", got = leftValue })
            )


evalExprList : Env -> State -> List Expr -> Result RuntimeError ( List Value, State )
evalExprList env state exprs =
    case exprs of
        [] ->
            Ok ( [], state )

        first :: rest ->
            evalExpr env state first
                |> Result.andThen
                    (\( value, state1 ) ->
                        evalExprList env state1 rest
                            |> Result.map (\( values, state2 ) -> ( value :: values, state2 ))
                    )


evalFieldExprs : Env -> State -> List ( String, Expr ) -> Result RuntimeError ( List ( String, Value ), State )
evalFieldExprs env state fields =
    case fields of
        [] ->
            Ok ( [], state )

        ( name, valueExpr ) :: rest ->
            evalExpr env state valueExpr
                |> Result.andThen
                    (\( value, state1 ) ->
                        evalFieldExprs env state1 rest
                            |> Result.map (\( values, state2 ) -> ( ( name, value ) :: values, state2 ))
                    )


{-| Evaluates the default expression for each parameter past the args a
call actually supplied (`callFunction`'s `VFunction` branch passes only
the trailing slice here, once positional binding has already claimed the
rest) — evaluated against `env`, the function's own captured *enclosing*
scope, never the call frame being built for this call. Two consequences,
both deliberate:

  - A default can't reference an earlier parameter (`function(a, b=a):
    ...`) — there's no call frame in scope yet at this point, only the
    enclosing one.
  - Evaluating fresh here, on every call that needs it, rather than once
    when the `VFunction` was first created, is what keeps a mutable
    default (`baz=[]`) an independent value per call rather than one
    shared instance mutated in place across all of them — avoiding the
    classic mutable-default-argument gotcha.

The `Nothing` branch is unreachable in practice: `Zak.Parser`'s
trailing-only-defaults rule guarantees every parameter past a supplied
argument has a default. Falls back to `VNil` rather than crashing if
that guarantee were somehow ever violated.
-}
evalDefaultArgs : Env -> State -> List ( String, Maybe Expr ) -> Result RuntimeError ( List ( String, Value ), State )
evalDefaultArgs env state remainingParams =
    case remainingParams of
        [] ->
            Ok ( [], state )

        ( name, Nothing ) :: rest ->
            evalDefaultArgs env state rest
                |> Result.map (\( values, state1 ) -> ( ( name, VNil ) :: values, state1 ))

        ( name, Just defaultExpr ) :: rest ->
            evalExpr env state defaultExpr
                |> Result.andThen
                    (\( value, state1 ) ->
                        evalDefaultArgs env state1 rest
                            |> Result.map (\( values, state2 ) -> ( ( name, value ) :: values, state2 ))
                    )


{-| True for a parameter with no default — the ones a call must always
supply. Used by `callFunction`'s `VFunction` branch to compute the
minimum arity a call must meet, alongside `List.length params` itself
for the maximum.
-}
isRequiredParam : ( String, Maybe Expr ) -> Bool
isRequiredParam ( _, default ) =
    case default of
        Nothing ->
            True

        Just _ ->
            False


{-| Calling a plain `VNative` or a `VFunction` whose body never suspends
both just produce `Done value` immediately, same as before this module
supported suspension at all — the only genuinely new case is `VNativeThread`
(`wait_for`/`join`, see `Zak.Thread`),
which can hand back `Suspended` directly, and a `VFunction` whose *body*
suspends (because it itself calls one of those, as its own top-level
statement — see `execStatement`'s `ExprStatement (Call ...)` case), whose
`Outcome Signal` from running the body is mapped to the `Outcome Value`
this function itself promises via `signalValue`/`mapOutcome`.
-}
callFunction : State -> Value -> List Value -> Result RuntimeError ( Outcome Value, State )
callFunction state callee args =
    case callee of
        VNative fn ->
            fn state args |> Result.map (\( value, state1 ) -> ( Done value, state1 ))

        VNativeThread fn ->
            fn state args

        VFunction params body closureEnv ->
            let
                minArity =
                    List.length (List.filter isRequiredParam params)

                maxArity =
                    List.length params

                got =
                    List.length args
            in
            if got < minArity then
                Err (WrongArgCount { expected = minArity, got = got })

            else if got > maxArity then
                Err (WrongArgCount { expected = maxArity, got = got })

            else
                let
                    suppliedArgs =
                        List.map2 (\( name, _ ) value -> ( name, value )) (List.take got params) args

                    remainingParams =
                        List.drop got params
                in
                evalDefaultArgs closureEnv state remainingParams
                    |> Result.andThen
                        (\( defaultedArgs, state1 ) ->
                            let
                                ( frameId, state2 ) =
                                    allocCell state1

                                callEnv =
                                    Env frameId (Just closureEnv)

                                state3 =
                                    { state2 | heap = Dict.insert frameId (Dict.fromList (withoutThrowaway (suppliedArgs ++ defaultedArgs))) state2.heap }
                            in
                            execBlock callEnv state3 body
                                |> Result.andThen (\( outcome, state4 ) -> mapOutcomeResult signalValue outcome |> Result.map (\mapped -> ( mapped, state4 )))
                        )

        _ ->
            Err (NotAFunction callee)


evalUnary : UnaryOp -> Value -> Result RuntimeError Value
evalUnary op value =
    case ( op, value ) of
        ( Negate, VNumber n ) ->
            Ok (VNumber -n)

        ( Negate, _ ) ->
            Err (TypeError { expected = "Number", got = value })

        ( Not, VBool b ) ->
            Ok (VBool (not b))

        ( Not, _ ) ->
            Err (TypeError { expected = "Bool", got = value })


evalBinary : BinaryOp -> Value -> Value -> Result RuntimeError Value
evalBinary op left right =
    case op of
        Add ->
            numberOp (+) left right

        Sub ->
            numberOp (-) left right

        Mul ->
            numberOp (*) left right

        Div ->
            checkedDivide "/" (/) left right

        FloorDiv ->
            checkedDivide "//" (\a b -> toFloat (floor (a / b))) left right

        Concat ->
            stringOp (++) left right

        Eq ->
            Ok (VBool (valuesEqual left right))

        NotEq ->
            Ok (VBool (not (valuesEqual left right)))

        Gt ->
            orderedCompare (>) (>) left right

        Lt ->
            orderedCompare (<) (<) left right

        GtEq ->
            orderedCompare (>=) (>=) left right

        LtEq ->
            orderedCompare (<=) (<=) left right

        And ->
            boolOp (&&) left right

        Or ->
            boolOp (||) left right

        In ->
            -- `Binary In` is always intercepted by `evalExpr` before
            -- reaching here (see its own case there) -- unlike `And`/
            -- `Or`, which *could* be implemented for real in terms of
            -- `Value`s alone (and are, above, if anything else ever did
            -- reach them this way), `in` genuinely can't be: resolving
            -- its right operand's contents needs `State`, which this
            -- function's own signature has no room for. See `evalIn`.
            Err (InternalError "Binary In is handled directly in evalExpr (needs State) -- see evalIn")


{-| `x in y` — sugar for `Array.contains`/`Table.contains`, matching
whichever container `y` actually is; reuses their exact logic via
`arrayHasValue`/`tableHasField` below, not a separate reimplementation
("not just the same error, the literal same function," the same relationship
`getArrayIndex`/`getTableField` already have with `Array.get`/`Table.get`).
A right-hand side that's neither an `Array` nor a `Table` is a hard
`TypeError` rather than silently `false`; every other operator/native in
Zak already refuses that kind of silent tolerance.
-}
evalIn : State -> Value -> Value -> Result RuntimeError Value
evalIn state left right =
    case right of
        VArray id ->
            Ok (VBool (arrayHasValue state id left))

        VTable id ->
            case left of
                VString name ->
                    Ok (VBool (tableHasField state id name))

                other ->
                    Err (TypeError { expected = "String", got = other })

        other ->
            Err (TypeError { expected = "Array or Table", got = other })


numberOp : (Float -> Float -> Float) -> Value -> Value -> Result RuntimeError Value
numberOp f left right =
    case ( left, right ) of
        ( VNumber a, VNumber b ) ->
            Ok (VNumber (f a b))

        ( VNumber _, _ ) ->
            Err (TypeError { expected = "Number", got = right })

        _ ->
            Err (TypeError { expected = "Number", got = left })


{-| Like `numberOp`, but for `/` and `//` specifically: a zero divisor is a
`DivisionByZero` runtime error rather than silently producing `Infinity` or
`NaN` — which matters beyond just this operator, since `NaN` famously isn't
even equal to itself (`NaN == NaN` is `False`, per IEEE 754), which would
otherwise make `valuesEqual` behave surprisingly for any number derived from
a division by zero. Note this can't be written as a `0` pattern match — Elm
doesn't allow pattern-matching a `Float` literal — so it's an explicit `==`
check instead.
-}
checkedDivide : String -> (Float -> Float -> Float) -> Value -> Value -> Result RuntimeError Value
checkedDivide operator f left right =
    case ( left, right ) of
        ( VNumber a, VNumber b ) ->
            if b == 0 then
                Err (DivisionByZero (String.fromFloat a ++ " " ++ operator ++ " 0 is undefined"))

            else
                Ok (VNumber (f a b))

        ( VNumber _, _ ) ->
            Err (TypeError { expected = "Number", got = right })

        _ ->
            Err (TypeError { expected = "Number", got = left })


{-| `>`/`<`/`>=`/`<=` on two `Number`s or two `String`s. `numCmp`/`strCmp`
here are Elm's own `(>)`/`(<)`/`(>=)`/`(<=)`, passed in twice (once
instantiated at `Float`, once at `String`) rather than anything hand-written
— Elm's `String` already has a real, built-in lexicographic order (the same
one `List.sort`/`compare` rely on elsewhere in `elm/core`), so ordering two
`VString`s needs nothing beyond calling it directly on the two extracted
Elm `String`s, exactly the same pattern `( VNumber a, VNumber b )` below
already uses for `Float`. Deliberately *not* named `numberCompare` anymore
now that it covers two types.

Ordering is defined for exactly these two — see "Comparison operators" in
the language reference for why `Bool`/`Nil`/every cross-type pairing
(`Number` vs `String` included) stays a hard `TypeError` rather than being
given invented semantics: only numeric and string ordering are
well-defined and deterministic.
-}
orderedCompare :
    (Float -> Float -> Bool)
    -> (String -> String -> Bool)
    -> Value
    -> Value
    -> Result RuntimeError Value
orderedCompare numCmp strCmp left right =
    case ( left, right ) of
        ( VNumber a, VNumber b ) ->
            Ok (VBool (numCmp a b))

        ( VNumber _, _ ) ->
            Err (TypeError { expected = "Number", got = right })

        ( VString a, VString b ) ->
            Ok (VBool (strCmp a b))

        ( VString _, _ ) ->
            Err (TypeError { expected = "String", got = right })

        _ ->
            Err (TypeError { expected = "Number or String", got = left })


stringOp : (String -> String -> String) -> Value -> Value -> Result RuntimeError Value
stringOp f left right =
    case ( left, right ) of
        ( VString a, VString b ) ->
            Ok (VString (f a b))

        ( VString _, _ ) ->
            Err (TypeError { expected = "String", got = right })

        _ ->
            Err (TypeError { expected = "String", got = left })


boolOp : (Bool -> Bool -> Bool) -> Value -> Value -> Result RuntimeError Value
boolOp f left right =
    case ( left, right ) of
        ( VBool a, VBool b ) ->
            Ok (VBool (f a b))

        ( VBool _, _ ) ->
            Err (TypeError { expected = "Bool", got = right })

        _ ->
            Err (TypeError { expected = "Bool", got = left })


{-| A hand-written equality, rather than Elm's own `==`, because a `Value`
can hold a raw Elm function (`VNative`) — comparing one of those with `==`
crashes at runtime. `VTable` and `VArray` both compare by heap id
(reference identity, matching how a mutable-in-place value is meant to
behave: "are these the same object", not "do they currently hold equal
contents") — two separately-built arrays with identical elements are *not*
`==` to one another, only an array compared against itself (reached
through two different names, say) is, the same rule tables already
follow. Two function values (`VFunction`/`VNative`) are never considered
equal to one another, even to themselves — Zak doesn't give functions an
identity to compare.
-}
valuesEqual : Value -> Value -> Bool
valuesEqual a b =
    case ( a, b ) of
        ( VString x, VString y ) ->
            x == y

        ( VNumber x, VNumber y ) ->
            x == y

        ( VBool x, VBool y ) ->
            x == y

        ( VNil, VNil ) ->
            True

        ( VArray x, VArray y ) ->
            x == y

        ( VTable x, VTable y ) ->
            x == y

        _ ->
            False



-- ENVIRONMENT / HEAP


{-| Exposed (unlike most of this module's own internals) so an
embedder's own natives can build an ad-hoc nested `VTable` from Elm data
-- e.g. constructing a `{x=,y=}` table to stamp onto some existing
table. Every other `NativeFunction` that needs a fresh table cell
(`NativeNamespace`'s own resolution, for one) already reaches this same function from inside this module; this just
widens who else can.
-}
allocCell : State -> ( Int, State )
allocCell state =
    ( state.nextId, { state | heap = Dict.insert state.nextId Dict.empty state.heap, nextId = state.nextId + 1 } )


{-| Like `allocCell`, but for a new `VArray` cell in `arrayHeap` — takes
its initial contents directly, since (unlike a frame or a fresh table)
an array is never allocated empty-then-filled-in.
-}
allocArrayCell : State -> Array Value -> ( Int, State )
allocArrayCell state contents =
    ( state.nextId, { state | arrayHeap = Dict.insert state.nextId contents state.arrayHeap, nextId = state.nextId + 1 } )


lookupVar : Env -> State -> String -> Maybe Value
lookupVar (Env frameId parent) state name =
    case Dict.get frameId state.heap |> Maybe.andThen (Dict.get name) of
        Just value ->
            Just value

        Nothing ->
            parent |> Maybe.andThen (\p -> lookupVar p state name)


{-| `let`: adds a new binding to the *current* frame only — an error if
that exact frame already has one (shadowing an *outer* scope's binding of
the same name is fine, and goes through this same function, since the
current frame starts out empty for a freshly-entered block).
-}
defineVar : Env -> State -> String -> Value -> Result RuntimeError State
defineVar (Env frameId _) state name value =
    let
        frame =
            Dict.get frameId state.heap |> Maybe.withDefault Dict.empty
    in
    if Dict.member name frame then
        Err (AlreadyDefined name)

    else
        Ok { state | heap = Dict.insert frameId (Dict.insert name value frame) state.heap }


{-| `const`: marks `name`, in the *same* frame `defineVar` just bound it
in, as reassignment-proof — called only after `defineVar` has already
succeeded, so this never needs to fail itself (the frame is guaranteed
to already hold `name` by the time this runs). Kept as a separate step
from `defineVar` rather than folded into it (e.g. via a `Bool`/`mode`
parameter) specifically so `const`'s own "already defined in this
scope"/shadowing behavior is *identical* to `let`'s, by construction —
both funnel through the exact same `defineVar`, so there's no second
copy of that logic to keep in sync.
-}
markConst : Env -> State -> String -> State
markConst (Env frameId _) state name =
    { state
        | constNames =
            Dict.update frameId
                (Maybe.withDefault Set.empty >> Set.insert name >> Just)
                state.constNames
    }


{-| Bare `name = expr`: walks outward through the scope chain to the
nearest frame that already has `name`, and updates it there — never
creates a new binding (that's what `let`/`const` are for). A `const`-marked
name in the frame that owns it is the one thing that turns this into a
hard error instead — checked only here, the single place a bare-name
reassignment can ever happen; `t.field = value`/`a[0] = value` (a
non-empty `AssignTarget` path) never reach this function at all (see
`execAssign` below), which is exactly why mutating a `const`-bound
table's/array's own *contents* is still allowed — only rebinding the
name itself isn't.
-}
assignVar : Env -> State -> String -> Value -> Result RuntimeError State
assignVar (Env frameId parent) state name value =
    let
        frame =
            Dict.get frameId state.heap |> Maybe.withDefault Dict.empty
    in
    if Dict.member name frame then
        if isConst frameId name state then
            Err (ConstReassigned name)

        else
            Ok { state | heap = Dict.insert frameId (Dict.insert name value frame) state.heap }

    else
        case parent of
            Just p ->
                assignVar p state name value

            Nothing ->
                Err (UndefinedName name)


isConst : Int -> String -> State -> Bool
isConst frameId name state =
    Dict.get frameId state.constNames
        |> Maybe.map (Set.member name)
        |> Maybe.withDefault False


{-| True if `name` is `const` in some *ancestor* of `env` — never `env`'s
own frame, deliberately: a same-frame collision (shadowing or not) is
already `AlreadyDefined`, a hard error `defineVar` raises before this is
ever reached, so the two checks never overlap. Walks outward the same way
`assignVar` does, but only ever *reads* `isConst`, one frame at a time —
covers every nesting level for free, since `execBlock` already gives every
`if`/`while`/`for`/function body its own fresh frame.
-}
shadowsConst : Env -> String -> State -> Bool
shadowsConst (Env _ parent) name state =
    case parent of
        Nothing ->
            False

        Just ((Env frameId _) as parentEnv) ->
            isConst frameId name state || shadowsConst parentEnv name state


{-| Called right after `defineVar` has already succeeded for `name` in
`env`'s own frame — queues a `LogWarning` (the exact mechanism
`Debug.log_warning(message)` itself uses, see `Zak.Debug.logNative`) if
that new binding shadows a `const` from an outer scope, e.g. a typo'd
`let true = ...` at the top level shadowing the const-marked `true` in
frame 0. A warning, not an error: the binding still succeeds either way,
exactly as shadowing already worked before `const` existed — this only
makes the one case most likely to be a mistake, rather than a deliberate
choice, loud instead of silent.
-}
warnIfShadowsConst : Env -> String -> State -> State
warnIfShadowsConst env name state =
    if shadowsConst env name state then
        { state
            | pendingEffects =
                state.pendingEffects
                    ++ [ Log LogWarning ("“" ++ name ++ "” shadows a const of the same name from an outer scope") ]
        }

    else
        state



-- ARRAY NATIVES
--
-- Backs the "Array" entry in builtinNatives above. get/set delegate to
-- getArrayIndex/setArrayIndex (shared with [index]/[index] = value); the
-- rest have no dedicated syntax of their own, so they're only ever reached
-- this way.


{-| Looks up a `VArray`'s actual contents in `state.arrayHeap`. The
`Nothing` case (an id with no entry) can't happen for any `VArray` the
interpreter itself ever produces — ids only ever come from
`allocArrayCell` — so it's treated as an empty array rather than threading
a new error case through every caller for something that would be an
interpreter bug, not a runtime condition a script could trigger.
-}
arrayContents : State -> Int -> Array Value
arrayContents state id =
    Dict.get id state.arrayHeap |> Maybe.withDefault Array.empty


arrayLength : State -> List Value -> Result RuntimeError ( Value, State )
arrayLength state args =
    case args of
        [ VArray id ] ->
            Ok ( VNumber (toFloat (Array.length (arrayContents state id))), state )

        [ other ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


arrayIsEmpty : State -> List Value -> Result RuntimeError ( Value, State )
arrayIsEmpty state args =
    case args of
        [ VArray id ] ->
            Ok ( VBool (Array.isEmpty (arrayContents state id)), state )

        [ other ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| `Array.get(array, index)` — a callable spelling of `array[index]`,
delegating to the same `getArrayIndex` that backs it.
-}
arrayGet : State -> List Value -> Result RuntimeError ( Value, State )
arrayGet state args =
    case args of
        [ arrayValue, indexValue ] ->
            getArrayIndex state arrayValue indexValue
                |> Result.map (\value -> ( value, state ))

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


{-| `Array.get_default(array, index, default)` — like `Array.get`, but
returns `default` instead of raising `IndexOutOfBounds` when `index` is
out of range. Only the bounds check is softened: a non-integer `index`
(`wholeNumberIndex`) or a non-`Array` `array` is still a hard error, the
same split `Table.get_default` draws between a missing *field* (softened)
and a wrong-typed target (still an error). The `Array` counterpart to
`Table.get_default`, kept symmetric with it.
-}
arrayGetDefault : State -> List Value -> Result RuntimeError ( Value, State )
arrayGetDefault state args =
    case args of
        [ VArray id, VNumber indexFloat, default ] ->
            wholeNumberIndex indexFloat
                |> Result.map
                    (\index ->
                        ( Array.get index (arrayContents state id) |> Maybe.withDefault default
                        , state
                        )
                    )

        [ other, VNumber _, _ ] ->
            Err (TypeError { expected = "Array", got = other })

        [ _, other, _ ] ->
            Err (TypeError { expected = "Number", got = other })

        _ ->
            Err (WrongArgCount { expected = 3, got = List.length args })


{-| `Array.set(array, index, value)` — a callable spelling of `array[index]
= value`, delegating to the same `setArrayIndex` that backs it.
-}
arraySet : State -> List Value -> Result RuntimeError ( Value, State )
arraySet state args =
    case args of
        [ arrayValue, indexValue, value ] ->
            setArrayIndex state arrayValue indexValue value
                |> Result.map (\state1 -> ( arrayValue, state1 ))

        _ ->
            Err (WrongArgCount { expected = 3, got = List.length args })


{-| `Array.push(array, value)` — a targeted edit, same as `Array.set`:
always mutates `array` directly, growing it by one, and returns the array
itself. No bounds to check — appending is always valid, unlike `set`. No
dedicated syntax of its own (unlike `get`/`set`), so this is its only form.
-}
arrayPush : State -> List Value -> Result RuntimeError ( Value, State )
arrayPush state args =
    case args of
        [ VArray id, value ] ->
            let
                state1 =
                    { state | arrayHeap = Dict.insert id (Array.push value (arrayContents state id)) state.arrayHeap }
            in
            Ok ( VArray id, state1 )

        [ other, _ ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


{-| `Array.append(array, other)` — appends every element of `other` to
the end of `array`, in order, mutating `array` directly and returning it
— `Array.push` generalized from one element to many rather than a new
category: it's still a targeted edit (the tail grows by exactly `other`'s
elements, nothing ambiguous about what's changing), so it follows
`push`'s own contract exactly rather than `map`/`filter`'s pure one —
matching `push`'s own name and shape here, not `String.append`'s purity,
since `array`/`other` are containers
with identity, not plain values the way strings are (see "Arrays" in the
language reference for why `String`/`Array` diverge on this).

Argument order matches every other mutating `Array` function — the
target first, the same position `push`/`set` already use — which also
means it now agrees with `String.append`/Elm's own `Array.append`:
argument order *is* content order, `array`'s own elements followed by
`other`'s, with no reversal to remember (see "Arrays" in the language
reference for the fuller history of this — target-last was tried first,
by analogy with Elm, before the analogy itself was found not to hold:
Elm's own last-argument convention is a consequence of currying + `|>`,
neither of which Zak has).
-}
arrayAppend : State -> List Value -> Result RuntimeError ( Value, State )
arrayAppend state args =
    case args of
        [ VArray id, VArray otherId ] ->
            let
                combined =
                    Array.append (arrayContents state id) (arrayContents state otherId)
            in
            Ok ( VArray id, { state | arrayHeap = Dict.insert id combined state.arrayHeap } )

        [ VArray _, other ] ->
            Err (TypeError { expected = "Array", got = other })

        [ other, _ ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


{-| `Array.pop(array)` — a targeted edit like `Array.push`/`Array.set`
(there's no ambiguity about *what* it removes, only ever the last
element), but it returns the *removed value*, not the array, as `pop`
does almost everywhere — the return-value split being: bulk mutators
return the array itself, removal returns what was removed. Errors on an
empty array rather than returning `nil` — matching Zak's own
established preference for a hard error over a silently-forgiving
result on a degenerate input (division by zero, an out-of-bounds index,
a non-integer index all already work this way).
-}
arrayPop : State -> List Value -> Result RuntimeError ( Value, State )
arrayPop state args =
    case args of
        [ VArray id ] ->
            let
                contents =
                    arrayContents state id

                lastIndex =
                    Array.length contents - 1
            in
            case Array.get lastIndex contents of
                Just lastValue ->
                    let
                        state1 =
                            { state | arrayHeap = Dict.insert id (Array.slice 0 lastIndex contents) state.arrayHeap }
                    in
                    Ok ( lastValue, state1 )

                Nothing ->
                    Err EmptyArray

        [ other ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


arrayContains : State -> List Value -> Result RuntimeError ( Value, State )
arrayContains state args =
    case args of
        [ VArray id, value ] ->
            Ok ( VBool (arrayHasValue state id value), state )

        [ other, _ ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


{-| Shared by `Array.contains` and the `in` operator (`evalIn`) — "not just
the same error, the literal same function," the same relationship
`getArrayIndex`/`getTableField` already have with `Array.get`/`Table.get`.
-}
arrayHasValue : State -> Int -> Value -> Bool
arrayHasValue state id value =
    arrayContents state id |> Array.toList |> List.any (valuesEqual value)


{-| `Array.clone(array)` — a new array with the same elements as `array`.
Shallow: top-level elements are
independent afterward, but a `VArray`/`VTable` element is just a heap
id, so a nested array/table inside is still the *same* one, shared by
reference — cloning never walks into it.
-}
arrayClone : State -> List Value -> Result RuntimeError ( Value, State )
arrayClone state args =
    case args of
        [ VArray id ] ->
            let
                ( newId, state1 ) =
                    allocArrayCell state (arrayContents state id)
            in
            Ok ( VArray newId, state1 )

        [ other ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| `Array.each(array, fn)` — calls `fn(value)` once per element, in
order, discarding whatever it returns; never mutates `array`. For a side
effect per element, not a transform — see `Array.map` for that. An empty
`array` is a no-op: `fn` is never called, falling straight out of
`eachValue`'s own base case below.
-}
arrayEach : State -> List Value -> Result RuntimeError ( Value, State )
arrayEach state args =
    case args of
        [ VArray id, fn ] ->
            eachValue state fn (Array.toList (arrayContents state id))
                |> Result.map (\state1 -> ( VNil, state1 ))

        [ other, _ ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


{-| `mapValues` (below) with the mapped results discarded rather than
collected — same shape, kept separate since `mapValues` returns
`List Value`, not `State`, and threading a throwaway accumulator through
it would be less clear than this own three-line recursion.
-}
eachValue : State -> Value -> List Value -> Result RuntimeError State
eachValue state fn values =
    case values of
        [] ->
            Ok state

        first :: rest ->
            callFunction state fn [ first ]
                |> Result.andThen (\( outcome, state1 ) -> requireDone outcome |> Result.map (\_ -> state1))
                |> Result.andThen (\state1 -> eachValue state1 fn rest)


{-| `Array.map(array, fn)` — a whole-collection derivation: never mutates
`array`, always allocates and returns a new one, same length. Calls `fn`
once per element, threading `State` through since `fn` may itself touch
the heap (e.g. it could allocate more arrays/tables of its own).
-}
arrayMap : State -> List Value -> Result RuntimeError ( Value, State )
arrayMap state args =
    case args of
        [ VArray id, fn ] ->
            mapValues state fn (Array.toList (arrayContents state id))
                |> Result.map
                    (\( mapped, state1 ) ->
                        let
                            ( newId, state2 ) =
                                allocArrayCell state1 (Array.fromList mapped)
                        in
                        ( VArray newId, state2 )
                    )

        [ other, _ ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


mapValues : State -> Value -> List Value -> Result RuntimeError ( List Value, State )
mapValues state fn values =
    case values of
        [] ->
            Ok ( [], state )

        first :: rest ->
            -- `fn` suspending mid-map isn't supported in this pass (see
            -- `Zak.Runtime.requireDone`'s own doc) — a script that tries
            -- gets a clear `SuspendedNotAllowed` error rather than a
            -- partially-applied map silently going wrong.
            callFunction state fn [ first ]
                |> Result.andThen (\( outcome, state1 ) -> requireDone outcome |> Result.map (\value -> ( value, state1 )))
                |> Result.andThen
                    (\( mappedFirst, state1 ) ->
                        mapValues state1 fn rest
                            |> Result.map (\( mappedRest, state2 ) -> ( mappedFirst :: mappedRest, state2 ))
                    )


{-| `Array.indexed_map(array, fn)` — like `Array.map`, but `fn` also
receives each element's index (`fn(index, element)`), matching Elm's
`indexedMap` signature order.
-}
arrayIndexedMap : State -> List Value -> Result RuntimeError ( Value, State )
arrayIndexedMap state args =
    case args of
        [ VArray id, fn ] ->
            indexedMapValues state fn (Array.toIndexedList (arrayContents state id))
                |> Result.map
                    (\( mapped, state1 ) ->
                        let
                            ( newId, state2 ) =
                                allocArrayCell state1 (Array.fromList mapped)
                        in
                        ( VArray newId, state2 )
                    )

        [ other, _ ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


indexedMapValues : State -> Value -> List ( Int, Value ) -> Result RuntimeError ( List Value, State )
indexedMapValues state fn indexedValues =
    case indexedValues of
        [] ->
            Ok ( [], state )

        ( index, value ) :: rest ->
            callFunction state fn [ VNumber (toFloat index), value ]
                |> Result.andThen (\( outcome, state1 ) -> requireDone outcome |> Result.map (\v -> ( v, state1 )))
                |> Result.andThen
                    (\( mappedFirst, state1 ) ->
                        indexedMapValues state1 fn rest
                            |> Result.map (\( mappedRest, state2 ) -> ( mappedFirst :: mappedRest, state2 ))
                    )


{-| `Array.filter(array, predicate)` — a whole-collection derivation: never
mutates `array`, always allocates and returns a new one holding only the
elements `predicate` returned `true` for. `predicate` must return a `Bool`,
same as any other Boolean-position value in the language (see the `if`/
`while` condition rule in the language reference).
-}
arrayFilter : State -> List Value -> Result RuntimeError ( Value, State )
arrayFilter state args =
    case args of
        [ VArray id, predicate ] ->
            filterValues state predicate (Array.toList (arrayContents state id))
                |> Result.map
                    (\( filtered, state1 ) ->
                        let
                            ( newId, state2 ) =
                                allocArrayCell state1 (Array.fromList filtered)
                        in
                        ( VArray newId, state2 )
                    )

        [ other, _ ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


filterValues : State -> Value -> List Value -> Result RuntimeError ( List Value, State )
filterValues state predicate values =
    case values of
        [] ->
            Ok ( [], state )

        first :: rest ->
            callFunction state predicate [ first ]
                |> Result.andThen (\( outcome, state1 ) -> requireDone outcome |> Result.map (\v -> ( v, state1 )))
                |> Result.andThen
                    (\( kept, state1 ) ->
                        case kept of
                            VBool True ->
                                filterValues state1 predicate rest
                                    |> Result.map (\( restKept, state2 ) -> ( first :: restKept, state2 ))

                            VBool False ->
                                filterValues state1 predicate rest

                            other ->
                                Err (TypeError { expected = "Bool", got = other })
                    )


{-| `Array.foldl(array, fn, initial)` — left-to-right reduction to a single
value; never mutates `array`, and its result isn't necessarily an array at
all (e.g. summing to a `Number`). `fn` takes `(element, accumulator)`,
matching Elm's own `foldl`/`foldr` argument order, not the reversed
`(accumulator, element)` order some languages use.
-}
arrayFoldl : State -> List Value -> Result RuntimeError ( Value, State )
arrayFoldl state args =
    case args of
        [ VArray id, fn, initial ] ->
            foldValues state fn initial (Array.toList (arrayContents state id))

        [ other, _, _ ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 3, got = List.length args })


{-| `Array.foldr(array, fn, initial)` — same as `Array.foldl`, but folds
right-to-left; implemented by reversing the element order first and
reusing the same left-to-right walk.
-}
arrayFoldr : State -> List Value -> Result RuntimeError ( Value, State )
arrayFoldr state args =
    case args of
        [ VArray id, fn, initial ] ->
            foldValues state fn initial (List.reverse (Array.toList (arrayContents state id)))

        [ other, _, _ ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 3, got = List.length args })


foldValues : State -> Value -> Value -> List Value -> Result RuntimeError ( Value, State )
foldValues state fn acc values =
    case values of
        [] ->
            Ok ( acc, state )

        first :: rest ->
            callFunction state fn [ first, acc ]
                |> Result.andThen (\( outcome, state1 ) -> requireDone outcome |> Result.map (\newAcc -> ( newAcc, state1 )))
                |> Result.andThen (\( newAcc, state1 ) -> foldValues state1 fn newAcc rest)


{-| `Array.range(lo, hi)` — a constructor, not a targeted edit or a
whole-collection derivation (there's no existing array to mutate or
derive from at all), so it doesn't fit either half of the mutation rule;
it just always allocates and returns a new array. Matches Elm's real
`List.range` exactly: inclusive of both `lo` and `hi`, and simply empty — not an
error — when `lo > hi` (`Array.range(6, 3) == []`).
-}
arrayRange : State -> List Value -> Result RuntimeError ( Value, State )
arrayRange state args =
    case args of
        [ VNumber loFloat, VNumber hiFloat ] ->
            let
                elements =
                    List.range (round loFloat) (round hiFloat)
                        |> List.map (\i -> VNumber (toFloat i))

                ( newId, state1 ) =
                    allocArrayCell state (Array.fromList elements)
            in
            Ok ( VArray newId, state1 )

        [ VNumber _, other ] ->
            Err (TypeError { expected = "Number", got = other })

        [ other, _ ] ->
            Err (TypeError { expected = "Number", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })



-- RECORD NATIVES
--
-- Backs the "Table" entry in builtinNatives above. get/set delegate to
-- getTableField/setTableField (shared with .field/.field = value) —
-- these exist purely to cover a computed field name, which dot syntax
-- can't express at all.


{-| `Table.get(table, name)` — a callable spelling of `table.name`,
delegating to the same `getTableField` that backs it.
-}
tableGet : State -> List Value -> Result RuntimeError ( Value, State )
tableGet state args =
    case args of
        [ tableValue, VString name ] ->
            getTableField state tableValue name
                |> Result.map (\value -> ( value, state ))

        [ _, other ] ->
            Err (TypeError { expected = "String", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


{-| `Table.set(table, name, value)` — a callable spelling of
`table.name = value`, delegating to the same `setTableField` that backs
it (which creates `name` if it doesn't already exist).
-}
tableSet : State -> List Value -> Result RuntimeError ( Value, State )
tableSet state args =
    case args of
        [ tableValue, VString name, value ] ->
            setTableField state tableValue name value
                |> Result.map (\state1 -> ( tableValue, state1 ))

        [ _, other, _ ] ->
            Err (TypeError { expected = "String", got = other })

        _ ->
            Err (WrongArgCount { expected = 3, got = List.length args })


{-| `Table.get_default(table, name, default)` — like `Table.get`, but
returns `default` instead of raising `UndefinedField` when `name` isn't
present on `table`. A callable alternative to null-safe field access
and null-coalescing operators (Zak has neither), reached via a built-in
function rather than new operator syntax, per Zak's own design goal of preferring the former.
Still raises `NotATable` if `table` isn't a `VTable` at all — only a
missing *field* gets the default, not a wrong-typed target.
-}
tableGetDefault : State -> List Value -> Result RuntimeError ( Value, State )
tableGetDefault state args =
    case args of
        [ VTable id, VString name, default ] ->
            let
                value =
                    Dict.get id state.heap
                        |> Maybe.andThen (Dict.get name)
                        |> Maybe.withDefault default
            in
            Ok ( value, state )

        [ other, VString name, _ ] ->
            Err (NotATable other name)

        [ _, other, _ ] ->
            Err (TypeError { expected = "String", got = other })

        _ ->
            Err (WrongArgCount { expected = 3, got = List.length args })


{-| `Table.contains(table, name)` — true if `table` has a field named
`name`, without ever raising `UndefinedField` the way `.name`/`Table.get`
would for a missing one. The only way a script can test for a field's
presence at all, since Zak has no exception handling to probe for that
error indirectly. Reuses `contains` across `Array`/`Table` deliberately —
it checks a different thing on each side (element *contents* for
`Array.contains`, field *name* existence here), the same way Python's own
`in` checks values on a list but keys on a dict.
-}
tableContains : State -> List Value -> Result RuntimeError ( Value, State )
tableContains state args =
    case args of
        [ VTable id, VString name ] ->
            Ok ( VBool (tableHasField state id name), state )

        [ other, VString name ] ->
            Err (NotATable other name)

        [ _, other ] ->
            Err (TypeError { expected = "String", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


{-| Shared by `Table.contains` and the `in` operator (`evalIn`) — see
`arrayHasValue`'s own doc for why this is the literal same function, not
a parallel reimplementation.
-}
tableHasField : State -> Int -> String -> Bool
tableHasField state id name =
    Dict.get id state.heap
        |> Maybe.map (Dict.member name)
        |> Maybe.withDefault False


{-| `Table.clone(table)` — same semantics as `Array.clone`, see its own
doc; a new table with the same fields, shallow.
-}
tableClone : State -> List Value -> Result RuntimeError ( Value, State )
tableClone state args =
    case args of
        [ VTable id ] ->
            let
                fields =
                    Dict.get id state.heap |> Maybe.withDefault Dict.empty

                ( newId, state1 ) =
                    allocCell state
            in
            Ok ( VTable newId, { state1 | heap = Dict.insert newId fields state1.heap } )

        [ other ] ->
            Err (TypeError { expected = "Table", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| `Table.each(table, fn)` — calls `fn(name, value)` once per field, in
`Dict.toList`'s natural (key-sorted, not insertion) order, discarding
whatever `fn` returns; never mutates `table`. An empty `table` is a
no-op, same as `Array.each` on an empty array. Field order is a known,
deliberately deferred gap here.
-}
tableEach : State -> List Value -> Result RuntimeError ( Value, State )
tableEach state args =
    case args of
        [ VTable id, fn ] ->
            let
                fields =
                    Dict.get id state.heap |> Maybe.withDefault Dict.empty |> Dict.toList
            in
            eachField state fn fields
                |> Result.map (\state1 -> ( VNil, state1 ))

        [ other, _ ] ->
            Err (TypeError { expected = "Table", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


eachField : State -> Value -> List ( String, Value ) -> Result RuntimeError State
eachField state fn fields =
    case fields of
        [] ->
            Ok state

        ( name, value ) :: rest ->
            callFunction state fn [ VString name, value ]
                |> Result.andThen (\( outcome, state1 ) -> requireDone outcome |> Result.map (\_ -> state1))
                |> Result.andThen (\state1 -> eachField state1 fn rest)
