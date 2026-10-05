module Zak.Internal.Library.Debug exposing (natives)

{-| Logging (`Debug.log`/`Debug.log_debug`/`Debug.log_info`/
`Debug.log_warning`/`Debug.log_error`) plus `Debug.assert`, grouped under
one `Debug` namespace table — these used to be five bare globals living
in `Zak.Internal.Library.Globals` alongside the unrelated `type`. Regrouped here once
there were enough of them, and enough of a shared theme ("things a script
does purely to help a human debugging it, never anything the script's own
logic depends on"), to actually be a category — the same "namespaced
built-ins get their own file because each is its own bounded, growing
family" reasoning `Zak.Internal.Library.Math`/`Zak.Internal.Library.String` already follow, not something
`Zak.Internal.Library.Globals`' remaining bare globals (just `type`) still need.

**`Zak.Internal.Library.Debug`, not Elm's own `Debug` module — same name, nothing else in
common.** Worth being explicit about, since the coincidence is closer
now than it used to be: this used to be one function (`print`) that
*internally* called Elm's own `Debug.log` before that was replaced (see
"No `Debug.log` anymore" below); now it's a whole Zak-visible namespace
spelled `Debug`. A Zak script's `Debug.log("hi")` is a table-field lookup
into a `NativeNamespace` followed by an ordinary native call — it never
touches Elm's own `Debug.log`, `Debug.toString`, or `Debug.todo`, and
Elm's own `Debug.log` remains exactly as incompatible with
`elm make --optimize` as it always was (a hard compile error on any code
that still contains it). Two unrelated things, at two completely
different levels, that happen to share a name.

Exposes `natives`, merged in automatically by `Zak.Internal.Interpreter` (along
with `Zak.Internal.Library.Math`/`Zak.Internal.Library.String`) for `run`/`initialWorld`/`runIncremental` —
nothing needs to import or merge this by hand. `runExpr` is the one entry
point that deliberately does *not* include it.
-}

import Dict exposing (Dict)
import Zak.Internal.Runtime exposing (Effect(..), LogLevel(..), NativeValue(..), RuntimeError(..), State, Value(..))
import Zak.Internal.Library.String


natives : Dict String NativeValue
natives =
    Dict.singleton "Debug"
        (NativeNamespace
            (Dict.fromList
                [ ( "log", NativeFunction (logNative LogPrint) )
                , ( "log_debug", NativeFunction (logNative LogDebug) )
                , ( "log_info", NativeFunction (logNative LogInfo) )
                , ( "log_warning", NativeFunction (logNative LogWarning) )
                , ( "log_error", NativeFunction (logNative LogError) )
                , ( "assert", NativeFunction assertNative )
                ]
            )
        )


{-| `Debug.log(value)`/`Debug.log_debug(value)`/`Debug.log_info(value)`/
`Debug.log_warning(value)`/`Debug.log_error(value)` — one native,
parameterized over which `LogLevel` it tags its message with, since the
five differ in nothing else: any value is accepted and turned into its
message through `Zak.Internal.Library.String.displayString` — the exact rendering
`String.from` and `%s` already use, so a logged value always reads the
same as it would once converted by hand (`Array`/`Table`/function values
included, as the same fixed `<array>`/`<table>`/`<function>`
placeholders) — and `VNil` back (there's nothing meaningful to hand back,
the same convention a bare `return` already uses). Deliberately looser
than `++`: logging is a debugging aid, not program logic, so there's no
typo for strictness to catch here.

**No `Debug.log` anymore** — this used to be `Debug.log`'s (then still
bare `print`'s) whole implementation, and it was a real, temporary
stand-in, not a finished design: Elm's own `Debug.log` cannot survive an
optimized build (`elm make --optimize` is a hard compile error on any
code that still contains it), so it had to be replaced before Zak could
ship in a real embedder. The deeper problem it papered over — every native
function's signature (`State -> List Value -> Result RuntimeError (
Value, State )`) is a pure transformation of interpreter state, with no
channel at all to communicate anything to the outside world — is what
`State.pendingEffects` (`Zak.Internal.Runtime`) now actually solves: this native's
*entire* job is appending one `Log` to that queue and returning, still
fully pure. Turning a queued `Log` into a real `console.log`/
`console.debug`/`console.info`/`console.warn`/`console.error` call is
`Zak.Internal.Interpreter.drainEffects` and, past that, the embedder's own job
(e.g. via a port) — never this module's, and never anything a native
function could do directly no matter what it stashed in `State` (see
`pendingEffects`'s own doc in `Zak.Internal.Runtime` for why this needed genuinely
different machinery than `Thread`'s `state.threads`, not just a
same-shaped copy of it).
-}
logNative : LogLevel -> State -> List Value -> Result RuntimeError ( Value, State )
logNative level state args =
    case args of
        [ value ] ->
            Ok ( VNil, { state | pendingEffects = state.pendingEffects ++ [ Log level (Zak.Internal.Library.String.displayString value) ] } )

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| `Debug.assert(expr, message)` — a `true` `expr` does nothing at all
and returns `nil`; a `false` one halts the script with a runtime error
carrying `message`. `message` is optional: `Debug.assert(false)` alone
fails with `"assertion failed"`, so a bare failed assertion still gets a
real, specific message, just a default one, not silence or a generic
"wrong argument count."

**The first Zak native with a variable argument count.** Every other
native in the language enforces exactly one arity via `WrongArgCount` —
this is the first genuine 1-or-2 case, so the `[]`/`_` branches below
report whichever bound was actually violated (`expected = 1` for too few,
`expected = 2` for too many), the same convention `Zak.Internal.Interpreter`'s
`callFunction` already established for a Zak-*defined* function with
default parameters (`function(a, b=1): ... end`, `min`/`max` arity
instead of one exact count) — this is that same rule, just needed by a
*native* for the first time instead of a `VFunction`.

`expr` must be a real `VBool`, not a truthy value — matching how
`if`/`while`/`and`/`or` already require a real `Bool` elsewhere in the
language. Whether *those* should instead accept any value via
truthy/falsy rules is a separate, still-open, unrelated design question
— `Debug.assert` simply follows whatever `if`/`while` already do today,
not a new decision of its own.
-}
assertNative : State -> List Value -> Result RuntimeError ( Value, State )
assertNative state args =
    case args of
        [ VBool True ] ->
            Ok ( VNil, state )

        [ VBool True, VString _ ] ->
            Ok ( VNil, state )

        [ VBool False ] ->
            Err (AssertionFailed "assertion failed")

        [ VBool False, VString message ] ->
            Err (AssertionFailed message)

        [ VBool _, other ] ->
            Err (TypeError { expected = "String", got = other })

        [ other ] ->
            Err (TypeError { expected = "Bool", got = other })

        [ other, _ ] ->
            Err (TypeError { expected = "Bool", got = other })

        [] ->
            Err (WrongArgCount { expected = 1, got = 0 })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })
