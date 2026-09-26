module Test.Zak.Globals exposing (suite)

import Dict
import Expect
import Test exposing (Test, describe, test)
import Zak.Globals as Globals
import Zak.Interpreter as I exposing (Error(..))
import Zak.Runtime as Runtime exposing (RuntimeError(..), Value(..))


{-| The bare global `type` is seeded by `Zak.Interpreter.run` itself now,
automatically — no natives need passing in here at all.

Strips any `AtPosition` a `RuntimeError` comes back wrapped in
(`Runtime.dropPosition`) — this suite pins down *which* `RuntimeError`
each case produces, the same as before position-tracking existed; *where*
it happened is a different, orthogonal thing, exercised by
`Test.Zak.Interpreter`'s own dedicated position-tracking tests instead,
not re-asserted at every call site here.
-}
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


{-| `runExpr` deliberately does *not* auto-include `type` (see
`Zak.Interpreter`'s own doc) — so unlike `run` above, this still has to
pass `Globals.natives` in by hand to exercise it here.
-}
runExpr : String -> Result Error Value
runExpr =
    I.runExpr Globals.natives


suite : Test
suite =
    describe "Zak.Globals"
        [ describe "type (a pure classification — the only possible error is arity)" <|
            [ test "string" <| \_ -> runExpr "type(\"hi\")" |> Expect.equal (Ok (VString "string"))
            , test "number" <| \_ -> runExpr "type(1)" |> Expect.equal (Ok (VString "number"))
            , test "bool" <|
                \_ ->
                    Expect.all
                        [ \_ -> runExpr "type(true)" |> Expect.equal (Ok (VString "bool"))
                        , \_ -> runExpr "type(false)" |> Expect.equal (Ok (VString "bool"))
                        ]
                        ()
            , test "nil" <| \_ -> runExpr "type(nil)" |> Expect.equal (Ok (VString "nil"))
            , test "array" <| \_ -> runExpr "type([1, 2, 3])" |> Expect.equal (Ok (VString "array"))
            , test "table — not \"record\" (see Zak.Globals's own doc for why)" <|
                \_ -> runExpr "type({ x = 1 })" |> Expect.equal (Ok (VString "table"))
            , test "function" <|
                \_ -> runExpr "type(function(): end)" |> Expect.equal (Ok (VString "function"))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "type(1, 2)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            , test "the motivating case: branching on a value's type" <|
                \_ ->
                    run
                        """
                        let value = "hhh"
                        if type(value) == "string":
                            return 1
                        end
                        if type(value) == "number":
                            return 2
                        end
                        return 3
                        """
                        |> Expect.equal (Ok (VNumber 1))
            , test "a script can still shadow type itself with its own let, same as any other global" <|
                \_ ->
                    run "let type = function(v): return 999 end\nreturn type(1)"
                        |> Expect.equal (Ok (VNumber 999))
            ]
        ]
