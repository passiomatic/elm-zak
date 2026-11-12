module Zak.Internal.Interpreter exposing
    ( Error(..)
    , call
    , drainEffects
    , hasThreads
    , include
    , initialWorld
    , isThreadRunning
    , run
    , runExpr
    , runIncremental
    , setThreadOwner
    , startThread
    , stopThreads
    , threadCount
    , tick
    , worldEnv
    )

{-| Evaluates a `Zak.Internal.AST` tree produced by `Zak.Internal.Parser`, against the
runtime value model `Zak.Internal.Runtime` defines. There are two tiers of
unconditional built-ins, for two different reasons:

`Array`/`Table` are unconditional in _every_ entry point below, including
`runExpr` — a real technical necessity, not a preference: `.field =
value`/`[index] = value` need to share their actual implementation with
`Table.set`/`Array.set` (see `setTableField`/`setArrayIndex` below),
and that sharing only works if both live in the same module as this
evaluator — see `builtinNatives` below.

`Math`/`String`/`Debug`/`Globals` (the `Debug` namespace table, plus the
bare global `type`) are
unconditional only in `run`/`initialWorld`/`runIncremental`, deliberately
_not_ in `runExpr` — see `stdlibNatives` below for why, and why this split
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
import Zak.Internal.AST exposing (AssignTarget(..), BinaryOp(..), Block, Expr(..), PathSegment(..), Position, PositionedStatement, Statement(..), UnaryOp(..))
import Zak.Internal.ErrorMessage as ErrorMessage
import Zak.Internal.Library.Debug as ZakDebug
import Zak.Internal.Library.Globals as Globals
import Zak.Internal.Library.Math as Math
import Zak.Internal.Library.Random as ZakRandom
import Zak.Internal.Library.String as ZakString
import Zak.Internal.Library.Thread as Thread
import Zak.Internal.Parser as Parser
import Zak.Internal.Runtime
    exposing
        ( Effect(..)
        , Env(..)
        , Function(..)
        , LogLevel(..)
        , NativeValue(..)
        , Outcome(..)
        , RuntimeError(..)
        , Signal(..)
        , State
        , Thread(..)
        , ThreadId
        , ThreadOwner
        , ThreadStatus(..)
        , Value(..)
        , WaitCondition(..)
        , allocArrayCell
        , allocCell
        , allocFunction
        , arrayContents
        , mapOutcome
        , mapOutcomeResult
        , nonNegativeIndex
        , requireDone
        , wholeNumber
        )


{-| `Value`, `RuntimeError`, `NativeValue`, `Env`, `State`, `Signal`,
`Outcome`, `WaitCondition`, `ThreadId`, `Thread` all live in `Zak.Internal.Runtime`
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
    (a -> State game -> Result RuntimeError ( Outcome game b, State game ))
    -> Result RuntimeError ( Outcome game a, State game )
    -> Result RuntimeError ( Outcome game b, State game )
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
run : Dict String (NativeValue ()) -> String -> Result Error Value
run natives source =
    let
        ( env, state ) =
            initialWorld () natives
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
runExpr : Dict String (NativeValue ()) -> String -> Result Error Value
runExpr natives source =
    case Parser.parseExpr source of
        Err parserError ->
            Err (SyntaxError parserError)

        Ok expression ->
            evalExpr globalEnv (initialState () natives) expression
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
meant to be called more than once against the _same_ frame — once per
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
initialWorld : game -> Dict String (NativeValue game) -> ( Env, State game )
initialWorld game natives =
    let
        ( frameId, state1 ) =
            allocCell (initialStateFull game natives)
    in
    ( Env frameId (Just globalEnv), { state1 | globalFrameId = frameId } )


{-| The `Env` `initialWorld` returned for `state`'s world: its top-level
frame, under `globalEnv`. Lets a caller that only kept the `State` run
more source into the same world.
-}
worldEnv : State game -> Env
worldEnv state =
    Env state.globalFrameId (Just globalEnv)


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
`SuspendedNotAllowed` — a root-VM-can't-suspend constraint (see `Zak.Internal.Runtime.Outcome`'s doc): only
`Thread.start` (or the host's `startThread`) ever lets a
script's own statements actually run as a suspend-capable thread, and
it fully absorbs whatever their spawned body
does (keeping it in `State.threads` if it suspends) before
returning here, so a `Suspended` reaching all the way out to
`runIncremental` never happens for a _correctly_ written top-level
script — only for one that calls a suspending native directly, which is
exactly the case this should reject.

-}
runIncremental : Env -> State game -> String -> Result Error ( Value, State game )
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
runProgramInto : Env -> State game -> Block -> Result RuntimeError ( Value, State game )
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
a lookup this module deliberately knows nothing about). Runs `source` in a
frame of its own, under the shared _world_ frame rather than the call
site's scope (whatever that happens to be). A top-level `let` of a `_`
name stays in the file's frame, private to it; any other goes straight
into the world frame (`bindingEnv`), so every file sees every other
file's public globals, matching `runIncremental`'s own existing
behavior, just triggered from inside a running script instead of the
embedder's own external loop. The file's functions capture its frame, so
they keep seeing its private names, and nothing else does. The frame is
never freed: `state.fileFrames` keeps it, which is also how an error
names the file a private name belongs to (`undefinedName`).

Idempotent: including the same `path` twice is a silent no-op (`state.
fileFrames`) rather than a second, redundant run — the same
`AlreadyDefined` a second literal run would hit anyway for every `let` it
already declared, and (not incidentally) the entire guard against an
include cycle: if `A` includes `B` includes `A`, `A` is already marked
included by the time `B`'s own `include("A")` runs, so it resolves to
`VNil` instead of looping.

-}
include : String -> String -> State game -> Result RuntimeError ( Value, State game )
include path source state =
    if List.member path (Dict.values state.fileFrames) then
        Ok ( VNil, state )

    else
        case Parser.parseProgram source of
            Err parserError ->
                Err (IncludeParseError path parserError)

            Ok program ->
                let
                    ( frameId, state1 ) =
                        allocCell state
                in
                runProgramInto (Env frameId (Just (worldEnv state1)))
                    { state1 | fileFrames = Dict.insert frameId path state1.fileFrames }
                    program


{-| Calls an already-resolved `Value` (e.g. a function field the
embedder read off some Zak table, not something evaluated from source
here) as a function — the embedder-facing entry point around the
otherwise-internal `callFunction`, for exactly the case `run`/
`runIncremental` don't cover: invoking a Zak closure the embedder already
has a handle on, outside of running a whole program. Named `call`, not
something host-specific like `callVerb` — this module stays host-agnostic
regardless of _why_ an embedder wants to call a value.

Same `Outcome`-collapsing `runIncremental` itself already does: a bare
call can never suspend (`Suspended _ _ -> SuspendedNotAllowed`) — a value
that wants to suspend has to already be a thread's own body, started via
`Thread.start(...)` from _inside_ whatever script produced this `Value`
in the first place. `callFunction` itself is deliberately not exposed
directly: every other public entry point in this module already commits
to this same "top-level calls can't suspend" contract, and exposing the
raw `Outcome`/`RuntimeError` pair here would let a caller route around
it.

-}
call : State game -> Value -> List Value -> Result Error ( Value, State game )
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
(see `seedWithHost`), plus `true`/`false`/`nil`. `natives` is whatever
the embedder chooses to wire up. It can add to `Array`/`Table` but never
replace what they hold, the same protection `true`/`false`/`nil` already
get below. A _script_ can still shadow `Array`/`Table` locally with its
own `let`, same as any other global — this only stops a native-Elm-code
caller from redefining what they mean for every script it runs.

Used directly by `runExpr`, which deliberately stops here (no
`stdlibNatives`) — see `initialStateFull` for the version `run`/
`initialWorld` use instead.

-}
initialState : game -> Dict String (NativeValue game) -> State game
initialState game natives =
    seedWithHost game builtinNatives natives


{-| Same as `initialState`, but also seeds `stdlibNatives`
(`Math`/`String`/`Debug`/`type`) — the full standard library, not just
`Array`/`Table`. Used by `run` and
`initialWorld` (and, through it, `runIncremental` — see that pair's own
docs), which are meant to run a complete, real program rather than a
single already-scoped expression. The same rule as `initialState`, for
the whole standard library: a caller adds to it, and never replaces any
of it.
-}
initialStateFull : game -> Dict String (NativeValue game) -> State game
initialStateFull game natives =
    seedWithHost game (Dict.union builtinNatives stdlibNatives) natives


{-| Seeds the state with the embedder's `game`, the `standard` natives
and the `host`'s, merged by `mergeNatives`, and logs each of the host's
that was ignored.
-}
seedWithHost : game -> Dict String (NativeValue game) -> Dict String (NativeValue game) -> State game
seedWithHost game standard host =
    let
        ( natives, ignored ) =
            mergeNatives "" standard host
    in
    List.foldl logIgnoredNative (seedState game natives) ignored


{-| The `standard` natives with the `host`'s added, and the full names of
the host's it ignored. A host namespace named like a standard one adds its
fields to it (`Thread.with_input_off`), merged the same way at every
level. Anything else the standard library already has keeps the standard
one: the host can add to the standard library, never replace it.
`prefix` is the dotted path of the namespace being merged, as in
`resolveNatives`.
-}
mergeNatives : String -> Dict String (NativeValue game) -> Dict String (NativeValue game) -> ( Dict String (NativeValue game), List String )
mergeNatives prefix standard host =
    Dict.foldl
        (\name hostNative ( merged, ignored ) ->
            case ( Dict.get name merged, hostNative ) of
                ( Nothing, _ ) ->
                    ( Dict.insert name hostNative merged, ignored )

                ( Just (NativeNamespace standardFields), NativeNamespace hostFields ) ->
                    let
                        ( fields, ignoredFields ) =
                            mergeNatives (prefix ++ name ++ ".") standardFields hostFields
                    in
                    ( Dict.insert name (NativeNamespace fields) merged, ignored ++ ignoredFields )

                ( Just _, _ ) ->
                    ( merged, ignored ++ [ prefix ++ name ] )
        )
        ( standard, [] )
        host


{-| `true`/`false`/`nil` are const in frame 0, so a bare `true = ...`
reaching all the way down to this frame is a `ConstReassigned` error
rather than silently repointing what every later `true` in the program
means — the typo-guard the original `const` open point named as a
motivating case. `natives` (`Array`/`Table`/`Math`/... ) deliberately
stay out of `constNames` for now, not because they're any less
"built-in" than `true`/`false`/`nil`, just a smaller, more conservative
first step. This only blocks _reassignment_: a script's own
`let true = ...` in a nested scope still shadows the built-in exactly as
before — that's a new binding in a child frame, `defineVar`
never even looks at frame 0's `constNames`.
-}
seedState : game -> Dict String (NativeValue game) -> State game
seedState game natives =
    let
        ( resolvedNatives, state1 ) =
            resolveNatives ""
                -- Frame 0 exists, empty, while the natives are resolved:
                -- a `NativeZakExpr` is evaluated in it, and a frame
                -- missing from the heap means one freed too early
                -- (`frameFreed`).
                { heap = Dict.singleton 0 Dict.empty
                , arrayHeap = Dict.empty
                , functionHeap = Dict.empty
                , constNames = Dict.empty
                , capturedFrames = Set.empty
                , nextId = 1
                , threads = Dict.empty
                , nextThreadId = 0
                , currentOwner = ""
                , pendingEffects = []
                , randomSeed = Random.initialSeed 0

                -- Both placeholder-zero here -- neither means anything until
                -- `initialWorld` allocates the real world frame right after
                -- this and stamps its own id into `globalFrameId`; nothing
                -- reads either field before that happens.
                , globalFrameId = 0
                , fileFrames = Dict.empty
                , game = game
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
_technical_ reason they couldn't live in a caller-supplied `natives` dict
instead — they're unconditional here purely as a design choice about
what a "real program" (`run`/`initialWorld`/`runIncremental`) should be
able to assume, deliberately not extended to `runExpr` (see that
function's own doc). Precedence mirrors `Zak.Internal.Library.Math`/`Zak.Internal.Library.Globals`/
`Zak.Internal.Library.String`/`Zak.Internal.Library.Debug`/`Zak.Internal.Library.Random`'s own declaration order; none of
the five share any keys, so the order doesn't actually matter today.
-}
stdlibNatives : Dict String (NativeValue game)
stdlibNatives =
    Dict.union (Dict.union Math.natives Globals.natives) ZakString.natives
        |> Dict.union threadNatives
        |> Dict.union ZakDebug.natives
        |> Dict.union ZakRandom.natives


{-| One `Thread` namespace table holding every threading primitive:
`wait_for`/`join`/`wait_while`/`stop` (`Zak.Internal.Library.Thread`, none
of which needs to call back into this module) plus `start` (defined
directly below, since spawning a thread means running its closure
argument via `callFunction` -- exactly the kind of sharing that keeps
`Array`/`Table`'s own natives living in this module too, per this
module's own top-of-file doc; putting it in `Zak.Internal.Library.Thread`
instead would need that module to import this one, which already imports
it -- a real circular import, not a style preference). The wrapping
happens here, one level up from `Zak.Internal.Library.Thread.natives`
itself, so it covers `start` too.

Merged into `stdlibNatives` since this is exactly as unconditional (in
`run`/`initialWorld`/`runIncremental`, not `runExpr`) as `Math`/`String`/
`Debug`/`type` already are, for the same reason: nothing about scripting
threads is a technical necessity the way `Array`/`Table`'s sharing is,
it's a "what a real program should be able to assume" design choice.

-}
threadNatives : Dict String (NativeValue game)
threadNatives =
    Dict.singleton "Thread"
        (NativeNamespace
            (Thread.natives
                |> Dict.insert "start" (NativeFunction start)
            )
        )


{-| `Thread.start(closure)` -- spawns `closure` (called with zero
arguments) as a new thread, owned by the owner of the code that starts it
(`state.currentOwner`): a thread's descendants share its owner. See
`spawn`.
-}
start : State game -> List Value -> Result RuntimeError ( Value, State game )
start state args =
    case args of
        [ closure ] ->
            spawn state.currentOwner closure [] state

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| Runs `callee` as a new thread owned by `owner`: its body runs
_immediately_, synchronously, right here, up to its own first suspend
point or completion -- _before_ this call itself returns anything. The
thread is registered in `state.threads` under a freshly-allocated id
before its body starts, as `Running`, so it counts as one of `owner`'s
threads (`hasThreads`), and can be stopped, from its very first
instruction. If the body suspends, it stays registered, now `Waiting`, to
be resumed later by `tick`; if it runs to completion, or was stopped
while it ran, it's gone (`settle`). Either way, the result is the new
thread's id, handed back so a caller can pass it to `join` later: starting
a thread is not running one, so the caller is never blocked by it.

While the body runs, `owner` is the current owner, so a thread it starts
before its first wait is `owner`'s too; the caller's owner is restored
afterwards. An error before the first wait comes back as an `Err`, with
the caller's state as it was, so nothing stays registered.

-}
spawn : ThreadOwner -> Value -> List Value -> State game -> Result RuntimeError ( Value, State game )
spawn owner callee args state =
    let
        threadId =
            state.nextThreadId

        callerOwner =
            state.currentOwner

        running =
            { state
                | nextThreadId = threadId + 1
                , currentOwner = owner
                , threads = Dict.insert threadId (Thread { owner = owner, status = Running }) state.threads
            }
    in
    callFunction running callee args
        |> Result.map
            (\( outcome, state1 ) ->
                ( VNumber (toFloat threadId)
                , settle threadId owner outcome { state1 | currentOwner = callerOwner }
                )
            )


{-| Where a thread stands once its code stops running for now, in its
first run (`spawn`) or a resume (`tick`): done, it's dropped; waiting
again, it's registered as `Waiting` -- unless it was stopped while it ran
(`stopThreads`, `Thread.stop`), which took it out of `state.threads`: then
it stays out, and never resumes.
-}
settle : ThreadId -> ThreadOwner -> Outcome game Value -> State game -> State game
settle threadId owner outcome state =
    case outcome of
        Done _ ->
            { state | threads = Dict.remove threadId state.threads }

        Suspended waitCondition resume ->
            if Dict.member threadId state.threads then
                { state
                    | threads =
                        Dict.insert threadId
                            (Thread { owner = owner, status = Waiting { waitCondition = waitCondition, elapsed = 0, resume = resume } })
                            state.threads
                }

            else
                state


{-| The host's way to start a thread: `callee` called with `args`, as a
thread owned by `owner` (see `spawn`), giving back its id. An error raised
before the body's first wait comes back as an `Err`, and nothing is
registered.
-}
startThread : ThreadOwner -> Value -> List Value -> State game -> Result Error ( Value, State game )
startThread owner callee args state =
    spawn owner callee args state
        |> Result.mapError RuntimeError


{-| The once-per-frame scheduler step: advances every currently-suspended
thread's own wait condition by `dt` (seconds since the last `tick`),
resuming any whose condition is now satisfied: a host's own condition
(`Host`) is asked with the state as it is when its thread's turn comes,
threads resumed earlier in the same pass included. Each thread gets at most
one `resume` call per `tick`, never more, so a thread that resumes and
immediately suspends again on a condition that's _already_ satisfied
still only advances one step this frame, picking up the rest on the next
`tick` instead of looping here.

A thread whose `resume` call errors is dropped from `threads` (there's
nothing sensible left to do with a thread whose own body raised a runtime
error) and its error is collected in the returned list, rather than
silently discarded or allowed to stop every _other_ thread this frame
from being ticked too.

**The fold walks the `threads` snapshot taken when this `tick` started,
but a thread can be removed mid-pass** — `Thread.stop`, called by a
thread resumed earlier in the same pass. So each thread is first checked
against `stateAcc`'s own `threads`, and skipped if it's gone; otherwise
the `StillWaiting` branch would write a stopped thread straight back in,
or `ReadyToResume` would run it. A thread that stops _itself_ (or its
caller) while being resumed here is out of `threads` by the time it waits
again, so `settle` leaves it out: it ends at its next wait.

**Known, confirmed latency: `Thread.join` can resolve one full tick later
than the thread it's joining actually finishes, depending on thread-id
ordering.** `Dict.foldl` visits `threads` in ascending key order (=
creation order, since ids are a monotonic counter), all within this one
fold pass, and `checkWaitCondition`'s `ThreadRunning` case checks the
target's membership against `stateAcc` -- the _same in-progress_
accumulator. So: if the joining thread's own id is _lower_ than the
target's (i.e. the joiner was created first -- an entirely ordinary
pattern, e.g. a long-running thread later joining on some shorter task it
spawns), it gets checked _before_ the target is processed and removed
later in this same pass, and only notices the target is gone on the
_next_ `tick` -- one extra frame of latency (~16ms at 60fps), never a
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
tick : Float -> State game -> ( State game, List RuntimeError )
tick dt state =
    Dict.foldl
        (\threadId (Thread thread) ( stateAcc, errorsAcc ) ->
            case ( thread.status, Dict.member threadId stateAcc.threads ) of
                ( Waiting waiting, True ) ->
                    case checkWaitCondition dt waiting.elapsed waiting.waitCondition stateAcc of
                        StillWaiting newElapsed ->
                            ( { stateAcc | threads = Dict.insert threadId (Thread { thread | status = Waiting { waiting | elapsed = newElapsed } }) stateAcc.threads }
                            , errorsAcc
                            )

                        ReadyToResume ->
                            -- The thread runs as its own owner, so a thread it
                            -- starts is its owner's too.
                            let
                                running =
                                    { stateAcc
                                        | currentOwner = thread.owner
                                        , threads = Dict.insert threadId (Thread { thread | status = Running }) stateAcc.threads
                                    }
                            in
                            case waiting.resume running of
                                Ok ( outcome, state1 ) ->
                                    ( settle threadId thread.owner outcome { state1 | currentOwner = stateAcc.currentOwner }, errorsAcc )

                                Err error ->
                                    ( { stateAcc | threads = Dict.remove threadId stateAcc.threads }, error :: errorsAcc )

                -- Stopped earlier in this pass. (A `Running` thread only
                -- exists while code runs, never when `tick` starts.)
                _ ->
                    ( stateAcc, errorsAcc )
        )
        ( state, [] )
        state.threads


{-| How many threads are waiting for `tick` to resume them. `0` means
there's nothing to advance, so a host can stop calling `tick` on every
frame.
-}
threadCount : State game -> Int
threadCount state =
    state.threads
        |> Dict.values
        |> List.filter
            (\(Thread thread) ->
                case thread.status of
                    Waiting _ ->
                        True

                    Running ->
                        False
            )
        |> List.length


{-| Stops every thread `owner` owns -- its descendants included, since
they share its owner -- the same way `Thread.stop` stops one: a waiting
thread never resumes, and a running one (the one whose native asked for
this, or one further up the call chain) carries on to its next wait and
ends there (`settle`).
-}
stopThreads : ThreadOwner -> State game -> State game
stopThreads owner state =
    { state | threads = Dict.filter (\_ (Thread thread) -> thread.owner /= owner) state.threads }


{-| Whether `owner` owns any thread: waiting for `tick`, or running now,
its first run included.
-}
hasThreads : ThreadOwner -> State game -> Bool
hasThreads owner state =
    state.threads
        |> Dict.values
        |> List.any (\(Thread thread) -> thread.owner == owner)


{-| Whether the thread `id` still exists: waiting for `tick`, or running
now, its first run included. `Thread.join` waits on the same check.
-}
isThreadRunning : Int -> State game -> Bool
isThreadRunning id state =
    Dict.member id state.threads


{-| Sets the owner of the code that runs outside any thread (what the
host runs or calls), so the threads it starts belong to `owner`.
-}
setThreadOwner : ThreadOwner -> State game -> State game
setThreadOwner owner state =
    { state | currentOwner = owner }


{-| Hands back every `Effect` queued in `state.pendingEffects` since the
last `drainEffects` call, oldest first, and clears the queue. Two kinds
share the queue (see `Zak.Internal.Runtime`'s `Effect`): a `Log` from a
`Debug.log*` call (`Zak.Internal.Library.Debug`) or an interpreter warning, and an
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
(see `Zak.Internal.Runtime`'s own `pendingEffects` doc for why).

-}
drainEffects : State game -> ( List Effect, State game )
drainEffects state =
    ( state.pendingEffects, { state | pendingEffects = [] } )


type WaitCheck
    = StillWaiting Float
    | ReadyToResume


checkWaitCondition : Float -> Float -> WaitCondition game -> State game -> WaitCheck
checkWaitCondition dt elapsed waitCondition state =
    case waitCondition of
        Host stillWaiting ->
            if stillWaiting state then
                StillWaiting elapsed

            else
                ReadyToResume

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


{-| `Array`/`Table`, always present in _every_ entry point — including
`runExpr` — regardless of what `natives` supplies. Unlike `stdlibNatives`
above, this one's unconditional-everywhere status is a real technical
necessity, not a design choice: see this module's own top-of-file doc for
why.

`Array` is a small set sourced from Elm's own `Array` module (not Elm's
`List`) — `length`, `is_empty`, `get`, `set`, `push`,
`append`, `pop`, `remove`, `contains`, `clone`, `slice`, `each`, `map`,
`filter`, `foldl`, `foldr`, `range`.
Every function that mutates (`set`, `push`, `append`, `pop`, `remove`)
always mutates — no separate copy-returning sibling (see "Arrays" in the
language reference for the full rule).
There's deliberately no `indexed_map` (or `indexed_each`): the games
never needed an element's index from a callback, and the one loop that
needs indexes walks `Array.range(0, Array.length(array) - 1)` with
`for`, which already gives it. `Table` covers what dot syntax structurally
can't (a field name that's a runtime value rather than a literal
identifier, `set`) plus a way to test/soften the hard error a missing
field raises (`contains`/`get`) — kept in lockstep with `Array`'s own
`contains`/`get`/`clone` rather than only fixing one side. On both, `get`
is the safe read; the strict one is `array[index]` or `table.name`.

-}
builtinNatives : Dict String (NativeValue game)
builtinNatives =
    Dict.fromList
        [ ( "Array"
          , NativeNamespace
                (Dict.fromList
                    [ ( "length", NativeFunction arrayLength )
                    , ( "is_empty", NativeFunction arrayIsEmpty )
                    , ( "get", NativeFunction arrayGet )
                    , ( "set", NativeFunction arraySet )
                    , ( "push", NativeFunction arrayPush )
                    , ( "append", NativeFunction arrayAppend )
                    , ( "pop", NativeFunction arrayPop )
                    , ( "remove", NativeFunction arrayRemove )
                    , ( "contains", NativeFunction arrayContains )
                    , ( "clone", NativeFunction arrayClone )
                    , ( "slice", NativeFunction arraySlice )
                    , ( "map", NativeFunction arrayMap )
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
                    , ( "set", NativeFunction tableSet )
                    , ( "remove", NativeFunction tableRemove )
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
`prefix` is the dotted path of the namespace being resolved (`""` at the
top, `"Math."` inside `Math`), so a broken native can be logged by its
full name.
-}
resolveNatives : String -> State game -> Dict String (NativeValue game) -> ( Dict String Value, State game )
resolveNatives prefix state natives =
    Dict.foldl
        (\name native ( acc, st ) ->
            case resolveNative (prefix ++ name) st native of
                ( Just value, st1 ) ->
                    ( Dict.insert name value acc, st1 )

                ( Nothing, st1 ) ->
                    ( acc, st1 )
        )
        ( Dict.empty, state )
        natives


resolveNative : String -> State game -> NativeValue game -> ( Maybe Value, State game )
resolveNative path state native =
    case native of
        NativeFunction fn ->
            allocFunction state (Native fn) |> Tuple.mapFirst (VFunction >> Just)

        NativeThreadFunction fn ->
            allocFunction state (NativeThread fn) |> Tuple.mapFirst (VFunction >> Just)

        NativeNamespace fields ->
            let
                ( resolvedFields, state1 ) =
                    resolveNatives (path ++ ".") state fields

                ( id, state2 ) =
                    allocCell state1
            in
            ( Just (VTable id), { state2 | heap = Dict.insert id resolvedFields state2.heap } )

        NativeZakExpr source ->
            -- `source` is fixed Zak source written alongside a native
            -- (e.g. in Zak.Internal.Library.Math, or by the host), not script input. If it
            -- fails to parse or evaluate, that native is left undefined
            -- (`Nothing`), and a `LogError` naming it is queued, rather
            -- than threading another error case through every caller of
            -- `run`/`runExpr` for a bug in the native's own source.
            -- Without the log, a script calling it would get a bare
            -- `UndefinedName` with no hint about the cause. Evaluating a
            -- self-contained function literal here (before frame 0 is
            -- fully populated) is safe: it only captures `globalEnv`, it
            -- doesn't look anything up in it until the function is
            -- actually called later.
            case Parser.parseExpr source of
                Err parserError ->
                    ( Nothing, logBrokenNative path (ErrorMessage.formatSyntaxError source parserError) state )

                Ok expr ->
                    case evalExpr globalEnv state expr of
                        Ok ( value, state1 ) ->
                            ( Just value, state1 )

                        Err runtimeError ->
                            ( Nothing, logBrokenNative path (ErrorMessage.formatRuntimeError source runtimeError) state )

        NativeConstant value ->
            ( Just value, state )


{-| Queues the `LogError` for a `NativeZakExpr` at `path` whose expression
failed to parse or evaluate; `message` is the error's own text.
-}
logBrokenNative : String -> String -> State game -> State game
logBrokenNative path message state =
    { state
        | pendingEffects =
            state.pendingEffects
                ++ [ Log LogError ("native “" ++ path ++ "” is left undefined, because its expression is broken.\n\n" ++ message) ]
    }


{-| Queues the `LogError` for a host native at `path` that `mergeNatives`
ignored, because the standard library already defines that name.
-}
logIgnoredNative : String -> State game -> State game
logIgnoredNative path state =
    { state
        | pendingEffects =
            state.pendingEffects
                ++ [ Log LogError ("native “" ++ path ++ "” is ignored, because the standard library already defines it.") ]
    }


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


{-| Runs a `Block` in its own fresh scope frame, chained under `parentEnv`,
used uniformly for an `if` branch, a `while` or `for` body and a function body.
-}
execBlock : Env -> State game -> Block -> Result RuntimeError ( Outcome game Signal, State game )
execBlock parentEnv state statements =
    withFrame parentEnv [] state (\env state1 -> execStatements env state1 statements)


{-| Runs `body` in a new scope frame under `parentEnv`, holding `bindings`
(a call's parameters, a `for` loop's variable, or nothing for a plain
block), then frees the frame. Every scope frame is made here.

A frame is freed as soon as its scope ends: once `body` is `Done`, or, if
it suspends, once the resumed body is (`andThenOutcome` moves the freeing
into the continuation). Only an `Env` can point at a frame, and an `Env`
outlives its scope only inside a closure, so a frame some closure captured
(`captureEnv`) is kept instead.

A failed `body` frees nothing: its `State` is dropped with the error.

-}
withFrame :
    Env
    -> List ( String, Value )
    -> State game
    -> (Env -> State game -> Result RuntimeError ( Outcome game a, State game ))
    -> Result RuntimeError ( Outcome game a, State game )
withFrame parentEnv bindings state body =
    let
        ( frameId, state1 ) =
            allocCell state

        state2 =
            if List.isEmpty bindings then
                state1

            else
                { state1 | heap = Dict.insert frameId (Dict.fromList bindings) state1.heap }
    in
    body (Env frameId (Just parentEnv)) state2
        |> andThenOutcome (\value state3 -> Ok ( Done value, releaseFrame frameId state3 ))


releaseFrame : Int -> State game -> State game
releaseFrame frameId state =
    if Set.member frameId state.capturedFrames then
        state

    else
        { state
            | heap = Dict.remove frameId state.heap
            , constNames = Dict.remove frameId state.constNames
        }


{-| Marks every frame of `env`'s chain as captured, so `releaseFrame` keeps
it: a closure made in `env` can read any of them later. Stops at the first
frame already marked, since its own ancestors were marked along with it.
-}
captureEnv : Env -> State game -> State game
captureEnv (Env frameId parent) state =
    if Set.member frameId state.capturedFrames then
        state

    else
        let
            marked =
                { state | capturedFrames = Set.insert frameId state.capturedFrames }
        in
        case parent of
            Just parentEnv ->
                captureEnv parentEnv marked

            Nothing ->
                marked


{-| Runs each statement in turn, tagging any `RuntimeError` that comes out
of it with _that statement's own_ position (`Zak.Internal.Runtime.WithPosition`, via
`tagPosition` below) before it propagates any further — the one place in
this whole module position-tagging happens at all. Because this function
is exactly what runs recursively for every nested block too (an `if`
branch, a `while`/`for` body, a function call's body — see `execBlock`),
a statement failing ten calls deep still gets tagged with its own real
position, by the innermost `execStatements` call to ever see the error,
_before_ it bubbles up through every enclosing one — each of which also
calls `tagPosition`, but `tagPosition` is a deliberate no-op on an
already-tagged error, so the innermost, most useful position is the one
that survives, not the outermost/least specific one.
-}
execStatements : Env -> State game -> Block -> Result RuntimeError ( Outcome game Signal, State game )
execStatements env state statements =
    case statements of
        [] ->
            Ok ( Done Normal, state )

        positioned :: rest ->
            case execStatement env state positioned.statement |> Result.mapError (tagPosition positioned.position) of
                -- A direct self-call, which Elm turns into a loop, so a long
                -- block doesn't grow the stack (see `execWhile`).
                Ok ( Done Normal, state1 ) ->
                    execStatements env state1 rest

                Ok ( Done signal, state1 ) ->
                    Ok ( Done signal, state1 )

                Ok ( Suspended waitCondition resume, state1 ) ->
                    Ok ( Suspended waitCondition resume, state1 )
                        |> andThenOutcome (\signal state2 -> afterStatement env rest signal state2)

                Err error ->
                    Err error


{-| What runs after a statement that waited, once it resumes: the rest of
the block, unless the statement stopped it. Returning/Breaking/Continuing
all stop the rest of _this_ block and propagate up unchanged — it's
whatever calls `execBlock` (`execWhile`, `callFunction`, ...) that decides
whether to absorb it or keep propagating it further. `execStatements`
does the same inline for a statement that didn't wait.
-}
afterStatement : Env -> Block -> Signal -> State game -> Result RuntimeError ( Outcome game Signal, State game )
afterStatement env rest signal state =
    case signal of
        Normal ->
            execStatements env state rest

        _ ->
            Ok ( Done signal, state )


{-| Wraps `error` in `WithPosition position error` — but only if it isn't
already wrapped. This is what makes "the innermost failure's position
wins" in `execStatements` above actually true: without the guard, every
enclosing `execStatements` call would re-wrap an already-positioned error
with its _own_, less specific position on the way back up, and the
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
`Zak.Internal.Runtime.Outcome`'s own doc for why that's the one place this pass
wires it up, and `evalExpr`'s `Call` case (used by every _other_ case
here, via `evalExpr`) for what happens if a suspending native is called
from anywhere else instead (a `SuspendedNotAllowed` error, not silent
wrong behavior).
-}
execStatement : Env -> State game -> Statement -> Result RuntimeError ( Outcome game Signal, State game )
execStatement env state statement =
    case statement of
        Let "_" valueExpr ->
            discard env state valueExpr

        Const "_" valueExpr ->
            discard env state valueExpr

        Let name valueExpr ->
            let
                target =
                    bindingEnv env name state
            in
            evalExpr env state valueExpr
                |> Result.andThen (\( value, state1 ) -> defineVar target state1 name value)
                |> Result.map (\state1 -> ( Done Normal, warnIfShadowsConst target name state1 ))

        Const name valueExpr ->
            let
                target =
                    bindingEnv env name state
            in
            evalExpr env state valueExpr
                |> Result.andThen (\( value, state1 ) -> defineVar target state1 name value)
                |> Result.map (\state1 -> ( Done Normal, markConst target (warnIfShadowsConst target name state1) name ))

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


{-| The next pass is a direct self-call in a `case` branch, which Elm
turns into a loop: the stack stays flat however many passes run. Calling
it from a function passed to `andThenOutcome`, as a pass that waited
must, isn't a self-call, so it would nest one level per pass; that's why
only a pass that waited goes through `andThenOutcome`. Its stack unwinds
to `tick` while it waits, so nothing builds up there either.
-}
execWhile : Env -> State game -> Expr -> Block -> Result RuntimeError ( Outcome game Signal, State game )
execWhile env state condExpr body =
    case evalExpr env state condExpr of
        Ok ( VBool True, state1 ) ->
            case execBlock env state1 body of
                Ok ( Done signal, state2 ) ->
                    case loopStep signal of
                        StopLoop result ->
                            Ok ( Done result, state2 )

                        NextPass ->
                            execWhile env state2 condExpr body

                Ok ( Suspended waitCondition resume, state2 ) ->
                    Ok ( Suspended waitCondition resume, state2 )
                        |> andThenOutcome (afterPass (\state3 -> execWhile env state3 condExpr body))

                Err error ->
                    Err error

        Ok ( VBool False, state1 ) ->
            Ok ( Done Normal, state1 )

        Ok ( condValue, _ ) ->
            Err (TypeError { expected = "Bool", got = condValue })

        Err error ->
            Err error


{-| What a loop does after a pass that ended with a given signal.
-}
type LoopStep
    = StopLoop Signal
    | NextPass


loopStep : Signal -> LoopStep
loopStep signal =
    case signal of
        -- propagates past this loop, all the way to the enclosing
        -- function call (or the top level)
        Returning _ ->
            StopLoop signal

        -- absorbed here: stop looping, resume normally with whatever
        -- comes after the loop
        Breaking ->
            StopLoop Normal

        -- the body stopped early (Continuing) or ran to completion
        -- (Normal): either way, on to the next pass
        _ ->
            NextPass


{-| `loopStep` for a pass that waited, once it resumes: `nextPass` runs
the rest of the loop.
-}
afterPass : (State game -> Result RuntimeError ( Outcome game Signal, State game )) -> Signal -> State game -> Result RuntimeError ( Outcome game Signal, State game )
afterPass nextPass signal state =
    case loopStep signal of
        StopLoop result ->
            Ok ( Done result, state )

        NextPass ->
            nextPass state


{-| `let _ = expr` / `const _ = expr`: evaluates `expr` for its effects
and throws the value away. Nothing is bound, so repeating it in the same
scope is never `AlreadyDefined`, and the parser already rejects any read
of `_` (`Zak.Internal.Parser.rejectThrowaway`).
-}
discard : Env -> State game -> Expr -> Result RuntimeError ( Outcome game Signal, State game )
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
once, up front, to fix _which_ array is being iterated (re-evaluating it
every pass isn't something most dynamic languages do either); iteration
itself is live, per `execForLoop` below.
-}
execFor : Env -> State game -> String -> Expr -> Block -> Result RuntimeError ( Outcome game Signal, State game )
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


{-| Live iteration: re-reads the array's _current_ contents from `arrayHeap`
on every pass (rather than a snapshot taken once at loop start), so a
`push`/`set` from within the body is visible to later iterations, as in
most dynamic languages. A deliberately revisitable choice, not a
permanent one.

Each pass gets a _fresh_ frame holding just `loopVar` (mirroring how
`callFunction` binds parameters in their own frame before running the
body), with `execBlock` then giving the body itself its own nested frame
underneath that — so a `let` inside the body never collides with `loopVar`,
the same separation a function's own parameters and its body's `let`s have.

-}
execForLoop : Env -> State game -> String -> Int -> Block -> Int -> Result RuntimeError ( Outcome game Signal, State game )
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
                -- the next pass is a direct self-call, as in `execWhile`
                case withFrame env (withoutThrowaway [ ( loopVar, element ) ]) state (\loopVarEnv state1 -> execBlock loopVarEnv state1 body) of
                    Ok ( Done signal, state2 ) ->
                        case loopStep signal of
                            StopLoop result ->
                                Ok ( Done result, state2 )

                            NextPass ->
                                execForLoop env state2 loopVar id body (index + 1)

                    Ok ( Suspended waitCondition resume, state2 ) ->
                        Ok ( Suspended waitCondition resume, state2 )
                            |> andThenOutcome (afterPass (\state3 -> execForLoop env state3 loopVar id body (index + 1)))

                    Err error ->
                        Err error


{-| `Taylor.a.b.c = 99` (an `AssignTarget (Name "Taylor") [ FieldSegment
"a", ... ]`) or `matrix[0][1] = 99` (`IndexSegment` steps), freely mixed
(`Taylor.items[0] = key`): with no path, this is a bare-name reassignment
(only ever reachable when `base` is a `Name`, per `exprToAssignTarget`'s
own invariant — nothing else parses with an empty path); with one, every
step but the last must already resolve to the right kind of value to take
the _next_ step on (a table for a `.field` step, an array for a `[index]`
step — no auto-vivification of these intermediate steps, see "Tables" in
the reference manual). The _last_ step is different for a `.field` step
specifically: it creates the field if it doesn't already exist, the same
targeted-edit-mutates rule `Array.set`/`Array.push` already follow, rather
than requiring it to already be there — a last `[index]` step still has to
be in-bounds, though, since arrays don't grow via assignment (only via
`Array.push`).

`base` is resolved via `evalExpr`, not a bare `lookupVar`, so a path
assignment's own base can be _any_ expression, not just a name —
`current_player().health = 100` resolves `current_player()` like any
other call before writing through it (see `AssignTarget`'s own doc in
`Zak.Internal.AST`). For the plain `Name` case this is
no behavior change at all: `evalExpr`'s own `Name` branch is exactly
`lookupVar`, which fails with `UndefinedName` the same way.

-}
execAssign : Env -> State game -> AssignTarget -> Value -> Result RuntimeError (State game)
execAssign env state (AssignTarget base segments) value =
    case ( base, segments ) of
        ( Name name, [] ) ->
            assignVar env state name value

        _ ->
            evalExpr env state base
                |> Result.andThen (\( baseValue, state1 ) -> setPath env state1 baseValue segments value)


setPath : Env -> State game -> Value -> List PathSegment -> Value -> Result RuntimeError (State game)
setPath env state target segments value =
    case segments of
        [ FieldSegment field ] ->
            setTableField state target field value

        (FieldSegment field) :: rest ->
            getTableField state target field
                |> Result.andThen (\innerValue -> setPath env state innerValue rest value)

        [ IndexSegment indexExpr ] ->
            evalExpr env state indexExpr
                |> Result.andThen
                    (\( indexValue, state1 ) -> setArrayIndex state1 target indexValue value)

        (IndexSegment indexExpr) :: rest ->
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


{-| The strict read, `array[index]`: shared by the `[index]`
assignment-target step above and the `Index` expression case below.
`Array.get` is the safe read, so it doesn't come through here.
-}
getArrayIndex : State game -> Value -> Value -> Result RuntimeError Value
getArrayIndex state target indexValue =
    case ( target, indexValue ) of
        ( VArray id, VNumber indexFloat ) ->
            wholeNumber indexFloat
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


setArrayIndex : State game -> Value -> Value -> Value -> Result RuntimeError (State game)
setArrayIndex state target indexValue value =
    case ( target, indexValue ) of
        ( VArray id, VNumber indexFloat ) ->
            wholeNumber indexFloat
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


{-| The strict read, `table.name`: shared by the `.field`/assignment-target
step above and the `FieldAccess` expression case below. `Table.get` is
the safe read, so it doesn't come through here.
-}
getTableField : State game -> Value -> String -> Result RuntimeError Value
getTableField state target field =
    case target of
        VTable id ->
            Dict.get id state.heap
                |> Maybe.andThen (Dict.get field)
                |> Result.fromMaybe (UndefinedField field)

        _ ->
            Err (NotATable target field)


setTableField : State game -> Value -> String -> Value -> Result RuntimeError (State game)
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


evalExpr : Env -> State game -> Expr -> Result RuntimeError ( Value, State game )
evalExpr env state expression =
    case expression of
        StringLiteral s ->
            Ok ( VString s, state )

        NumberLiteral n ->
            Ok ( VNumber n, state )

        Name name ->
            lookupVar env state name
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
            Ok (allocFunction (captureEnv env state) (Closure params body env) |> Tuple.mapFirst VFunction)

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
evalShortCircuit : Env -> State game -> Bool -> Expr -> Expr -> Result RuntimeError ( Value, State game )
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


evalExprList : Env -> State game -> List Expr -> Result RuntimeError ( List Value, State game )
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


evalFieldExprs : Env -> State game -> List ( String, Expr ) -> Result RuntimeError ( List ( String, Value ), State game )
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
rest) — evaluated against `env`, the function's own captured _enclosing_
scope, never the call frame being built for this call. Two consequences,
both deliberate:

  - A default can't reference an earlier parameter (`fn(a, b=a):
    ...`) — there's no call frame in scope yet at this point, only the
    enclosing one.
  - Evaluating fresh here, on every call that needs it, rather than once
    when the `VFunction` was first created, is what keeps a mutable
    default (`baz=[]`) an independent value per call rather than one
    shared instance mutated in place across all of them — avoiding the
    classic mutable-default-argument gotcha.

The `Nothing` branch is unreachable in practice: `Zak.Internal.Parser`'s
trailing-only-defaults rule guarantees every parameter past a supplied
argument has a default. Falls back to `VNil` rather than crashing if
that guarantee were somehow ever violated.

-}
evalDefaultArgs : Env -> State game -> List ( String, Maybe Expr ) -> Result RuntimeError ( List ( String, Value ), State game )
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


{-| Calls `callee`, which must be a `VFunction`: the function in
`functionHeap` its id points at (`callFunctionCell`).
-}
callFunction : State game -> Value -> List Value -> Result RuntimeError ( Outcome game Value, State game )
callFunction state callee args =
    case callee of
        VFunction id ->
            case Dict.get id state.functionHeap of
                Just function ->
                    callFunctionCell state function args

                Nothing ->
                    Err (InternalError ("no function with id " ++ String.fromInt id))

        _ ->
            Err (NotAFunction callee)


{-| Calling a `Native`, or a `Closure` whose body never suspends, just
produces `Done value` immediately. A `NativeThread` (`wait_for`/`join`, see
`Zak.Internal.Library.Thread`, or a host's waiting native) can hand back
`Suspended` directly, and so can a `Closure` whose _body_ suspends
(because it itself calls one of those, as its own top-level statement —
see `execStatement`'s `ExprStatement (Call ...)` case), whose `Outcome
Signal` from running the body is mapped to the `Outcome Value` this
function itself promises via `signalValue`/`mapOutcome`.
-}
callFunctionCell : State game -> Function game -> List Value -> Result RuntimeError ( Outcome game Value, State game )
callFunctionCell state function args =
    case function of
        Native fn ->
            fn state args |> Result.map (\( value, state1 ) -> ( Done value, state1 ))

        NativeThread fn ->
            fn state args

        Closure params body closureEnv ->
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
                            withFrame closureEnv (withoutThrowaway (suppliedArgs ++ defaultedArgs)) state1 (\callEnv state2 -> execBlock callEnv state2 body)
                                |> Result.andThen (\( outcome, state3 ) -> mapOutcomeResult signalValue outcome |> Result.map (\mapped -> ( mapped, state3 )))
                        )


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
            checkedDivide "//" floorDivide left right

        Mod ->
            checkedDivide "%" floorModulo left right

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
`setArrayIndex`/`setTableField` already have with `Array.set`/`Table.set`).
A right-hand side that's neither an `Array` nor a `Table` is a hard
`TypeError` rather than silently `false`; every other operator/native in
Zak already refuses that kind of silent tolerance.
-}
evalIn : State game -> Value -> Value -> Result RuntimeError Value
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


{-| `a // b`: divides, then rounds down (toward negative infinity, not
toward zero), so `-7 // 2` is `-4`.
-}
floorDivide : Float -> Float -> Float
floorDivide a b =
    toFloat (floor (a / b))


