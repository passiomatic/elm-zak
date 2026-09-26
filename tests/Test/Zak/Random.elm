module Test.Zak.Random exposing (suite)

{-| `Random` is seeded by `Zak.Interpreter.run` itself now, automatically —
no natives need passing in here at all, the same as `Zak.Math`/
`Zak.String`/`Zak.Debug` already are. See `Zak.Interpreter`'s own doc for
why `run` gets this and `runExpr` deliberately doesn't (exercised
directly below, in the one describe block that does need its own
`runExpr` helper).

`Random.number`/`Random.odds` draw from `state.randomSeed`, which
`Zak.Interpreter.seedState` always starts at the exact same fixed
default (`Random.initialSeed 0`) — so within a single `run` call, results
are deterministic and reproducible, but no individual draw's exact value
is asserted here (that would pin down `elm/random`'s own internal
algorithm, not this module's behavior) — only invariants a caller
actually depends on: staying in range, only ever returning a real array
element, and the two probability-1/probability-0 edges of `odds`.
-}

import Dict
import Expect
import Test exposing (Test, describe, test)
import Zak.Interpreter as I exposing (Error(..))
import Zak.Random as Random
import Zak.Runtime as Runtime exposing (RuntimeError(..), Value(..))


run : String -> Result Error Value
run source =
    I.run Dict.empty source |> Result.mapError dropRuntimePosition


dropRuntimePosition : Error -> Error
dropRuntimePosition error =
    case error of
        RuntimeError e ->
            RuntimeError (Runtime.dropPosition e)

        SyntaxError _ ->
            error


suite : Test
suite =
    describe "Zak.Random"
        [ describe "Random.number" <|
            [ test "stays within [start, end] across many draws in one script" <|
                \_ ->
                    run """
                        let ok = true
                        for i in Array.range(0, 200):
                            let n = Random.number(1, 10)
                            if n < 1 or n > 10:
                                ok = false
                            end
                        end
                        return ok
                        """
                        |> Expect.equal (Ok (VBool True))
            , test "start == end always returns that value" <|
                \_ -> run "return Random.number(5, 5)" |> Expect.equal (Ok (VNumber 5))
            , test "wrong argument count" <|
                \_ -> run "return Random.number(1)" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            , test "wrong first argument type" <|
                \_ -> run "return Random.number(\"x\", 1)" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            , test "wrong second argument type" <|
                \_ -> run "return Random.number(1, \"y\")" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "y" })))
            ]
        , describe "Random.pick" <|
            [ test "only ever returns an actual element of the array, across many draws in one script" <|
                \_ ->
                    run """
                        let choices = ["a", "b", "c"]
                        let ok = true
                        for i in Array.range(0, 200):
                            let picked = Random.pick(choices)
                            if picked /= "a" and picked /= "b" and picked /= "c":
                                ok = false
                            end
                        end
                        return ok
                        """
                        |> Expect.equal (Ok (VBool True))
            , test "a single-element array always returns that element" <|
                \_ -> run "return Random.pick([42])" |> Expect.equal (Ok (VNumber 42))
            , test "an empty array is EmptyArray, matching Array.pop's own precedent for this degenerate input" <|
                \_ -> run "return Random.pick([])" |> Expect.equal (Err (RuntimeError EmptyArray))
            , test "wrong argument type" <|
                \_ -> run "return Random.pick(1)" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ -> run "return Random.pick([1], [2])" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            ]
        , describe "Random.odds" <|
            [ test "odds(0) is always false" <|
                \_ ->
                    run """
                        let ok = true
                        for i in Array.range(0, 50):
                            if Random.odds(0):
                                ok = false
                            end
                        end
                        return ok
                        """
                        |> Expect.equal (Ok (VBool True))
            , test "odds(1) is always true" <|
                \_ ->
                    run """
                        let ok = true
                        for i in Array.range(0, 50):
                            if not Random.odds(1):
                                ok = false
                            end
                        end
                        return ok
                        """
                        |> Expect.equal (Ok (VBool True))
            , test "wrong argument count" <|
                \_ -> run "return Random.odds()" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 0 })))
            , test "wrong argument type" <|
                \_ -> run "return Random.odds(true)" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VBool True })))
            ]
        , describe "run: Random is unconditional (like Math/String/Debug), but runExpr is not" <|
            [ test "runExpr, with no natives passed in, does not have Random at all" <|
                \_ ->
                    I.runExpr Dict.empty "Random.number(1, 10)"
                        |> Result.mapError dropRuntimePosition
                        |> Expect.equal (Err (RuntimeError (UndefinedName "Random")))
            , test "runExpr, given Zak.Random.natives explicitly, does have it" <|
                \_ ->
                    I.runExpr Random.natives "Random.number(5, 5)"
                        |> Result.mapError dropRuntimePosition
                        |> Expect.equal (Ok (VNumber 5))
            ]
        ]
