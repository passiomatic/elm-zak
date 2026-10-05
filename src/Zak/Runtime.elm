module Zak.Runtime exposing
    ( Value(..)
    , RuntimeError(..)
    , NativeValue(..)
    , Env(..)
    , State
    , Heap
    , ArrayHeap
    , Signal(..)
    , Outcome(..)
    , WaitCondition(..)
    , ThreadId
    , Thread(..)
    , LogLevel(..)
    , Effect(..)
    , bindGlobal
    , dropPosition
    , mapOutcome
    , mapOutcomeResult
    , requireDone
    )

{-| The runtime representation `Zak.Interpreter`'s evaluator manipulates
while a program *runs* — as opposed to `Zak.AST`, which represents a
program's *static* structure before anything has executed. Split into its
own module so `Zak.Math`/`Zak.String`/`Zak.Debug`/`Zak.Globals` (each of
which needs these types to describe their own natives) and
`Zak.Interpreter` (which needs to import those four, to seed their
natives automatically into `run`/`initialWorld`) don't form a circular
import — `Zak.Interpreter`
importing `Zak.Math` while `Zak.Math` imports `Zak.Interpreter` back would
be one, and Elm rejects that outright. This module imports nothing
Zak-specific except `Zak.AST` (for `Block`, in `VFunction` below), so it
can never be part of a cycle itself.

`Env`'s constructor is exposed here (`Env(..)`), unlike `Zak.Interpreter`
which only ever exposed the opaque type name — nothing outside
`Zak.Interpreter` currently constructs an `Env` by hand, so this loses no
real safety today, but it's a convention `Zak.Interpreter` itself relies
on (not a compiler-enforced one) rather than a guarantee.
-}

import Array exposing (Array)
import Dict exposing (Dict)
import Random
import Set exposing (Set)
import Zak.AST exposing (Block, Expr, Position)
import Zak.Parser as Parser


{-| A runtime value. `VArray`, `VTable`, and function-call scope frames are
all heap cells (see `Heap`/`arrayHeap` in `State` below) rather than plain
Elm data, because Zak's design needs things Elm's own immutable values can't
give you directly: arrays and tables that mutate in place and are shared
wherever they're passed, and a closure whose captured outer-scope variables
stay mutable and shared across every call to that closure (see the
counter-closure example in the reference manual). Mutating "in place" means
replacing that id's entry in the relevant heap threaded through evaluation,
so every `Value` holding that same id observes the change — this is also
why `VArray`/`VTable` compare by that id (reference identity), not by
their current contents, in `Zak.Interpreter`'s `valuesEqual`.

`VNative` takes `State` because a native function may need heap access
(e.g. any of the `Array.*` natives, which have to read/write `arrayHeap` to
do anything at all) — see `NativeValue`'s own doc for how this threads
through.
-}
type Value
    = VString String
    | VNumber Float
    | VBool Bool
    | VNil
    | VArray Int
    | VTable Int
    | VFunction (List ( String, Maybe Expr )) Block Env
    | VNative (State -> List Value -> Result RuntimeError ( Value, State ))
    | VNativeThread (State -> List Value -> Result RuntimeError ( Outcome Value, State ))


{-| `WithPosition` is different in kind from the other 15 constructors here —
they're all *leaf* errors, raised directly at the ~116 places across this
module and the native modules that actually detect something wrong;
`WithPosition` is a *wrapper*, added by exactly one place
(`Zak.Interpreter.execStatements`, via its own `tagPosition` helper) once
a leaf error has already propagated out of whichever statement raised it.
None of those ~116 raise sites construct `WithPosition` themselves, or need
to change at all for it to exist — every one of them still just builds a
plain leaf error the same way it always has; the wrapping happens exactly
once, after the fact, at the one place that actually knows *which*
statement was executing. See `execStatements`' own doc for why a wrapper
here (rather than adding a position field to every one of the other 16
constructors, or to every `Zak.AST.Expr`/`Statement` node) is enough to
report a genuinely useful position for every runtime error, not just a
constant "start of the script" one, at a fraction of the structural cost.
-}
type RuntimeError
    = UndefinedName String
    | AlreadyDefined String
    | ConstReassigned String
    | UndefinedField String
    | NotATable Value String
    | NotAFunction Value
    | WrongArgCount { expected : Int, got : Int }
    | TypeError { expected : String, got : Value }
    | DivisionByZero String
    | DomainError String
    | AssertionFailed String
    | IndexOutOfBounds { index : Float, length : Int }
    | NotAnInteger { index : Float }
    | NegativeIndex { index : Float }
    | EmptyArray
    | SuspendedNotAllowed
    | FormatArgMismatch { expected : Int, got : Int }
    | UnknownFormatDirective String
    | IncludeNotFound String
    | IncludeParseError String Parser.Error
    | InternalError String
    | WithPosition Position RuntimeError


{-| The underlying leaf error, discarding whatever `WithPosition` it's
wrapped in (if any) — the inverse of what `Zak.Interpreter.execStatements`
builds via `tagPosition`. Use it when matching on a *specific*
`RuntimeError` shape (a test asserting on the exact error returned, say)
and the position is beside the point, since *which* statement failed and
*what* went wrong are two different things to check, not one. Not needed
anywhere in the interpreter's own evaluation, since nothing there ever
wants to throw a captured position away.
-}
dropPosition : RuntimeError -> RuntimeError
dropPosition error =
    case error of
        WithPosition _ inner ->
            dropPosition inner

        _ ->
            error


{-| What a statement/block execution produced, besides an updated `State`:
it either ran normally, or hit one of three things that stop the rest of
the current block from running and need to propagate up further still.
`Returning` propagates through any enclosing `if`/`while` until it reaches
the function-call boundary that should receive the value. `Breaking`/
`Continuing` propagate the same way but only as far as the nearest
enclosing `while` (see `Zak.Interpreter`'s `execWhile`), which absorbs
them there — the parser guarantees `break`/`continue` can never appear
outside a loop in the first place (see `Zak.Parser`'s `insideLoop`
threading), so neither signal can ever legitimately reach a function-call
boundary or the top level; if one ever does, `Zak.Interpreter`'s
`signalValue` treats it as an interpreter bug, not a runtime condition to
recover from.

Lives here, not in `Zak.Interpreter`, because `Outcome`/`Thread` below need
to refer to it (a spawned thread's own body executes statements, so its
`resume` continuation is phrased in terms of `Signal`, the same as any
other statement-sequence execution) — see this module's own top-of-file
doc for why runtime types live together, away from the evaluator itself.
-}
type Signal
    = Normal
    | Returning Value
    | Breaking
    | Continuing


{-| What running something that *might* suspend produced: either it ran to
completion (`Done`), or it hit a suspend point (`Suspended`) and needs to
be resumed later, once `waitCondition` is satisfied — `resume` is "the
rest of this computation," captured as an ordinary Elm closure over
whatever `Env`/remaining statements/etc. were in scope at the suspend
point. Parameterized over the payload type so the *same* suspend/resume
shape works for both a statement sequence's own `Signal` (`Outcome
Signal`, e.g. `Zak.Interpreter.execStatements`) and a function call's
`Value` (`Outcome Value`, e.g. `Zak.Interpreter.callFunction`) — see
`mapOutcome` for converting between the two (a `VFunction` call's body
runs as `Outcome Signal`, but the call itself needs to report `Outcome
Value` to its own caller).

Deliberately narrow in this first pass: only `Zak.Thread`'s
`wait_for`/`join` (and, inside
`Zak.Interpreter` itself, `start`/`start_global`'s own
closure body, transitively) ever construct a `Suspended` value — see
`WaitCondition`'s doc for what a thread can wait on. A suspend attempted from
inside a plain expression (`let x = wait_for(1.0)`, an `Array.map`
callback, an `if` condition, ...) is deliberately *not* supported yet —
`requireDone` is what every one of those contexts uses to turn an
unexpected `Suspended` into a `SuspendedNotAllowed` error instead of
silently doing the wrong thing. Only a bare top-level statement call
(`Zak.Interpreter.execStatement`'s `ExprStatement (Call ...)` case) is
wired to actually preserve and propagate a `Suspended` result.
-}
type Outcome a
    = Done a
    | Suspended WaitCondition (State -> Result RuntimeError ( Outcome a, State ))


{-| What a suspended thread is waiting on, checked once per scheduler
`tick` (`Zak.Interpreter.tick`): a fixed number of elapsed seconds
(`wait_for`), or another thread's own completion (`join`,
the one generic "wait on something else" primitive kept in this pass).
Host-specific conditions are left to the embedder rather than folded in
here as a `Custom` case.
-}
type WaitCondition
    = Seconds Float
    | ThreadRunning ThreadId


type alias ThreadId =
    Int


{-| One suspended, independently-scheduled thread, as registered in
`State.threads` by `start`/`start_global` — see
`Zak.Interpreter`'s own doc for why those two natives (unlike
`wait_for`/`join`) have to live in
`Zak.Interpreter` itself rather than `Zak.Thread`. `resume` is
`Outcome Value`, not `Outcome Signal`, even though a thread's body is a
statement sequence — spawning a thread is really just calling its closure
argument (via `Zak.Interpreter.callFunction`, zero args), and a function
call's own result is always a `Value` (`Zak.Interpreter.signalValue`
already collapses the body's own `Signal` into one, the same conversion
any other call goes through) — `Thread` only ever needs to carry that
call forward to completion, resuming it exactly like any other suspended
call. `elapsed` is reset to `0` every time `waitCondition` changes (a
fresh suspend point starts its own fresh countdown); `isGlobal`
(mirroring `start_global`) is what `Zak.Interpreter.stopLocalThreads`
reads: it stops every thread that isn't global, and that's the only
difference in how the two are treated.

A real `type` (not a `type alias`) for the same reason `Env` already is
one: `Thread`'s own `resume` field refers back to `State`, and `State`
holds a `Dict ThreadId Thread` — a plain record alias can't be mutually
recursive with another alias like that (Elm rejects it outright, the same
way it would for `Env`/`State` if `Env` weren't already wrapped this way),
so this needs a real constructor to break the cycle. `Zak.Interpreter`
pattern-matches `Thread record` to get at the fields, the same way it
already does for `Env frameId parent`.
-}
type Thread
    = Thread
        { waitCondition : WaitCondition
        , elapsed : Float
        , resume : State -> Result RuntimeError ( Outcome Value, State )
        , isGlobal : Bool
        }


{-| Maps the payload of an `Outcome`, threading the mapping function into
a still-`Suspended` value's own eventual result too — the `Outcome`
equivalent of `Result.map`/`Maybe.map`. Used by `Zak.Interpreter.callFunction`
to turn a `VFunction` call's `Outcome Signal` (from running its body) into
the `Outcome Value` the call itself needs to report, via `signalValue`.
-}
mapOutcome : (a -> b) -> Outcome a -> Outcome b
mapOutcome f outcome =
    case outcome of
        Done value ->
            Done (f value)

        Suspended cond resume ->
            Suspended cond (\s -> resume s |> Result.map (\( inner, s1 ) -> ( mapOutcome f inner, s1 )))


{-| `mapOutcome` for a mapping that can fail: the error surfaces right
away for a `Done` outcome, or when a `Suspended` one eventually resumes.
Used by `Zak.Interpreter.callFunction`, whose `signalValue` rejects a
`break`/`continue` signal that escaped its loop.
-}
mapOutcomeResult : (a -> Result RuntimeError b) -> Outcome a -> Result RuntimeError (Outcome b)
mapOutcomeResult f outcome =
    case outcome of
        Done value ->
            Result.map Done (f value)

        Suspended cond resume ->
            Ok
                (Suspended cond
                    (\s ->
                        resume s
                            |> Result.andThen (\( inner, s1 ) -> mapOutcomeResult f inner |> Result.map (\mapped -> ( mapped, s1 )))
                    )
                )


{-| Collapses an `Outcome` that isn't allowed to suspend here into a plain
`Result` — `Done value` unwraps normally, `Suspended` becomes a
`SuspendedNotAllowed` error. Used everywhere a suspend can't be preserved
in this first pass: `Zak.Interpreter.evalExpr`'s `Call` case (so a plain
expression context can't silently do the wrong thing with a suspend), and
every native that calls a Zak function as a callback (`Array.map`'s `fn`,
`Array.filter`'s `predicate`, ...) — see `Outcome`'s own doc for the full
reasoning on why suspension is deliberately restricted to bare top-level
statement calls in this pass.
-}
requireDone : Outcome a -> Result RuntimeError a
requireDone outcome =
    case outcome of
        Done value ->
            Ok value

        Suspended _ _ ->
            Err SuspendedNotAllowed


{-| Describes a native, as supplied to `run`/`runExpr`, before it's been
seeded into the global scope. A `NativeFunction` becomes an ordinary
`VNative`; a `NativeNamespace` becomes a `VTable` — allocating a real heap
cell for its fields — so a whole group of related natives (`Math`'s
trig functions, say) can be exposed as one table (`Math.cos(1)`) instead
of each living as its own separate global name. Namespaces can nest
arbitrarily, though nothing needs more than one level yet.

`NativeZakExpr` is for something expressible in Zak itself (e.g.
`Math.abs`, which needs no native code at all): its source is parsed and
evaluated once, as a single self-contained expression (typically a
function literal), during the same seeding pass as every other entry. This
is what lets a namespace mix native and Zak-defined members and still end
up as one atomically-built table — building `Math.abs` this way, as part
of the same `NativeNamespace` as `Math.cos`, avoids ever needing to add a
field to an already-built table after the fact (which the language
deliberately disallows).

`NativeConstant` is for a plain value that isn't callable at all — a
number like `Math.pi`, say — seeded as-is, with no function-call machinery
involved.

A `NativeFunction` takes `State` (and returns an updated one), unlike a
plain `VFunction` call, because a native written in Elm can't get at the
heap any other way — `Math`'s natives ignore it and pass it straight
through, but anything working with `Array`/`Table` internals (like the
built-in `Array.*` natives in `Zak.Interpreter`) genuinely needs it.

`NativeThreadFunction` is `NativeFunction`'s suspend-capable twin — the
*only* difference is `Outcome Value` instead of a bare `Value` as the
success payload, needed by exactly the natives that can themselves
suspend their caller directly (`Zak.Thread`'s `wait_for`/
`join`). Every other native — including
`start`/`start_global`, which spawn a thread but never
suspend the *caller* — stays a plain `NativeFunction`; see `Outcome`'s own
doc for why suspension is deliberately this narrow in the first pass.
-}
type NativeValue
    = NativeFunction (State -> List Value -> Result RuntimeError ( Value, State ))
    | NativeThreadFunction (State -> List Value -> Result RuntimeError ( Outcome Value, State ))
    | NativeNamespace (Dict String NativeValue)
    | NativeZakExpr String
    | NativeConstant Value


{-| A scope: the heap id of its own frame, and (unless this is the
outermost scope) the enclosing scope. This is an ordinary, immutable Elm
value — only what's *inside* each frame (in the heap) is mutable; the chain
of *which* frames are nested under which is fixed once a scope is entered.
A closure captures this whole chain, which is what makes lexical scoping
(as opposed to dynamic scoping) work: a `VFunction`'s body always resolves
names against the scope active where it was *written*, never the caller's.
-}
type Env
    = Env Int (Maybe Env)


type alias Heap =
    Dict Int (Dict String Value)


{-| The backing storage for every `VArray` — a separate heap from `Heap`
above since an array cell holds an Elm `Array Value` (indexed by position),
not a `Dict String Value` (indexed by field name) the way a frame/table
cell does. Ids are still drawn from the same `nextId` counter as `Heap`, so
an id always unambiguously means "look in `heap`" or "look in `arrayHeap`"
depending on whether the `Value` holding it is a `VTable` or a `VArray` —
the two heaps never need to agree on what a given id means to each other.
-}
type alias ArrayHeap =
    Dict Int (Array Value)


{-| `threads`/`nextThreadId` hold every currently-suspended thread spawned
by `start`/`start_global` — kept as part of `State` itself
(rather than a separate field the embedding app has to thread through
alongside it) so a native function that spawns a thread can register it
with nothing more than the `State` it's already given, and so
`Zak.Interpreter.tick` (the once-per-frame scheduler step) only ever needs
a plain `State -> State` shape, the same as everything else that advances
`State` already looks like. A finished thread is removed from `threads`
entirely, not kept around in some other state — there's no history to
query once a thread completes.

`pendingEffects` is a *different* kind of "kept as part of `State`" than
`threads` is, worth not conflating even though both look like "a queue a
native appends to." `threads` holds continuations — Elm closures the
interpreter itself calls back into later, entirely within pure Elm. An
effect has no such callback to give: what a native wants to happen (a
`console.log` call, a sound playing) can only ever be a `Cmd`, and only an
embedder's own `update` can produce one — no native function ever can, no
matter what it stashes in `State`. So `pendingEffects` holds plain, inert
data describing what was asked for, oldest first; appending to it is the
*entire* job such a native does. `Zak.Interpreter.drainEffects` hands the
queue to the embedder, and turning it into a `Cmd` is entirely the
embedder's job. Logs and host effects share the one queue, so their
relative order survives the drain — see `Effect`'s own doc.

`constNames` tracks which names in which scope frame were declared with
`const` rather than `let` — a separate, narrow side-structure rather
than a change to `Heap`'s own `Dict String Value` value type, deliberately:
`Heap` backs *every* scope frame (`let` bindings, function parameters,
for-loop variables), not just `const` ones, so widening its value type
to carry const-ness would add a field every ordinary variable lookup has
to thread through, for a distinction only a bare reassignment ever needs
to check. Consulted from exactly one place, `Zak.Interpreter`'s
`assignVar` — a `let` binding never appears here at all, since `let`
never marks anything in it in the first place.
-}
type alias State =
    { heap : Heap
    , arrayHeap : ArrayHeap
    , constNames : Dict Int (Set String)
    , nextId : Int
    , threads : Dict ThreadId Thread
    , nextThreadId : ThreadId
    , pendingEffects : List Effect
    , randomSeed : Random.Seed

    {- The world frame's own heap id -- every top-level `let` across every
       loaded `.zak` file lands here (`Zak.Interpreter.initialWorld`/
       `execStatements`' own "run into the same frame, not a fresh child"
       design), so a later file can see an earlier one's globals. Set once,
       in `initialWorld`, to the same id its own returned `Env` already
       carries. Exists so a plain `NativeFunction` (`State -> List Value ->
       ...`, no `Env` of its own) can still splice more top-level code into
       the shared world -- an embedder's own `include` native -- without
       needing `Env` threaded into every native's own signature just for
       this one case.
    -}
    , globalFrameId : Int

    {- Every path `include` has already spliced in, world-wide -- makes a
       second `include` of the same file a no-op instead of re-running (and
       re-`AlreadyDefined`-erroring on) its own top-level `let`s, and this
       is also the entire cycle-guard: if `A` includes `B` includes `A`, `A`
       is already in here by the time `B`'s own `include("A")` runs, so it
       resolves to nothing rather than looping.
    -}
    , includedFiles : Set String
    }


{-| Binds `name -> value` directly into the shared world frame
(`state.globalFrameId`, stamped once by `Zak.Interpreter.initialWorld`) --
for embedder natives that need to define a global even when their own
call is nested inside another function (e.g. a script helper called from
`main()`), which ordinary Zak `let` can't give them: `let` is properly,
lexically scoped in Zak by design -- a `let` inside a function body binds
locally to that call, not globally.
-}
bindGlobal : String -> Value -> State -> State
bindGlobal name value state =
    { state | heap = Dict.update state.globalFrameId (Maybe.map (Dict.insert name value)) state.heap }


{-| The five severities a script can log at — deliberately matching the
handful of `console.*` methods a browser actually renders differently
(`log`/`debug`/`info`/`warn`/`error`), not the much wider "everything
`console` offers" (MDN's own reference lists `table`/`group`/`assert`/
`trace`/`count`/`time`/... well beyond this).
-}
type LogLevel
    = LogPrint
    | LogDebug
    | LogInfo
    | LogWarning
    | LogError


{-| One item a native queued in `State.pendingEffects` for the embedder,
until `Zak.Interpreter.drainEffects` hands it over. Plain, inert data —
see `pendingEffects`'s own doc for why this is *not* the same kind of
thing `Thread`'s `resume` is, despite both living on `State`. The two
variants differ in who defines them:

  - `Log` is defined by the language: `Zak.Debug`'s `Debug.log*` natives,
    and the interpreter's own warnings. Its shape is fixed — a level and a
    message — so it's typed, not a magic effect name a host could forget
    to handle.
  - `Effect` is defined by the host: a name its own native chooses
    (`"play_sound"`, `"move_to"`, ...) and that native's arguments.
    Deliberately generic, not a closed type naming actual host operations:
    that would put one embedder's vocabulary inside `Zak.Runtime`, which
    is meant to work for any host. This module never inspects `name` or
    `args`.

A `VTable`/`VArray` argument is queued as a reference, not a copy: the
host reads its contents when it handles the effect, so it sees any change
a script made in between. A native that needs a snapshot reads the plain
fields out *before* queuing.
-}
type Effect
    = Log LogLevel String
    | Effect String (List Value)
