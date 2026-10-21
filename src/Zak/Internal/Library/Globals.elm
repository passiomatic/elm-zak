module Zak.Internal.Library.Globals exposing (natives)

{-| Bare global functions — not grouped into a namespace at all, because
none of them belong to any particular category. `type`, plus the
`is_*` type checks built on it:
logging (`print`/`debug`/`info`/`warning`/`error`, as they used to be
called) used to live here too, for the same "no better home" reason, but
moved out into its own `Zak.Internal.Library.Debug` namespace once there were enough of
them, and enough of a shared theme, to actually be a category — the same
"namespaced built-ins get their own file because each is its own
bounded, growing family" reasoning `Zak.Internal.Library.Math`/`Zak.Internal.Library.String`/`Zak.Internal.Library.Debug`
already follow. `type` alone doesn't have that — it's not part of a
family, it's just "the one thing with nowhere else to go" — so a single
ungrouped-globals module still earns its keep for it, the same way it
would for any future addition that turns out not to fit an existing
namespace either.

Exposes `natives`, merged in automatically by `Zak.Internal.Interpreter` (along
with `Zak.Internal.Library.Math`/`Zak.Internal.Library.String`/`Zak.Internal.Library.Debug`) for `run`/`initialWorld`/
`runIncremental` — nothing needs to import or merge this by hand.
`runExpr` is the one entry point that deliberately does _not_ include it.

-}

import Dict exposing (Dict)
import Zak.Internal.Runtime exposing (NativeValue(..), RuntimeError(..), State, Value(..))


natives : Dict String (NativeValue game)
natives =
    Dict.fromList
        [ ( "type", NativeFunction typeNative )
        , ( "is_string", NativeFunction (isType "string") )
        , ( "is_number", NativeFunction (isType "number") )
        , ( "is_bool", NativeFunction (isType "bool") )
        , ( "is_array", NativeFunction (isType "array") )
        , ( "is_table", NativeFunction (isType "table") )
        , ( "is_function", NativeFunction (isType "function") )
        ]


{-| `type(value)` — the only way a script can inspect a value's runtime
type at all, since Zak has no exception handling to probe for it
indirectly. A pure function, unlike `print`: no state, no side-effect
channel needed, just a plain classification. Returns a lowercase string
— `"nil"`, `"number"`, `"string"`, `"bool"`, `"array"`, `"function"`,
`"table"`. `"table"`, not `"record"`, because a `record` reads as an
invitation to expect Elm-record semantics (fixed fields, no `Table.set`
mutation, no `contains` probing) that this type deliberately doesn't
have. Lowercase throughout, even though Zak's own `TypeError` messages capitalize these same names ("expected Array, got
Number") — a deliberate difference in register, not an inconsistency:
`TypeError` reads like a sentence fragment, `type(value)` returns a token
meant for direct `==` comparison against a string literal.
-}
typeNative : State game -> List Value -> Result RuntimeError ( Value, State game )
typeNative state args =
    case args of
        [ value ] ->
            Ok ( VString (typeName value), state )

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| `is_string(value)`/`is_number`/`is_bool`/`is_array`/`is_table`/
`is_function` — `type(value) == name`, for the six type names a script
actually checks. They started as script helpers in elm-adventure and
proved useful enough to move here. Built on the same `typeName` as
`type`, so the two can never disagree (`is_function` is `true` for a
native too, exactly as `type` reports `"function"` for one). No
`is_nil`: `value == nil` already says it. Like `type`, they accept any
value, so the only possible error is arity.
-}
isType : String -> State game -> List Value -> Result RuntimeError ( Value, State game )
isType name state args =
    case args of
        [ value ] ->
            Ok ( VBool (typeName value == name), state )

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


typeName : Value -> String
typeName value =
    case value of
        VString _ ->
            "string"

        VNumber _ ->
            "number"

        VBool _ ->
            "bool"

        VNil ->
            "nil"

        VArray _ ->
            "array"

        VTable _ ->
            "table"

        VFunction _ ->
            "function"
