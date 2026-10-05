module Test.Zak.Math exposing (suite)

import Dict
import Expect
import Test exposing (Test, describe, test)
import Zak.Internal.Interpreter as I exposing (Error(..))
import Zak.Internal.Runtime as Runtime exposing (RuntimeError(..), Value(..))


{-| `Math` is seeded by `Zak.Internal.Interpreter.run` itself now, automatically —
no natives need passing in here at all. See `Zak.Internal.Interpreter`'s own doc
for why `run` gets this and `runExpr` deliberately doesn't.

Strips any `WithPosition` a `RuntimeError` comes back wrapped in — this
suite pins down *which* `RuntimeError` each case produces, the same as
before position-tracking existed; *where* it happened is exercised by
`Test.Zak.Interpreter`'s own dedicated position-tracking tests instead.
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


{-| Compares the `Float` inside an `Ok (VNumber _)` result with a
tolerance — trig results are irrational, so (per elm-test's own warning)
this can't use exact `Expect.equal` the way the arity/type-error tests
below do.
-}
expectNumber : Float -> Result Error Value -> Expect.Expectation
expectNumber expected result =
    case result of
        Ok (VNumber actual) ->
            Expect.within (Expect.Absolute 0.000001) expected actual

        Ok other ->
            Expect.fail ("expected a number, got: " ++ Debug.toString other)

        Err err ->
            Expect.fail ("expected " ++ String.fromFloat expected ++ ", but failed: " ++ Debug.toString err)


suite : Test
suite =
    describe "Zak.Internal.Library.Math"
        [ describe "cos" <|
            [ test "cos(0) is 1" <| \_ -> run "return Math.cos(0)" |> expectNumber 1
            , test "cos(pi) is -1" <| \_ -> run "return Math.cos(Math.pi)" |> expectNumber -1
            , test "cos(1) matches Elm's own cos" <| \_ -> run "return Math.cos(1)" |> expectNumber (cos 1)
            , test "wrong argument count" <|
                \_ -> run "return Math.cos(1, 2)" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            , test "wrong argument type" <|
                \_ -> run "return Math.cos(\"x\")" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            ]
        , describe "sin" <|
            [ test "sin(0) is 0" <| \_ -> run "return Math.sin(0)" |> expectNumber 0
            , test "sin(pi / 2) is 1" <| \_ -> run "return Math.sin(Math.pi / 2)" |> expectNumber 1
            , test "sin(1) matches Elm's own sin" <| \_ -> run "return Math.sin(1)" |> expectNumber (sin 1)
            , test "wrong argument count" <|
                \_ -> run "return Math.sin()" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 0 })))
            , test "wrong argument type" <|
                \_ -> run "return Math.sin(true)" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VBool True })))
            ]
        , describe "tan" <|
            [ test "tan(0) is 0" <| \_ -> run "return Math.tan(0)" |> expectNumber 0
            , test "tan(1) matches Elm's own tan" <| \_ -> run "return Math.tan(1)" |> expectNumber (tan 1)
            , test "wrong argument count" <|
                \_ -> run "return Math.tan(1, 2, 3)" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 3 })))
            , test "wrong argument type" <|
                \_ -> run "return Math.tan(nil)" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VNil })))
            ]
        , describe "acos" <|
            [ test "acos(1) is 0" <| \_ -> run "return Math.acos(1)" |> expectNumber 0
            , test "acos(0) is pi / 2" <| \_ -> run "return Math.acos(0)" |> expectNumber (pi / 2)
            , test "acos(0.5) matches Elm's own acos" <| \_ -> run "return Math.acos(0.5)" |> expectNumber (acos 0.5)
            , test "input outside [-1, 1] is a DomainError, not a silent NaN" <|
                \_ ->
                    run "return Math.acos(2)"
                        |> Expect.equal (Err (RuntimeError (DomainError "Math.acos(2) is undefined (must be between -1 and 1)")))
            , test "wrong argument count" <|
                \_ -> run "return Math.acos()" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 0 })))
            , test "wrong argument type" <|
                \_ -> run "return Math.acos(\"x\")" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            ]
        , describe "asin" <|
            [ test "asin(0) is 0" <| \_ -> run "return Math.asin(0)" |> expectNumber 0
            , test "asin(1) is pi / 2" <| \_ -> run "return Math.asin(1)" |> expectNumber (pi / 2)
            , test "asin(0.5) matches Elm's own asin" <| \_ -> run "return Math.asin(0.5)" |> expectNumber (asin 0.5)
            , test "input outside [-1, 1] is a DomainError, not a silent NaN" <|
                \_ ->
                    run "return Math.asin(-2)"
                        |> Expect.equal (Err (RuntimeError (DomainError "Math.asin(-2) is undefined (must be between -1 and 1)")))
            , test "wrong argument count" <|
                \_ -> run "return Math.asin(1, 2)" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            , test "wrong argument type" <|
                \_ -> run "return Math.asin(true)" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VBool True })))
            ]
        , describe "atan" <|
            [ test "atan(0) is 0" <| \_ -> run "return Math.atan(0)" |> expectNumber 0
            , test "atan(1) is pi / 4" <| \_ -> run "return Math.atan(1)" |> expectNumber (pi / 4)
            , test "atan(2) matches Elm's own atan" <| \_ -> run "return Math.atan(2)" |> expectNumber (atan 2)
            , test "wrong argument count" <|
                \_ -> run "return Math.atan()" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 0 })))
            , test "wrong argument type" <|
                \_ -> run "return Math.atan(nil)" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VNil })))
            ]
        , describe "atan2" <|
            [ test "atan2(1, 1) is pi / 4" <| \_ -> run "return Math.atan2(1, 1)" |> expectNumber (pi / 4)
            , test "atan2(0, 1) is 0" <| \_ -> run "return Math.atan2(0, 1)" |> expectNumber 0
            , test "atan2(1, 0) is pi / 2" <| \_ -> run "return Math.atan2(1, 0)" |> expectNumber (pi / 2)
            , test "atan2(3, 4) matches Elm's own atan2" <| \_ -> run "return Math.atan2(3, 4)" |> expectNumber (atan2 3 4)
            , test "wrong argument count (too few)" <|
                \_ -> run "return Math.atan2(1)" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            , test "wrong argument count (too many)" <|
                \_ -> run "return Math.atan2(1, 2, 3)" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 3 })))
            , test "wrong first argument type" <|
                \_ -> run "return Math.atan2(\"x\", 1)" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            , test "wrong second argument type" <|
                \_ -> run "return Math.atan2(1, \"y\")" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "y" })))
            ]
        , describe "min" <|
            [ test "min(3, 7) is 3" <| \_ -> run "return Math.min(3, 7)" |> Expect.equal (Ok (VNumber 3))
            , test "min(7, 3) is 3" <| \_ -> run "return Math.min(7, 3)" |> Expect.equal (Ok (VNumber 3))
            , test "min(5, 5) is 5" <| \_ -> run "return Math.min(5, 5)" |> Expect.equal (Ok (VNumber 5))
            , test "min(-2, 3) is -2" <| \_ -> run "return Math.min(-2, 3)" |> Expect.equal (Ok (VNumber -2))
            , test "wrong argument count (too few)" <|
                \_ -> run "return Math.min(1)" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            , test "wrong argument count (too many)" <|
                \_ -> run "return Math.min(1, 2, 3)" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 3 })))
            , test "wrong first argument type" <|
                \_ -> run "return Math.min(\"x\", 1)" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            , test "wrong second argument type" <|
                \_ -> run "return Math.min(1, \"y\")" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "y" })))
            ]
        , describe "max" <|
            [ test "max(3, 7) is 7" <| \_ -> run "return Math.max(3, 7)" |> Expect.equal (Ok (VNumber 7))
            , test "max(7, 3) is 7" <| \_ -> run "return Math.max(7, 3)" |> Expect.equal (Ok (VNumber 7))
            , test "max(5, 5) is 5" <| \_ -> run "return Math.max(5, 5)" |> Expect.equal (Ok (VNumber 5))
            , test "max(-2, 3) is 3" <| \_ -> run "return Math.max(-2, 3)" |> Expect.equal (Ok (VNumber 3))
            , test "wrong argument count (too few)" <|
                \_ -> run "return Math.max(1)" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            , test "wrong argument count (too many)" <|
                \_ -> run "return Math.max(1, 2, 3)" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 3 })))
            , test "wrong first argument type" <|
                \_ -> run "return Math.max(\"x\", 1)" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            , test "wrong second argument type" <|
                \_ -> run "return Math.max(1, \"y\")" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "y" })))
            ]
        , describe "pi (a NativeConstant, not callable at all)" <|
            [ test "Math.pi matches Elm's own pi" <| \_ -> run "return Math.pi" |> expectNumber pi
            , test "Math.pi participates in arithmetic like any other number" <|
                \_ -> run "return Math.pi * 2" |> expectNumber (pi * 2)
            , test "calling Math.pi like a function is an error, not a crash" <|
                \_ ->
                    run "return Math.pi()"
                        |> Expect.equal (Err (RuntimeError (NotAFunction (VNumber pi))))
            ]
        , describe "round" <|
            [ test "round(1.0) is 1" <| \_ -> run "return Math.round(1.0)" |> Expect.equal (Ok (VNumber 1))
            , test "round(1.2) is 1" <| \_ -> run "return Math.round(1.2)" |> Expect.equal (Ok (VNumber 1))
            , test "round(1.5) is 2" <| \_ -> run "return Math.round(1.5)" |> Expect.equal (Ok (VNumber 2))
            , test "round(1.8) is 2" <| \_ -> run "return Math.round(1.8)" |> Expect.equal (Ok (VNumber 2))

            -- ties break toward positive infinity, not away from zero:
            -- round(-1.5) is -1, not -2
            , test "round(-1.2) is -1" <| \_ -> run "return Math.round(-1.2)" |> Expect.equal (Ok (VNumber -1))
            , test "round(-1.5) is -1" <| \_ -> run "return Math.round(-1.5)" |> Expect.equal (Ok (VNumber -1))
            , test "round(-1.8) is -2" <| \_ -> run "return Math.round(-1.8)" |> Expect.equal (Ok (VNumber -2))
            , test "wrong argument count" <|
                \_ -> run "return Math.round(1, 2)" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            , test "wrong argument type" <|
                \_ -> run "return Math.round(\"x\")" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            ]
        , describe "sqrt" <|
            [ test "sqrt(16) is 4" <| \_ -> run "return Math.sqrt(16)" |> Expect.equal (Ok (VNumber 4))
            , test "sqrt(0) is 0" <| \_ -> run "return Math.sqrt(0)" |> Expect.equal (Ok (VNumber 0))
            , test "sqrt(2) matches Elm's own sqrt" <| \_ -> run "return Math.sqrt(2)" |> expectNumber (sqrt 2)
            , test "negative input is a DomainError, not a silent NaN" <|
                \_ ->
                    run "return Math.sqrt(-4)"
                        |> Expect.equal (Err (RuntimeError (DomainError "Math.sqrt(-4) is undefined (negative input)")))
            , test "wrong argument count" <|
                \_ -> run "return Math.sqrt(1, 2)" |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            , test "wrong argument type" <|
                \_ -> run "return Math.sqrt(\"x\")" |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            ]
        , describe "abs (Zak-defined, not native — lives in Math for namespace consistency, but gets its arity/type checking for free from ordinary function-call semantics)" <|
            [ test "abs on a negative number" <|
                \_ -> run "return Math.abs(-5)" |> Expect.equal (Ok (VNumber 5))
            , test "abs on a positive number and zero" <|
                \_ ->
                    Expect.all
                        [ \_ -> run "return Math.abs(5)" |> Expect.equal (Ok (VNumber 5))
                        , \_ -> run "return Math.abs(0)" |> Expect.equal (Ok (VNumber 0))
                        ]
                        ()
            , test "abs given the wrong argument type fails with the exact TypeError from its own `<` check — nobody wrote this check by hand" <|
                \_ ->
                    run "return Math.abs(\"hi\")"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 0 })))
            , test "abs given the wrong number of arguments fails with the exact WrongArgCount from ordinary function-call semantics" <|
                \_ ->
                    run "return Math.abs(1, 2)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            , test "a script can still shadow Math itself with its own let, same as any other global" <|
                \_ ->
                    run "let Math = { abs = function(n): return 999 end }\nreturn Math.abs(-5)"
                        |> Expect.equal (Ok (VNumber 999))
            ]
        ]