{-| `a % b`: the remainder that goes with `//`, defined from it directly
(`a - b * (a // b)`) so the pair always satisfies
`a == b * (a // b) + a % b`. That makes it a _floored_ modulo — the
result takes the sign of `b` — like Python's and Lua's `%` and Elm's
`modBy`, not C's/JavaScript's/Squirrel's truncated one (whose result
takes the sign of `a`, so stepping back with `(i - 1) % n` gives `-1` at
`i == 0`). See `design/Modulo.md` for the full comparison, including
the Euclidean option that would have meant redefining `//`.

Works on fractional numbers (`5.5 % 2 == 1.5`, useful for angles and
timers), with the usual floating-point caveats: computing it through
`floor (a / b)` rather than C's `fmod` can lose precision for very large
quotients, and like Python's `%` a tiny negative `a` can round to exactly
`b` (`-1e-20 % 360` gives exactly `360`).

-}
floorModulo : Float -> Float -> Float
floorModulo a b =
    a - b * floorDivide a b


{-| Like `numberOp`, but for `/`, `//` and `%` specifically: a zero divisor is a
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
already uses for `Float`. Deliberately _not_ named `numberCompare` anymore
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


{-| Zak's `==`, which is Elm's own: a `Value` holds no Elm function, only
ids, so Elm can compare any two. `VTable`, `VArray` and `VFunction` compare
by heap id (reference identity, matching how a mutable-in-place value is
meant to behave: "are these the same object", not "do they currently hold
equal contents") — two separately-built arrays with identical elements are
_not_ `==` to one another, only an array compared against itself (reached
through two different names, say) is. A function is the same: itself, not
another one built from the same source.
-}
valuesEqual : Value -> Value -> Bool
valuesEqual a b =
    a == b



-- ENVIRONMENT / HEAP


{-| Walks outward through the scope chain to the nearest frame that has
`name`. Like `defineVar` and `assignVar`, fails with `frameFreed` on a frame
that isn't in the heap anymore, instead of skipping it: skipping would
silently find an outer variable of the same name.
-}
lookupVar : Env -> State game -> String -> Result RuntimeError Value
lookupVar (Env frameId parent) state name =
    case Dict.get frameId state.heap of
        Nothing ->
            Err (frameFreed frameId)

        Just frame ->
            case ( Dict.get name frame, parent ) of
                ( Just value, _ ) ->
                    Ok value

                ( Nothing, Just parentEnv ) ->
                    lookupVar parentEnv state name

                ( Nothing, Nothing ) ->
                    Err (undefinedName state name)


{-| The error for a `name` no frame in the chain has: `PrivateName` when
it's a `_` name an included file keeps in its own frame, so the message
can say why it can't be seen from here, else `UndefinedName`.
-}
undefinedName : State game -> String -> RuntimeError
undefinedName state name =
    let
        holdsName ( frameId, _ ) =
            Dict.get frameId state.heap
                |> Maybe.map (Dict.member name)
                |> Maybe.withDefault False
    in
    if String.startsWith "_" name then
        case List.filter holdsName (Dict.toList state.fileFrames) of
            ( _, path ) :: _ ->
                PrivateName { name = name, path = path }

            [] ->
                UndefinedName name

    else
        UndefinedName name


{-| A scope frame used after `withFrame` freed it: a bug in the
interpreter, never in the script.
-}
frameFreed : Int -> RuntimeError
frameFreed frameId =
    InternalError ("scope frame " ++ String.fromInt frameId ++ " was freed while still in use")


{-| `let`: adds a new binding to the _current_ frame only — an error if
that exact frame already has one (shadowing an _outer_ scope's binding of
the same name is fine, and goes through this same function, since the
current frame starts out empty for a freshly-entered block).
-}
defineVar : Env -> State game -> String -> Value -> Result RuntimeError (State game)
defineVar (Env frameId _) state name value =
    case Dict.get frameId state.heap of
        Nothing ->
            Err (frameFreed frameId)

        Just frame ->
            if Dict.member name frame then
                Err (AlreadyDefined name)

            else
                Ok { state | heap = Dict.insert frameId (Dict.insert name value frame) state.heap }


{-| The scope a `let`/`const` of `name` binds in: `env` itself, except at
the top level of an included file (`include`), where only a `_` name
stays in the file's own frame, private to it, and any other name goes to
the world frame above it.
-}
bindingEnv : Env -> String -> State game -> Env
bindingEnv ((Env frameId parent) as env) name state =
    case parent of
        Just outer ->
            if Dict.member frameId state.fileFrames && not (String.startsWith "_" name) then
                outer

            else
                env

        Nothing ->
            env


{-| `const`: marks `name`, in the _same_ frame `defineVar` just bound it
in, as reassignment-proof — called only after `defineVar` has already
succeeded, so this never needs to fail itself (the frame is guaranteed
to already hold `name` by the time this runs). Kept as a separate step
from `defineVar` rather than folded into it (e.g. via a `Bool`/`mode`
parameter) specifically so `const`'s own "already defined in this
scope"/shadowing behavior is _identical_ to `let`'s, by construction —
both funnel through the exact same `defineVar`, so there's no second
copy of that logic to keep in sync.
-}
markConst : Env -> State game -> String -> State game
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
table's/array's own _contents_ is still allowed — only rebinding the
name itself isn't.
-}
assignVar : Env -> State game -> String -> Value -> Result RuntimeError (State game)
assignVar (Env frameId parent) state name value =
    case Dict.get frameId state.heap of
        Nothing ->
            Err (frameFreed frameId)

        Just frame ->
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
                        Err (undefinedName state name)


isConst : Int -> String -> State game -> Bool
isConst frameId name state =
    Dict.get frameId state.constNames
        |> Maybe.map (Set.member name)
        |> Maybe.withDefault False


{-| True if `name` is `const` in some _ancestor_ of `env` — never `env`'s
own frame, deliberately: a same-frame collision (shadowing or not) is
already `AlreadyDefined`, a hard error `defineVar` raises before this is
ever reached, so the two checks never overlap. Walks outward the same way
`assignVar` does, but only ever _reads_ `isConst`, one frame at a time —
covers every nesting level for free, since `execBlock` already gives every
`if`/`while`/`for`/function body its own fresh frame.
-}
shadowsConst : Env -> String -> State game -> Bool
shadowsConst (Env _ parent) name state =
    case parent of
        Nothing ->
            False

        Just ((Env frameId _) as parentEnv) ->
            isConst frameId name state || shadowsConst parentEnv name state


{-| Called right after `defineVar` has already succeeded for `name` in
`env`'s own frame — queues a `LogWarning` (the exact mechanism
`Debug.log_warning(message)` itself uses, see `Zak.Internal.Library.Debug.logNative`) if
that new binding shadows a `const` from an outer scope, e.g. a typo'd
`let true = ...` at the top level shadowing the const-marked `true` in
frame 0. A warning, not an error: the binding still succeeds either way,
exactly as shadowing already worked before `const` existed — this only
makes the one case most likely to be a mistake, rather than a deliberate
choice, loud instead of silent.
-}
warnIfShadowsConst : Env -> String -> State game -> State game
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
-- Backs the "Array" entry in builtinNatives above. set delegates to
-- setArrayIndex (shared with [index] = value); get is the safe read, and
-- the rest have no dedicated syntax of their own, so they're only ever
-- reached this way.


arrayLength : State game -> List Value -> Result RuntimeError ( Value, State game )
arrayLength state args =
    case args of
        [ VArray id ] ->
            Ok ( VNumber (toFloat (Array.length (arrayContents state id))), state )

        [ other ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


arrayIsEmpty : State game -> List Value -> Result RuntimeError ( Value, State game )
arrayIsEmpty state args =
    case args of
        [ VArray id ] ->
            Ok ( VBool (Array.isEmpty (arrayContents state id)), state )

        [ other ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| `Array.get(array, index, default)` — the safe read: `array[index]`,
or `default` where `array[index]` would raise `IndexOutOfBounds` or
`NegativeIndex` (Elm's `Array.get` gives `Nothing` for both). `default`
is optional, `nil` when omitted. Only a miss is softened: a non-integer
`index` (`wholeNumber`) or a non-`Array` `array` is still a hard error,
the same split `Table.get` draws between a missing _field_ (softened)
and a wrong-typed target (still an error). The strict read is
`array[index]` alone: there's no function for it, as `Table` has none
for `table.name`.
-}
arrayGet : State game -> List Value -> Result RuntimeError ( Value, State game )
arrayGet state args =
    case args of
        [ arrayValue, indexValue ] ->
            arrayGet state [ arrayValue, indexValue, VNil ]

        [ VArray id, VNumber indexFloat, default ] ->
            wholeNumber indexFloat
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

        [ _ ] ->
            Err (WrongArgCount { expected = 2, got = 1 })

        [] ->
            Err (WrongArgCount { expected = 2, got = 0 })

        _ ->
            Err (WrongArgCount { expected = 3, got = List.length args })


{-| `Array.set(array, index, value)` — a callable spelling of `array[index]
= value`, delegating to the same `setArrayIndex` that backs it.
-}
arraySet : State game -> List Value -> Result RuntimeError ( Value, State game )
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
arrayPush : State game -> List Value -> Result RuntimeError ( Value, State game )
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
argument order _is_ content order, `array`'s own elements followed by
`other`'s, with no reversal to remember (see "Arrays" in the language
reference for the fuller history of this — target-last was tried first,
by analogy with Elm, before the analogy itself was found not to hold:
Elm's own last-argument convention is a consequence of currying + `|>`,
neither of which Zak has).

-}
arrayAppend : State game -> List Value -> Result RuntimeError ( Value, State game )
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
(there's no ambiguity about _what_ it removes, only ever the last
element), but it returns the _removed value_, not the array, as `pop`
does almost everywhere — the return-value split being: bulk mutators
return the array itself, removal returns what was removed. Errors on an
empty array rather than returning `nil` — matching Zak's own
established preference for a hard error over a silently-forgiving
result on a degenerate input (division by zero, an out-of-bounds index,
a non-integer index all already work this way).
-}
arrayPop : State game -> List Value -> Result RuntimeError ( Value, State game )
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


{-| `Array.remove(array, value)` — removes the first element equal to
`value` (by the same rules as `==`/`in`/`Array.contains`), in place:
like `Array.pop`, a targeted edit, so it mutates. Follows C#'s
`List.Remove` rather than Python's `list.remove`: it returns `true` if
something was removed and `false` if `value` wasn't there, instead of
erroring. Unlike `pop`, which has to return an element and so has
nothing to return on an empty array, `remove` always has an answer, and
"remove it if it's there" is a normal thing for game code to want (an
inventory item that's already gone). Only the first match goes; to drop
every match, `Array.filter` already does that, as a new array.
-}
arrayRemove : State game -> List Value -> Result RuntimeError ( Value, State game )
arrayRemove state args =
    case args of
        [ VArray id, value ] ->
            let
                contents =
                    arrayContents state id
            in
            case firstIndexOf value contents of
                Just index ->
                    let
                        remaining =
                            Array.append
                                (Array.slice 0 index contents)
                                (Array.slice (index + 1) (Array.length contents) contents)
                    in
                    Ok ( VBool True, { state | arrayHeap = Dict.insert id remaining state.arrayHeap } )

                Nothing ->
                    Ok ( VBool False, state )

        [ other, _ ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


firstIndexOf : Value -> Array Value -> Maybe Int
firstIndexOf value contents =
    contents
        |> Array.toIndexedList
        |> List.filter (\( _, element ) -> valuesEqual value element)
        |> List.head
        |> Maybe.map Tuple.first


arrayContains : State game -> List Value -> Result RuntimeError ( Value, State game )
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
`setArrayIndex`/`setTableField` already have with `Array.set`/`Table.set`.
-}
arrayHasValue : State game -> Int -> Value -> Bool
arrayHasValue state id value =
    arrayContents state id |> Array.toList |> List.any (valuesEqual value)


{-| `Array.slice(array, start, end)` — a new array with `array`'s elements
from `start` up to but not including `end`, leaving `array` untouched:
a derivation from the whole array, like `Array.map`/`Array.filter`, so it
doesn't mutate. Every language that has a function named `slice`
(Squirrel, JavaScript, Ruby) returns a copy too; the in-place versions
always go by another name (`splice`, `RemoveRange`, `resize`).

Same rules as `String.slice`, on purpose, so the one name means one
thing: `end` is optional (through the end of the array), `start`/`end`
must be non-negative whole numbers (`nonNegativeIndex` — no
count-from-the-end), an `end` past the length clamps to the length, and
`start >= end` gives `[]`. Shallow, like `Array.clone`: a nested
array/table element is shared with the original, not copied.

-}
arraySlice : State game -> List Value -> Result RuntimeError ( Value, State game )
arraySlice state args =
    case args of
        [ VArray id, VNumber startFloat, VNumber endFloat ] ->
            arraySliceChecked state id startFloat (Just endFloat)

        [ VArray id, VNumber startFloat ] ->
            arraySliceChecked state id startFloat Nothing

        [ VArray _, VNumber _, other ] ->
            Err (TypeError { expected = "Number", got = other })

        [ VArray _, other ] ->
            Err (TypeError { expected = "Number", got = other })

        [ VArray _, other, _ ] ->
            Err (TypeError { expected = "Number", got = other })

        [ other, _, _ ] ->
            Err (TypeError { expected = "Array", got = other })

        [ other, _ ] ->
            Err (TypeError { expected = "Array", got = other })

        [ _ ] ->
            Err (WrongArgCount { expected = 2, got = 1 })

        [] ->
            Err (WrongArgCount { expected = 2, got = 0 })

        _ ->
            Err (WrongArgCount { expected = 3, got = List.length args })


{-| Validates `start`/`end`, resolves an omitted `end` to the array's
length, and clamps both into `[0, length]` before calling Elm's own
`Array.slice` (whose negative-index wraparound the validation keeps out
of reach) — the same steps as `String.slice`'s `sliceChecked`.
-}
arraySliceChecked : State game -> Int -> Float -> Maybe Float -> Result RuntimeError ( Value, State game )
arraySliceChecked state id startFloat maybeEndFloat =
    let
        contents =
            arrayContents state id

        length =
            Array.length contents
    in
    nonNegativeIndex startFloat
        |> Result.andThen
            (\startIndex ->
                case maybeEndFloat of
                    Nothing ->
                        Ok ( startIndex, length )

                    Just endFloat ->
                        nonNegativeIndex endFloat |> Result.map (\endIndex -> ( startIndex, endIndex ))
            )
        |> Result.map
            (\( startIndex, endIndex ) ->
                let
                    ( newId, state1 ) =
                        allocArrayCell state (Array.slice (min startIndex length) (min endIndex length) contents)
                in
                ( VArray newId, state1 )
            )


{-| `Array.clone(array)` — a new array with the same elements as `array`.
Shallow: top-level elements are
independent afterward, but a `VArray`/`VTable` element is just a heap
id, so a nested array/table inside is still the _same_ one, shared by
reference — cloning never walks into it.
-}
arrayClone : State game -> List Value -> Result RuntimeError ( Value, State game )
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


{-| Calls `fn` from a native that needs its value right away: `fn`
waiting isn't supported there (see `Zak.Internal.Runtime.requireDone`'s
own doc), so a script that tries gets a clear `SuspendedNotAllowed` error
rather than, say, a partially-applied map silently going wrong.
-}
callForValue : State game -> Value -> List Value -> Result RuntimeError ( Value, State game )
callForValue state fn args =
    callFunction state fn args
        |> Result.andThen (\( outcome, state1 ) -> requireDone outcome |> Result.map (\value -> ( value, state1 )))


