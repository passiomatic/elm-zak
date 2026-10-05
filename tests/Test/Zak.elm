module Test.Zak exposing (suite)

{-| The public API, `Zak`, as a host uses it: only through `Zak` itself,
never the internal modules. The language is tested in depth by the
`Test.Zak.*` suites; this one checks that the boundary converts values,
errors and effects faithfully, both ways.
-}

import Dict
import Expect
import Test exposing (Test, describe, test)
import Zak exposing (Effect(..), Error(..), LogLevel(..), RuntimeError(..), Value(..), World)


{-| A world with `natives`, then `source` run into it. -}
runIn : List ( String, Zak.Native ) -> String -> Result Error ( Value, World )
runIn natives source =
    Zak.run source (Zak.init natives)


{-| The value `source` returns, in a world with `natives`. -}
returns : List ( String, Zak.Native ) -> String -> Result Error Value
returns natives source =
    runIn natives source |> Result.map Tuple.first


{-| A runtime error without the `WithPosition` it comes wrapped in. -}
leaf : RuntimeError -> RuntimeError
leaf error =
    case error of
        WithPosition _ inner ->
            leaf inner

        _ ->
            error


leafError : Result Error a -> Maybe RuntimeError
leafError result =
    case result of
        Err (RuntimeError error) ->
            Just (leaf error)

        _ ->
            Nothing


double : Zak.Native
double =
    Zak.nativeFunction
        (\args world ->
            case args of
                [ Number n ] ->
                    Ok ( Number (n * 2), world )

                [ other ] ->
                    Err (TypeError { expected = "Number", got = other })

                _ ->
                    Err (WrongArgCount { expected = 1, got = List.length args })
        )


{-| Queues `Effect "ping" [ the argument ]` and returns `nil`. -}
ping : Zak.Native
ping =
    Zak.nativeFunction (\args world -> Ok ( Nil, Zak.emitEffect "ping" args world ))


{-| Fails with "expected success" instead of a `Result` mismatch, so a test
can go on with the world.
-}
withWorld : Result Error ( Value, World ) -> (( Value, World ) -> Expect.Expectation) -> Expect.Expectation
withWorld result expect =
    case result of
        Ok pair ->
            expect pair

        Err error ->
            Expect.fail ("expected success, got: " ++ Zak.errorToString "" error)


suite : Test
suite =
    describe "Zak (the public API)"
        [ describe "running"
            [ test "run gives back the value of the final return" <|
                \_ -> returns [] "return 1 + 2" |> Expect.equal (Ok (Number 3))
            , test "each run sees the globals earlier runs defined" <|
                \_ ->
                    Zak.init []
                        |> Zak.run "let x = 20"
                        |> Result.andThen (\( _, world ) -> Zak.run "return x + 1" world)
                        |> Result.map Tuple.first
                        |> Expect.equal (Ok (Number 21))
            , test "a source that doesn't parse is a SyntaxError" <|
                \_ ->
                    case returns [] "let = 1" of
                        Err (SyntaxError _) ->
                            Expect.pass

                        other ->
                            Expect.fail ("expected a SyntaxError, got: " ++ Debug.toString other)
            , test "a runtime error comes back with the position of its statement" <|
                \_ ->
                    case returns [] "let a = 1\nreturn b" of
                        Err (RuntimeError (WithPosition position (UndefinedName "b"))) ->
                            Expect.equal { row = 2, col = 1 } position

                        other ->
                            Expect.fail ("expected UndefinedName at line 2, got: " ++ Debug.toString other)
            , test "include runs a file's definitions into the world, once" <|
                \_ ->
                    let
                        twice =
                            Zak.init []
                                |> Zak.include "lib.zak" "let answer = 42"
                                |> Result.andThen (\( _, world ) -> Zak.include "lib.zak" "let answer = 42" world)
                    in
                    case twice of
                        Ok ( _, world ) ->
                            Zak.getGlobal "answer" world |> Expect.equal (Just (Number 42))

                        Err error ->
                            Expect.fail ("expected success, got: " ++ Debug.toString error)
            , test "include of a file that doesn't parse is an IncludeParseError naming it" <|
                \_ ->
                    case Zak.include "bad.zak" "let = " (Zak.init []) of
                        Err (IncludeParseError path _) ->
                            Expect.equal "bad.zak" path

                        other ->
                            Expect.fail ("expected IncludeParseError, got: " ++ Debug.toString other)
            , test "two worlds reseeded alike roll alike" <|
                \_ ->
                    let
                        roll seed =
                            Zak.init []
                                |> Zak.reseed seed
                                |> Zak.run "return [Random.number(1, 1000), Random.number(1, 1000)]"
                                |> Result.map (\( value, world ) -> Zak.items value world)
                    in
                    roll 7 |> Expect.equal (roll 7)
            ]
        , describe "calling"
            [ test "call runs a script's function with arguments from the host" <|
                \_ ->
                    withWorld (runIn [] "let add = function(a, b): return a + b end") <|
                        \( _, world ) ->
                            case Zak.getGlobal "add" world of
                                Just fn ->
                                    Zak.call fn [ Number 2, Number 3 ] world
                                        |> Result.map Tuple.first
                                        |> Expect.equal (Ok (Number 5))

                                Nothing ->
                                    Expect.fail "add isn't defined"
            , test "call on a value that isn't a function is NotAFunction" <|
                \_ ->
                    Zak.call (Number 1) [] (Zak.init [])
                        |> leafError
                        |> Expect.equal (Just (NotAFunction (Number 1)))
            , test "a native can be called from the host too" <|
                \_ ->
                    let
                        world =
                            Zak.init [ ( "double", double ) ]
                    in
                    case Zak.getGlobal "double" world of
                        Just fn ->
                            Zak.call fn [ Number 4 ] world
                                |> Result.map Tuple.first
                                |> Expect.equal (Ok (Number 8))

                        Nothing ->
                            Expect.fail "double isn't defined"
            ]
        , describe "natives"
            [ test "nativeFunction gets the script's arguments and gives back its result" <|
                \_ -> returns [ ( "double", double ) ] "return double(21)" |> Expect.equal (Ok (Number 42))
            , test "an error a native raises reaches the host, with the value it carried" <|
                \_ ->
                    returns [ ( "double", double ) ] "return double(\"x\")"
                        |> leafError
                        |> Expect.equal (Just (TypeError { expected = "Number", got = String "x" }))
            , test "a table passed to a native and back is the same table" <|
                \_ ->
                    let
                        identity =
                            Zak.nativeFunction
                                (\args world ->
                                    case args of
                                        [ value ] ->
                                            Ok ( value, world )

                                        _ ->
                                            Ok ( Nil, world )
                                )
                    in
                    returns [ ( "identity", identity ) ] "let t = { x = 1 }\nidentity(t).x = 2\nreturn t.x"
                        |> Expect.equal (Ok (Number 2))
            , test "a function passed to a native can be called back" <|
                \_ ->
                    let
                        apply =
                            Zak.nativeFunction
                                (\args world ->
                                    case args of
                                        [ fn, value ] ->
                                            Zak.call fn [ value ] world
                                                |> Result.mapError (\_ -> InternalError "call failed")

                                        _ ->
                                            Ok ( Nil, world )
                                )
                    in
                    returns [ ( "apply", apply ) ] "return apply(function(x): return x * 10 end, 4)"
                        |> Expect.equal (Ok (Number 40))
            , test "nativeTable groups natives behind a dot" <|
                \_ ->
                    returns [ ( "Util", Zak.nativeTable [ ( "double", double ), ( "seven", Zak.nativeConstant (Number 7) ) ] ) ] "return Util.double(Util.seven)"
                        |> Expect.equal (Ok (Number 14))
            , test "nativeExpression is a native written in Zak" <|
                \_ ->
                    returns [ ( "triple", Zak.nativeExpression "function(n): return n * 3 end" ) ] "return triple(5)"
                        |> Expect.equal (Ok (Number 15))
            , test "a broken nativeExpression is left undefined, and logged by name" <|
                \_ ->
                    case Zak.takeEffects (Zak.init [ ( "broken", Zak.nativeExpression "function(:" ) ]) of
                        ( [ Log LogError message ], world ) ->
                            Expect.all
                                [ \_ -> message |> String.startsWith "native “broken” is left undefined" |> Expect.equal True
                                , \_ -> Zak.getGlobal "broken" world |> Expect.equal Nothing
                                ]
                                ()

                        other ->
                            Expect.fail ("expected one LogError, got: " ++ Debug.toString (Tuple.first other))
            ]
        , describe "data"
            [ test "getGlobal reads a script's global, and a native" <|
                \_ ->
                    withWorld (runIn [ ( "seven", Zak.nativeConstant (Number 7) ) ] "let name = \"Zak\"") <|
                        \( _, world ) ->
                            ( Zak.getGlobal "name" world, Zak.getGlobal "seven" world, Zak.getGlobal "missing" world )
                                |> Expect.equal ( Just (String "Zak"), Just (Number 7), Nothing )
            , test "setGlobal defines a new global the scripts can read" <|
                \_ ->
                    Zak.init []
                        |> Zak.setGlobal "greeting" (String "hi")
                        |> Zak.run "return greeting"
                        |> Result.map Tuple.first
                        |> Expect.equal (Ok (String "hi"))
            , test "setGlobal changes a script's own global" <|
                \_ ->
                    withWorld (runIn [] "let score = 1\nlet read = function(): return score end") <|
                        \( _, world ) ->
                            world
                                |> Zak.setGlobal "score" (Number 2)
                                |> Zak.run "return read()"
                                |> Result.map Tuple.first
                                |> Expect.equal (Ok (Number 2))
            , test "setGlobal on a name declared as a native is seen by a nativeExpression" <|
                \_ ->
                    Zak.init [ ( "_current", Zak.nativeConstant Nil ), ( "current", Zak.nativeExpression "function(): return _current end" ) ]
                        |> Zak.setGlobal "_current" (String "Diner")
                        |> Zak.run "return current()"
                        |> Result.map Tuple.first
                        |> Expect.equal (Ok (String "Diner"))
            , test "newTable makes a table the scripts can read" <|
                \_ ->
                    let
                        ( point, world ) =
                            Zak.newTable [ ( "x", Number 10 ), ( "y", Number 20 ) ] (Zak.init [])
                    in
                    world
                        |> Zak.setGlobal "point" point
                        |> Zak.run "return point.x + point.y"
                        |> Result.map Tuple.first
                        |> Expect.equal (Ok (Number 30))
            , test "getField, setField and fields read and change a script's table" <|
                \_ ->
                    withWorld (runIn [] "return { a = 1 }") <|
                        \( table, world ) ->
                            let
                                world1 =
                                    Zak.setField "b" (Bool True) table world
                            in
                            ( Zak.getField "a" table world1, Zak.getField "nope" table world1, Zak.fields table world1 )
                                |> Expect.equal ( Just (Number 1), Nothing, Just (Dict.fromList [ ( "a", Number 1 ), ( "b", Bool True ) ]) )
            , test "the table functions treat anything but a table as having no fields" <|
                \_ ->
                    let
                        world =
                            Zak.init []
                    in
                    ( Zak.getField "x" (Number 1) world, Zak.fields Nil world, Zak.threadCount (Zak.setField "x" Nil Nil world) )
                        |> Expect.equal ( Nothing, Nothing, 0 )
            , test "items reads a script's array, in order" <|
                \_ ->
                    withWorld (runIn [] "return [1, \"two\", nil]") <|
                        \( array, world ) ->
                            Zak.items array world |> Expect.equal (Just [ Number 1, String "two", Nil ])
            ]
        , describe "threads"
            [ test "threadCount counts the waiting threads, and tick advances them" <|
                \_ ->
                    withWorld (runIn [] "Thread.start(function(): Thread.wait_for(1.0) end)") <|
                        \( _, world ) ->
                            let
                                ( _, world1 ) =
                                    Zak.tick 1.0 world
                            in
                            ( Zak.threadCount world, Zak.threadCount world1 ) |> Expect.equal ( 1, 0 )
            , test "tick gives back the errors of failed threads, in the order they failed" <|
                \_ ->
                    withWorld (runIn [] "Thread.start(function(): Thread.wait_for(1.0)\nreturn first end)\nThread.start(function(): Thread.wait_for(1.0)\nreturn second end)") <|
                        \( _, world ) ->
                            Zak.tick 1.0 world
                                |> Tuple.first
                                |> List.map leaf
                                |> Expect.equal [ UndefinedName "first", UndefinedName "second" ]
            , test "stopLocalThreads keeps only the global threads" <|
                \_ ->
                    withWorld (runIn [] "Thread.start(function(): Thread.wait_for(1.0) end)\nThread.start_global(function(): Thread.wait_for(1.0) end)") <|
                        \( _, world ) ->
                            Zak.threadCount (Zak.stopLocalThreads world) |> Expect.equal 1
            ]
        , describe "effects"
            [ test "logs and a native's effects come back in one queue, in order, and the queue empties" <|
                \_ ->
                    withWorld (runIn [ ( "ping", ping ) ] "Debug.log(\"a\")\nping(1)\nDebug.log_warning(\"b\")") <|
                        \( _, world ) ->
                            let
                                ( effects, world1 ) =
                                    Zak.takeEffects world
                            in
                            ( effects, Tuple.first (Zak.takeEffects world1) )
                                |> Expect.equal ( [ Log LogPrint "a", Effect "ping" [ Number 1 ], Log LogWarning "b" ], [] )
            ]
        , describe "errors"
            [ test "errorToString shows the line and a caret when given the source" <|
                \_ ->
                    case returns [] "let a = 1\nreturn b" of
                        Err error ->
                            Zak.errorToString "let a = 1\nreturn b" error
                                |> Expect.equal "Runtime error at line 2, column 1:\n\n    return b\n    ^\n\n“b” is not defined"

                        Ok _ ->
                            Expect.fail "expected an error"
            , test "errorToString with no source is one line" <|
                \_ ->
                    case returns [] "let a = 1\nreturn b" of
                        Err error ->
                            Zak.errorToString "" error
                                |> Expect.equal "Runtime error at line 2, column 1: “b” is not defined"

                        Ok _ ->
                            Expect.fail "expected an error"
            ]
        ]
