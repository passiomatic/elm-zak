module Zak.Math exposing (natives)

{-| Math functions under one `Math` namespace table (`Math.cos(1)`,
`Math.abs(-1)`, ...) rather than flooding the global scope with each name.
Most of these (trigonometry) genuinely need native code — there's no way
to compute a sine or cosine from Zak's own operators — so they're plain
`NativeFunction`s wrapping Elm's own `Basics` implementations directly.
`abs`, though, *is* fully expressible from Zak's own operators/control-flow,
so it's written as Zak source (`NativeZakExpr`) instead of native code —
"don't implement what the language can already express" applies here too,
it just happens to sit inside a namespace instead of the global scope.

`min`/`max` are *also* fully expressible from Zak's own `<` — but unlike
`abs`, they're still plain `NativeFunction`s (`binaryNumber min`/
`binaryNumber max`, the same helper `atan2` already uses), not
`NativeZakExpr`. Reason: Zak's own `<` (`orderedCompare` in
`Zak.Interpreter`) already accepts strings, not just numbers, so a pure
`if a < b: return a else return b end` snippet would silently make
`Math.min`/`Math.max` the one Math function that also works on strings —
inconsistent with every sibling here, all of which `TypeError` on
anything but a `Number`. Matching that requires an explicit Number check,
and pure Zak has no way to raise a `TypeError` itself (only a native's own
Elm code can construct a `RuntimeError` value directly) — so `binaryNumber`
it is, reusing `Basics.min`/`Basics.max` the same way `pi`/`round` already
reuse their own `Basics` counterparts.

Building `abs` this way, as part of the same `Math` `NativeNamespace` as
the native trig functions, is also what avoids ever needing to add an
`abs` field to an already-built `Math` table after the fact (which the
language disallows) — the whole namespace, native and Zak-defined members
alike, is built in one atomic step.

`Math.pi` is a `NativeConstant` — a plain value, not something callable,
wrapping Elm's own `Basics.pi` directly (same idea as `abs`/the trig
functions: reuse what Elm already gives you rather than hand-typing a
`3.14159...` literal into Zak source and hoping it's precise enough).

`Math.round` wraps Elm's own `Basics.round` (converted back to `Float`,
since Zak has no separate integer type). Worth knowing: Elm's `round`
breaks ties by always rounding *up* (toward positive infinity) — `round
1.5 == 2` but `round -1.5 == -1`, not `-2` — rather than the more common
"round half away from zero" most people expect. `Math.round` inherits
this exact behavior rather than reimplementing rounding some other way.

`Math.sqrt`/`Math.acos`/`Math.asin` aren't bare `unaryNumber` wrappers —
each has a real domain restriction (`sqrt`: no negatives; `acos`/`asin`:
`[-1, 1]` only) where plain `Basics.sqrt`/`acos`/`asin` would silently
return `NaN` instead of failing. Out-of-domain input is a real
`DomainError` for all three, matching `Zak.Interpreter.checkedDivide`'s
own "guard the domain, don't let a `NaN`/`Infinity` leak into a script's
later arithmetic" precedent for `/`/`//`. See `domainChecked`'s own doc,
below.

Exposes `natives`, a single `"Math"` namespace entry — a fragment of the
`Dict String NativeValue` `Zak.Interpreter` merges in automatically (along
with `Zak.String`/`Zak.Debug`/`Zak.Globals`) for `run`/`initialWorld`/
`runIncremental`. Nothing needs to import or merge this by hand —
`runExpr` is the one entry point that deliberately does *not* include it
(see `Zak.Interpreter`'s own module doc for why).
-}

import Dict exposing (Dict)
import Zak.Runtime exposing (NativeValue(..), RuntimeError(..), State, Value(..))


