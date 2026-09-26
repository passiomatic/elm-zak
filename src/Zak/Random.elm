module Zak.Random exposing (natives)

{-| `random`/`randomfrom`/`randomodds` — DeloresDev's real random-function
API (`design/Random Functions.md`, ranked against the full 49-file real
game corpus: these three cover ~99% of actual use; `randomseed`'s
introspection form and the `FLIPCOIN` macro are skipped as genuinely
unused there) — under one `Random` namespace table, the same "family of
related built-ins gets its own file/namespace" shape `Zak.Math`/
`Zak.String`/`Zak.Debug` already follow.

Built directly on `elm/random`'s own real primitives (`Random.float`/
`Random.uniform`/`Random.weighted`), not reimplemented — but the names
below are this module's own, not copied from `elm/random`'s naming:
Zak calls its numeric type `"number"` (`type(1)` → `"number"`,
`Zak.Globals`), never `"float"`, so `Random.number` is used in place of
what would otherwise read as `Random.float` and leak Elm-internal
vocabulary into Zak's own.

Every function here reads and updates `State.randomSeed` (`Random.step
generator state.randomSeed`, storing the resulting seed back) — the same
"thread a running value through `State`, one call at a time" shape
`nextId`/`nextThreadId` already establish, just for a `Random.Seed`
instead of a counter. `Zak.Interpreter.seedState` seeds it with a fixed,
deterministic default (`Random.initialSeed 0`), same as every other
`State` field there; real entropy is the embedding game's own job to
supply later (see `Engine`/`Main.elm`), not this module's.

Exposes `natives`, a single `"Random"` namespace entry — folded into
`Zak.Interpreter.stdlibNatives`, the same tier `Math`/`String`/`Debug`
already sit in: unconditional in `run`/`initialWorld`/`runIncremental`,
absent from `runExpr` (see that function's own doc for why).
-}

import Array exposing (Array)
import Dict exposing (Dict)
import Random
import Zak.Runtime exposing (NativeValue(..), RuntimeError(..), State, Value(..))


natives : Dict String NativeValue
natives =
    Dict.singleton "Random"
        (NativeNamespace
            (Dict.fromList
                [ ( "number", NativeFunction number )
                , ( "pick", NativeFunction pick )
                , ( "odds", NativeFunction odds )
                ]
            )
        )


{-| `Random.number(start, end)` — DeloresDev's real `random(start,end)`.
Its real int-vs-float-by-argument-type overload is dropped: Zak's
`Value` only ever has `VNumber Float`, so this always returns a float,
the same simplification-over-verbatim-port precedent this codebase
already leans on elsewhere (no ternary, no `ONCE`-gating).
-}
number : State -> List Value -> Result RuntimeError ( Value, State )
number state args =
    case args of
        [ VNumber start, VNumber end ] ->
            let
                ( n, newSeed ) =
                    Random.step (Random.float start end) state.randomSeed
            in
            Ok ( VNumber n, { state | randomSeed = newSeed } )

        [ VNumber _, other ] ->
            Err (TypeError { expected = "Number", got = other })

        [ other, _ ] ->
            Err (TypeError { expected = "Number", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


{-| `Random.pick(array)` — DeloresDev's real `randomfrom`, array-only
here (a caller can always pass a list; see `design/Random Functions.md`
for why this sidesteps building Zak's first true variadic native).
Built on `elm/random`'s own `Random.uniform : a -> List a -> Generator a`
("pick uniformly from a list"), which needs exactly this
already-split-into-head/tail shape. Errors on an empty array
(`EmptyArray`), matching `Array.pop`'s own existing precedent for this
degenerate input rather than returning `nil`.
-}
pick : State -> List Value -> Result RuntimeError ( Value, State )
pick state args =
    case args of
        [ VArray id ] ->
            case Array.toList (Dict.get id state.arrayHeap |> Maybe.withDefault Array.empty) of
                [] ->
                    Err EmptyArray

                head :: tail ->
                    let
                        ( picked, newSeed ) =
                            Random.step (Random.uniform head tail) state.randomSeed
                    in
                    Ok ( picked, { state | randomSeed = newSeed } )

        [ other ] ->
            Err (TypeError { expected = "Array", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| `Random.odds(p)` — DeloresDev's real `randomodds`, kept verbatim
minus the redundant `random` prefix. `true` with probability `p`,
`false` with probability `1 - p`. Built on `elm/random`'s own
`Random.weighted : (Float, a) -> List (Float, a) -> Generator a` (picks
from weighted pairs, probability proportional to weight) rather than
`Random.uniform`, which would only ever give a fixed 50/50 split
regardless of `p`.
-}
odds : State -> List Value -> Result RuntimeError ( Value, State )
odds state args =
    case args of
        [ VNumber p ] ->
            let
                ( result, newSeed ) =
                    Random.step (Random.weighted ( p, True ) [ ( 1 - p, False ) ]) state.randomSeed
            in
            Ok ( VBool result, { state | randomSeed = newSeed } )

        [ other ] ->
            Err (TypeError { expected = "Number", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })
