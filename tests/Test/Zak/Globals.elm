module Test.Zak.Globals exposing (suite)

import Dict
import Expect
import Test exposing (Test, describe, test)
import Zak.Internal.Interpreter as I exposing (Error(..))
import Zak.Internal.Library.Globals as Globals
import Zak.Internal.Runtime as Runtime exposing (RuntimeError(..), Value(..))


{-| The bare global `type` is seeded by `Zak.Internal.Interpreter.run` itself now,
automatically — no natives need passing in here at all.

Strips any `WithPosition` a `RuntimeError` comes back wrapped in
(`Runtime.dropPosition`) — this suite pins down _which_ `RuntimeError`
each case produces, the same as before position-tracking existed; _where_
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


{-| `runExpr` deliberately does _not_ auto-include `type` (see
`Zak.Internal.Interpreter`'s own doc) — so unlike `run` above, this still has to
pass `Globals.natives` in by hand to exercise it here.
-}
runExpr : String -> Result Error Value
runExpr =
    I.runExpr Globals.natives


suite : Test
suite =
    describe "Zak.Internal.Library.Globals"
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
            , test "table — not \"record\" (see Zak.Internal.Library.Globals's own doc for why)" <|
                \_ -> runExpr "type({ x = 1 })" |> Expect.equal (Ok (VString "table"))
            , test "function" <|
                \_ -> runExpr "type(fn(): end)" |> Expect.equal (Ok (VString "function"))
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
                    run "let type = fn(v): return 999 end\nreturn type(1)"
                        |> Expect.equal (Ok (VNumber 999))
            ]
        , describe "is_string/is_number/is_bool/is_array/is_table/is_function (type(value) == name)" <|
            let
                -- One value of every type, including a native function.
                samples =
                    [ ( "\"hi\"", "string" )
                    , ( "\"\"", "string" )
                    , ( "1", "number" )
                    , ( "0", "number" )
                    , ( "true", "bool" )
                    , ( "false", "bool" )
                    , ( "nil", "nil" )
                    , ( "[1, 2]", "array" )
                    , ( "[]", "array" )
                    , ( "{ x = 1 }", "table" )
                    , ( "fn(): return 1 end", "function" )
                    , ( "type", "function" )
                    ]

                predicates =
                    [ ( "is_string", "string" )
                    , ( "is_number", "number" )
                    , ( "is_bool", "bool" )
                    , ( "is_array", "array" )
                    , ( "is_table", "table" )
                    , ( "is_function", "function" )
                    ]
            in
            List.concatMap
                (\( predicate, typeName ) ->
                    List.map
                        (\( source, sampleType ) ->
                            test (predicate ++ "(" ++ source ++ ")") <|
                                \_ ->
                                    runExpr (predicate ++ "(" ++ source ++ ")")
                                        |> Expect.equal (Ok (VBool (sampleType == typeName)))
                        )
                        samples
                        ++ [ test (predicate ++ ": wrong argument count") <|
                                \_ ->
                                    runExpr (predicate ++ "(1, 2)")
                                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
                           ]
                )
                predicates
                ++ [ test "always agrees with type(), for every value" <|
                        \_ ->
                            run
                                """
                                let values = ["hi", 1, true, nil, [1], { x = 1 }, fn(): return 1 end, type]
                                let ok = true
                                for v in values:
                                    if is_string(v) != (type(v) == "string") or is_number(v) != (type(v) == "number") or is_bool(v) != (type(v) == "bool") or is_array(v) != (type(v) == "array") or is_table(v) != (type(v) == "table") or is_function(v) != (type(v) == "function"):
                                        ok = false
                                    end
                                end
                                return ok
                                """
                                |> Expect.equal (Ok (VBool True))
                   , test "available in run without passing any natives" <|
                        \_ -> run "return is_string(\"x\")" |> Expect.equal (Ok (VBool True))
                   , test "a script's own let is_string still shadows it, so existing helper definitions keep working" <|
                        \_ ->
                            run "let is_string = fn(value): return type(value) == \"string\" end\nreturn is_string(1)"
                                |> Expect.equal (Ok (VBool False))
                   ]
        ]