natives : Dict String NativeValue
natives =
    Dict.singleton "Math"
        (NativeNamespace
            (Dict.fromList
                [ ( "pi", NativeConstant (VNumber pi) )
                , ( "cos", NativeFunction (unaryNumber cos) )
                , ( "sin", NativeFunction (unaryNumber sin) )
                , ( "tan", NativeFunction (unaryNumber tan) )
                , ( "acos", NativeFunction acosNative )
                , ( "asin", NativeFunction asinNative )
                , ( "atan", NativeFunction (unaryNumber atan) )
                , ( "atan2", NativeFunction (binaryNumber atan2) )
                , ( "min", NativeFunction (binaryNumber min) )
                , ( "max", NativeFunction (binaryNumber max) )
                , ( "round", NativeFunction (unaryNumber (\n -> toFloat (round n))) )
                , ( "sqrt", NativeFunction sqrtNative )
                , ( "abs"
                  , NativeZakExpr
                        """
                        function(n):
                            if n < 0:
                                return -n
                            end
                            return n
                        end
                        """
                  )
                ]
            )
        )


{-| Wraps a plain `Float -> Float` Elm function as a one-argument Zak
native: checks arity and argument type, then calls straight through. Takes
(and passes through unchanged) the `State` every `NativeFunction` now
threads — Math's own functions never touch the heap, but the signature is
shared with natives that do (see `Zak.Interpreter`'s `Array.*`).
-}
unaryNumber : (Float -> Float) -> (State -> List Value -> Result RuntimeError ( Value, State ))
unaryNumber f state args =
    case args of
        [ VNumber n ] ->
            Ok ( VNumber (f n), state )

        [ other ] ->
            Err (TypeError { expected = "Number", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| Like `unaryNumber`, but for a function with a real domain restriction
— `isValid` decides whether `n` is in bounds, and `describeError` builds
the `DomainError` message when it isn't (checked *before* ever calling
`f`, rather than calling it and checking the result for `NaN` — cheaper,
and reads as "this input is invalid" rather than "something already went
wrong and now we're finding out"). Elm's own `Basics.sqrt`/`acos`/`asin`
don't fail for an out-of-domain input, they silently return `NaN` (a
real, valid `Float` — Elm has no separate "this computation failed"
signal at that level), which would otherwise flow on into the caller's
own later arithmetic as a value that famously isn't even equal to itself
(`NaN == NaN` is `False`) — the exact class of surprising-Zak-value-not-
obviously-wrong-until-much-later bug `Zak.Interpreter.checkedDivide`
already guards `/`/`//` against for a zero divisor (see that function's
own doc). `sqrt`/`acos`/`asin` (below) get the same treatment here,
sharing this one check rather than each hand-rolling it.
-}
domainChecked : (Float -> Bool) -> (Float -> String) -> (Float -> Float) -> (State -> List Value -> Result RuntimeError ( Value, State ))
domainChecked isValid describeError f state args =
    case args of
        [ VNumber n ] ->
            if isValid n then
                Ok ( VNumber (f n), state )

            else
                Err (DomainError (describeError n))

        [ other ] ->
            Err (TypeError { expected = "Number", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


sqrtNative : State -> List Value -> Result RuntimeError ( Value, State )
sqrtNative =
    domainChecked (\n -> n >= 0)
        (\n -> "Math.sqrt(" ++ String.fromFloat n ++ ") is undefined (negative input)")
        sqrt


acosNative : State -> List Value -> Result RuntimeError ( Value, State )
acosNative =
    domainChecked (\n -> n >= -1 && n <= 1)
        (\n -> "Math.acos(" ++ String.fromFloat n ++ ") is undefined (must be between -1 and 1)")
        acos


asinNative : State -> List Value -> Result RuntimeError ( Value, State )
asinNative =
    domainChecked (\n -> n >= -1 && n <= 1)
        (\n -> "Math.asin(" ++ String.fromFloat n ++ ") is undefined (must be between -1 and 1)")
        asin


{-| Same as `unaryNumber`, for a two-argument `Float -> Float -> Float`
function like `atan2`. Checks the first argument's type before the
second's, matching `Zak.Interpreter`'s own `numberOp` convention.
-}
binaryNumber : (Float -> Float -> Float) -> (State -> List Value -> Result RuntimeError ( Value, State ))
binaryNumber f state args =
    case args of
        [ VNumber a, VNumber b ] ->
            Ok ( VNumber (f a b), state )

        [ VNumber _, other ] ->
            Err (TypeError { expected = "Number", got = other })

        [ other, _ ] ->
            Err (TypeError { expected = "Number", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })
