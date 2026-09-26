module Test.Zak.Debug exposing (suite)

import Dict
import Expect
import Test exposing (Test, describe, test)
import Zak.Debug as ZakDebug
import Zak.Interpreter as I exposing (Error(..))
import Zak.Runtime as Runtime exposing (LogLevel(..), RuntimeError(..), State, Value(..))


{-| `Debug` is seeded by `Zak.Interpreter.run` itself now, automatically —
no natives need passing in here at all.

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


{-| `runExpr` deliberately does *not* auto-include `Debug` (see
`Zak.Interpreter`'s own doc) — so unlike `run` above, this still has to
pass `ZakDebug.natives` in by hand to exercise it here.
-}
runExpr : String -> Result Error Value
runExpr =
    I.runExpr ZakDebug.natives


{-| Same pattern `Test.Zak.Thread`'s own `runWithState` uses, for the
same reason: `run`/`runExpr` above both discard `State`, but the logging
tests below need to inspect `state.pendingLogs` directly, not just a
script's own return value.
-}
runWithState : String -> Result Error ( Value, State )
runWithState source =
    let
        ( env, state ) =
            I.initialWorld Dict.empty
    in
    I.runIncremental env state source


suite : Test
suite =
    describe "Zak.Debug (log, log_debug, log_info, log_warning, log_error, assert)" <|
        [ describe "log" <|
            [ test "logging a string returns nil" <|
                \_ -> run "return Debug.log(\"Hi there!\")" |> Expect.equal (Ok VNil)
            , test "wrong argument type" <|
                \_ ->
                    run "return Debug.log(1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    run "return Debug.log(\"a\", \"b\")"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            ]
        , describe "log_debug/log_info/log_warning/log_error (same shape as log, one shared logNative parameterized by level — see 'logging queues a LogEntry' below for the part that's actually new)" <|
            [ test "log_debug returns nil" <| \_ -> run "return Debug.log_debug(\"x\")" |> Expect.equal (Ok VNil)
            , test "log_info returns nil" <| \_ -> run "return Debug.log_info(\"x\")" |> Expect.equal (Ok VNil)
            , test "log_warning returns nil" <| \_ -> run "return Debug.log_warning(\"x\")" |> Expect.equal (Ok VNil)
            , test "log_error returns nil" <| \_ -> run "return Debug.log_error(\"x\")" |> Expect.equal (Ok VNil)
            , test "wrong argument type, using log_debug as the representative case" <|
                \_ ->
                    run "return Debug.log_debug(1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong argument count, using log_warning as the representative case" <|
                \_ ->
                    run "return Debug.log_warning(\"a\", \"b\")"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            ]
        , describe "logging queues a LogEntry in state.pendingLogs, drained via Zak.Interpreter.drainLogs — no Debug.log anywhere in this module's own Elm code" <|
            [ test "log tags its entry LogPrint" <|
                \_ ->
                    case runWithState "Debug.log(\"hi\")\nreturn nil" of
                        Ok ( _, state ) ->
                            state.pendingLogs |> Expect.equal [ { level = LogPrint, message = "hi" } ]

                        Err error ->
                            Expect.fail ("expected success, got: " ++ Debug.toString error)
            , test "log_debug/log_info/log_warning/log_error each tag their entry with their own LogLevel" <|
                \_ ->
                    case runWithState "Debug.log_debug(\"a\")\nDebug.log_info(\"b\")\nDebug.log_warning(\"c\")\nDebug.log_error(\"d\")\nreturn nil" of
                        Ok ( _, state ) ->
                            state.pendingLogs
                                |> Expect.equal
                                    [ { level = LogDebug, message = "a" }
                                    , { level = LogInfo, message = "b" }
                                    , { level = LogWarning, message = "c" }
                                    , { level = LogError, message = "d" }
                                    ]

                        Err error ->
                            Expect.fail ("expected success, got: " ++ Debug.toString error)
            , test "multiple calls accumulate in call order, not reversed" <|
                \_ ->
                    case runWithState "Debug.log(\"first\")\nDebug.log(\"second\")\nDebug.log(\"third\")\nreturn nil" of
                        Ok ( _, state ) ->
                            List.map .message state.pendingLogs |> Expect.equal [ "first", "second", "third" ]

                        Err error ->
                            Expect.fail ("expected success, got: " ++ Debug.toString error)
            , test "nothing is queued if no logging native was ever called" <|
                \_ ->
                    case runWithState "return 1" of
                        Ok ( _, state ) ->
                            state.pendingLogs |> Expect.equal []

                        Err error ->
                            Expect.fail ("expected success, got: " ++ Debug.toString error)
            , test "drainLogs returns the queued entries and clears the queue" <|
                \_ ->
                    case runWithState "Debug.log(\"a\")\nDebug.log(\"b\")\nreturn nil" of
                        Ok ( _, state ) ->
                            let
                                ( drained, state1 ) =
                                    I.drainLogs state
                            in
                            Expect.all
                                [ \_ -> List.map .message drained |> Expect.equal [ "a", "b" ]
                                , \_ -> state1.pendingLogs |> Expect.equal []
                                ]
                                ()

                        Err error ->
                            Expect.fail ("expected success, got: " ++ Debug.toString error)
            , test "a second drainLogs call after an empty run returns nothing — the queue doesn't leak entries from a previous drain" <|
                \_ ->
                    case runWithState "Debug.log(\"only once\")\nreturn nil" of
                        Ok ( _, state ) ->
                            let
                                ( _, state1 ) =
                                    I.drainLogs state

                                ( secondDrain, _ ) =
                                    I.drainLogs state1
                            in
                            secondDrain |> Expect.equal []

                        Err error ->
                            Expect.fail ("expected success, got: " ++ Debug.toString error)
            ]
        , describe "assert (expr, message — message optional)" <|
            [ test "a true expr with a message does nothing, returns nil" <|
                \_ -> runExpr "Debug.assert(true, \"should not fire\")" |> Expect.equal (Ok VNil)
            , test "a true expr with no message also does nothing, returns nil" <|
                \_ -> runExpr "Debug.assert(true)" |> Expect.equal (Ok VNil)
            , test "a false expr with a message fails with that exact message" <|
                \_ ->
                    runExpr "Debug.assert(false, \"one is not two\")"
                        |> Expect.equal (Err (RuntimeError (AssertionFailed "one is not two")))
            , test "a false expr with no message fails with the default message \"assertion failed\"" <|
                \_ ->
                    runExpr "Debug.assert(false)"
                        |> Expect.equal (Err (RuntimeError (AssertionFailed "assertion failed")))
            , test "wrong type for expr — must be a real Bool, no truthy coercion" <|
                \_ ->
                    runExpr "Debug.assert(1, \"msg\")"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Bool", got = VNumber 1 })))
            , test "wrong type for message" <|
                \_ ->
                    runExpr "Debug.assert(true, 1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "too few arguments — zero" <|
                \_ ->
                    runExpr "Debug.assert()"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 0 })))
            , test "too many arguments — three" <|
                \_ ->
                    runExpr "Debug.assert(true, \"a\", \"b\")"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 3 })))
            ]
        ]