{-| `Array.map(array, fn)` — a whole-collection derivation: never mutates
`array`, always allocates and returns a new one, same length. Calls `fn`
once per element, threading `State` through since `fn` may itself touch
the heap (e.g. it could allocate more arrays/tables of its own).
-}
arrayMap : State game -> List Value -> Result RuntimeError ( Value, State game )
arrayMap state args =
    case args of
        [ VArray id, fn ] ->
            mapValues state fn [] (Array.toList (arrayContents state id))
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


{-| `revMapped` holds the results so far, last first.

Like every walk over a collection here, the next step is a direct
self-call in a `case` branch, which Elm turns into a loop, so a long
collection doesn't grow the stack (see `execWhile`).

-}
mapValues : State game -> Value -> List Value -> List Value -> Result RuntimeError ( List Value, State game )
mapValues state fn revMapped values =
    case values of
        [] ->
            Ok ( List.reverse revMapped, state )

        first :: rest ->
            case callForValue state fn [ first ] of
                Ok ( mapped, state1 ) ->
                    mapValues state1 fn (mapped :: revMapped) rest

                Err error ->
                    Err error


{-| `Array.filter(array, predicate)` — a whole-collection derivation: never
mutates `array`, always allocates and returns a new one holding only the
elements `predicate` returned `true` for. `predicate` must return a `Bool`,
same as any other Boolean-position value in the language (see the `if`/
`while` condition rule in the language reference).
-}
arrayFilter : State game -> List Value -> Result RuntimeError ( Value, State game )
arrayFilter state args =
    case args of
        [ VArray id, predicate ] ->
            filterValues state predicate [] (Array.toList (arrayContents state id))
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


{-| `revKept` holds the elements kept so far, last first.
-}
filterValues : State game -> Value -> List Value -> List Value -> Result RuntimeError ( List Value, State game )
filterValues state predicate revKept values =
    case values of
        [] ->
            Ok ( List.reverse revKept, state )

        first :: rest ->
            case callForValue state predicate [ first ] of
                Ok ( VBool True, state1 ) ->
                    filterValues state1 predicate (first :: revKept) rest

                Ok ( VBool False, state1 ) ->
                    filterValues state1 predicate revKept rest

                Ok ( other, _ ) ->
                    Err (TypeError { expected = "Bool", got = other })

                Err error ->
                    Err error


{-| `Array.foldl(array, fn, initial)` — left-to-right reduction to a single
value; never mutates `array`, and its result isn't necessarily an array at
all (e.g. summing to a `Number`). `fn` takes `(element, accumulator)`,
matching Elm's own `foldl`/`foldr` argument order, not the reversed
`(accumulator, element)` order some languages use.
-}
arrayFoldl : State game -> List Value -> Result RuntimeError ( Value, State game )
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
arrayFoldr : State game -> List Value -> Result RuntimeError ( Value, State game )
arrayFoldr state args =
    case args of
        [ VArray id, fn, initial ] ->
            foldValues state fn initial (List.reverse (Array.toList (arrayContents state id)))

        [ other, _, _ ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 3, got = List.length args })


foldValues : State game -> Value -> Value -> List Value -> Result RuntimeError ( Value, State game )
foldValues state fn acc values =
    case values of
        [] ->
            Ok ( acc, state )

        first :: rest ->
            case callForValue state fn [ first, acc ] of
                Ok ( newAcc, state1 ) ->
                    foldValues state1 fn newAcc rest

                Err error ->
                    Err error


{-| `Array.range(lo, hi)` — a constructor, not a targeted edit or a
whole-collection derivation (there's no existing array to mutate or
derive from at all), so it doesn't fit either half of the mutation rule;
it just always allocates and returns a new array. Matches Elm's real
`List.range` exactly: inclusive of both `lo` and `hi`, and simply empty — not an
error — when `lo > hi` (`Array.range(6, 3) == []`). Both bounds must be
whole numbers (`wholeNumber`), as an index must: a fractional one is
`NotAnInteger`, not rounded.
-}
arrayRange : State game -> List Value -> Result RuntimeError ( Value, State game )
arrayRange state args =
    case args of
        [ VNumber loFloat, VNumber hiFloat ] ->
            Result.map2
                (\lo hi ->
                    let
                        ( newId, state1 ) =
                            allocArrayCell state (Array.fromList (List.map (\i -> VNumber (toFloat i)) (List.range lo hi)))
                    in
                    ( VArray newId, state1 )
                )
                (wholeNumber loFloat)
                (wholeNumber hiFloat)

        [ VNumber _, other ] ->
            Err (TypeError { expected = "Number", got = other })

        [ other, _ ] ->
            Err (TypeError { expected = "Number", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })



-- RECORD NATIVES
--
-- Backs the "Table" entry in builtinNatives above. set delegates to
-- setTableField (shared with .field = value), to cover a computed field
-- name, which dot syntax can't express at all; get is the safe read.


{-| `Table.set(table, name, value)` — a callable spelling of
`table.name = value`, delegating to the same `setTableField` that backs
it (which creates `name` if it doesn't already exist).
-}
tableSet : State game -> List Value -> Result RuntimeError ( Value, State game )
tableSet state args =
    case args of
        [ tableValue, VString name, value ] ->
            setTableField state tableValue name value
                |> Result.map (\state1 -> ( tableValue, state1 ))

        [ _, other, _ ] ->
            Err (TypeError { expected = "String", got = other })

        _ ->
            Err (WrongArgCount { expected = 3, got = List.length args })


{-| `Table.get(table, name, default)` — the safe read: `table.name`, or
`default` where `table.name` would raise `UndefinedField`. `default` is
optional, `nil` when omitted. The strict read is `table.name` alone, so
a field name built at runtime has only this one. A callable
alternative to null-safe field access and null-coalescing operators (Zak
has neither), reached via a built-in function rather than new operator
syntax, per Zak's own design goal of preferring the former.
Still raises `NotATable` if `table` isn't a `VTable` at all — only a
missing _field_ gets the default, not a wrong-typed target.
-}
tableGet : State game -> List Value -> Result RuntimeError ( Value, State game )
tableGet state args =
    case args of
        [ tableValue, nameValue ] ->
            tableGet state [ tableValue, nameValue, VNil ]

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

        [ _ ] ->
            Err (WrongArgCount { expected = 2, got = 1 })

        [] ->
            Err (WrongArgCount { expected = 2, got = 0 })

        _ ->
            Err (WrongArgCount { expected = 3, got = List.length args })


{-| `Table.remove(table, name)` — removes the field named `name` from
`table`, in place. `true` if it was there, `false` if it wasn't (not an
error), the same contract as `Array.remove`. A boolean rather than the
removed value: a field can hold `nil`, so a returned `nil` couldn't tell
a removed `nil` from a missing field. Setting a field to `nil` keeps it,
so this is the only way to take one out.
-}
tableRemove : State game -> List Value -> Result RuntimeError ( Value, State game )
tableRemove state args =
    case args of
        [ VTable id, VString name ] ->
            if tableHasField state id name then
                Ok ( VBool True, { state | heap = Dict.update id (Maybe.map (Dict.remove name)) state.heap } )

            else
                Ok ( VBool False, state )

        [ other, VString name ] ->
            Err (NotATable other name)

        [ _, other ] ->
            Err (TypeError { expected = "String", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


{-| `Table.contains(table, name)` — true if `table` has a field named
`name`, without ever raising `UndefinedField` the way `.name`/`Table.get`
would for a missing one. The only way a script can test for a field's
presence at all, since Zak has no exception handling to probe for that
error indirectly. Reuses `contains` across `Array`/`Table` deliberately —
it checks a different thing on each side (element _contents_ for
`Array.contains`, field _name_ existence here), the same way Python's own
`in` checks values on a list but keys on a dict.
-}
tableContains : State game -> List Value -> Result RuntimeError ( Value, State game )
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
tableHasField : State game -> Int -> String -> Bool
tableHasField state id name =
    Dict.get id state.heap
        |> Maybe.map (Dict.member name)
        |> Maybe.withDefault False


{-| `Table.clone(table)` — same semantics as `Array.clone`, see its own
doc; a new table with the same fields, shallow.
-}
tableClone : State game -> List Value -> Result RuntimeError ( Value, State game )
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
no-op. Field order is a known, deliberately deferred gap here. The
fields are read once, up front, so
`fn` can `Table.remove` fields safely: a field removed partway through
is still visited, with its old value.
-}
tableEach : State game -> List Value -> Result RuntimeError ( Value, State game )
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


eachField : State game -> Value -> List ( String, Value ) -> Result RuntimeError (State game)
eachField state fn fields =
    case fields of
        [] ->
            Ok state

        ( name, value ) :: rest ->
            case callForValue state fn [ VString name, value ] of
                Ok ( _, state1 ) ->
                    eachField state1 fn rest

                Err error ->
                    Err error
