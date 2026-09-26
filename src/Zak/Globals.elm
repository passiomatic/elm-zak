module Zak.Globals exposing (natives)

{-| Bare global functions — not grouped into a namespace at all, because
none of them belong to any particular category. Just `type` for now:
logging (`print`/`debug`/`info`/`warning`/`error`, as they used to be
called) used to live here too, for the same "no better home" reason, but
moved out into its own `Zak.Debug` namespace once there were enough of
them, and enough of a shared theme, to actually be a category — the same
"namespaced built-ins get their own file because each is its own
bounded, growing family" reasoning `Zak.Math`/`Zak.String`/`Zak.Debug`
already follow. `type` alone doesn't have that — it's not part of a
family, it's just "the one thing with nowhere else to go" — so a single
ungrouped-globals module still earns its keep for it, the same way it
would for any future addition that turns out not to fit an existing
namespace either.

Every language Zak already draws from that has an equivalent of `type`
at all (Squirrel, Lua) exposes it as a bare global too — verified against
both directly, not assumed.

Exposes `natives`, merged in automatically by `Zak.Interpreter` (along
with `Zak.Math`/`Zak.String`/`Zak.Debug`) for `run`/`initialWorld`/
`runIncremental` — nothing needs to import or merge this by hand.
`runExpr` is the one entry point that deliberately does *not* include it.
-}

import Dict exposing (Dict)
import Zak.Runtime exposing (NativeValue(..), RuntimeError(..), State, Value(..))


natives : Dict String NativeValue
natives =
    Dict.fromList
        [ ( "type", NativeFunction typeNative )
        ]


{-| `type(value)` — the only way a script can inspect a value's runtime
type at all, since Zak has no exception handling to probe for it
indirectly. A pure function, unlike `print`: no state, no side-effect
channel needed, just a plain classification. Returns a lowercase string,
matching Lua's `type`/Squirrel's `type` exactly (both verified against
their real source, not assumed) — `"nil"`, `"number"`, `"string"`,
`"bool"`, `"array"`, `"function"`, `"table"`. `"table"` is a deliberate
*re*-alignment with Lua/Squirrel's own naming, not the original choice:
this type used to be called `"record"` specifically to read as Zak's own
concept rather than borrowed table terminology, but that backfired in the
other direction — a `record` reads as an invitation to expect Elm-record
semantics (fixed fields, no `Table.set` mutation, no `contains` probing)
that this type deliberately doesn't have, so `table` — genuinely
unfamiliar to nobody, and carrying no such false promise — wins instead
(see `design/Zak Language Implementation.md`'s "Tables"). Lowercase
throughout, even though Zak's own
`TypeError` messages capitalize these same names ("expected Array, got
Number") — a deliberate difference in register, not an inconsistency:
`TypeError` reads like a sentence fragment, `type(value)` returns a token
meant for direct `==` comparison against a string literal, matching every
precedent language's own convention for this specific function.
-}
typeNative : State -> List Value -> Result RuntimeError ( Value, State )
typeNative state args =
    case args of
        [ value ] ->
            Ok ( VString (typeName value), state )

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

        VFunction _ _ _ ->
            "function"

        VNative _ ->
            "function"

        VNativeThread _ ->
            "function"
