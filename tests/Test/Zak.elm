module Test.Zak exposing (suite)

{-| The public API, `Zak`, as a host uses it: only through `Zak` itself,
never the internal modules. The language is tested in depth by the
`Test.Zak.*` suites; this one checks that the boundary converts values,
errors and effects faithfully, both ways.
-}

import Dict
import Expect
import Test exposing (Test, describe, test)
import Zak exposing (Effect(..), Error, LogLevel(..), Problem(..), Value(..), World)


{-| A world with `natives`, then `source` run into it. -}
runIn : List ( String, Zak.Native ) -> String -> Result Error ( Value, World )
runIn natives source =
    Zak.run source (Zak.init natives)


{-| The value `source` returns, in a world with `natives`. -}
returns : List ( String, Zak.Native ) -> String -> Result Error Value
returns natives source =
    runIn natives source |> Result.map Tuple.first


{-| What went wrong, if anything. -}
problem : Result Error a -> Maybe Problem
problem result =
    case result of
        Err error ->
            Just (Zak.errorProblem error)

        Ok _ ->
            Nothing


{-| A world with `files` to include, then `source` run into it. -}
withFiles : List ( String, String ) -> String -> Result Error ( Value, World )
withFiles files source =
    runIn [ ( "include", Zak.nativeInclude (\path -> Dict.get path (Dict.fromList files)) ) ] source


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
                        Err error ->
                            ( Zak.errorProblem error, Zak.errorPosition error )
                                |> Expect.equal ( SyntaxError "expected a name", Just { row = 1, col = 5 } )

                        Ok _ ->
                            Expect.fail "expected a SyntaxError"
            , test "a runtime error comes back with the position of its statement" <|
                \_ ->
                    case returns [] "let a = 1\nreturn b" of
                        Err error ->
                            ( Zak.errorProblem error, Zak.errorPosition error )
                                |> Expect.equal ( UndefinedName "b", Just { row = 2, col = 1 } )

                        Ok _ ->
                            Expect.fail "expected UndefinedName"
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
                        |> problem
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
                        |> problem
                        |> Expect.equal (Just (TypeError { expected = "Number", got = String "x" }))
            , test "a Problem a native raises reaches the host as it was, at the native's call" <|
                \_ ->
                    let
                        refuse =
                            Zak.nativeFunction (\_ _ -> Err (Problem "not today"))
                    in
                    case returns [ ( "refuse", refuse ) ] "let a = 1\nrefuse()" of
                        Err error ->
                            ( Zak.errorProblem error, Zak.errorPosition error, Zak.errorToString "" error )
                                |> Expect.equal ( Problem "not today", Just { row = 2, col = 1 }, "Runtime error at line 2, column 1: not today" )

                        Ok _ ->
                            Expect.fail "expected an error"
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
                                                |> Result.mapError Zak.errorProblem

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
        , describe "including"
            [ test "nativeInclude runs a file's definitions into the world" <|
                \_ ->
                    withFiles [ ( "lib.zak", "let answer = 42" ) ] "include(\"lib.zak\")\nreturn answer"
                        |> Result.map Tuple.first
                        |> Expect.equal (Ok (Number 42))
            , test "a file is included once, which also stops include cycles" <|
                \_ ->
                    withFiles
                        [ ( "a.zak", "include(\"b.zak\")\nlet from_a = 1" )
                        , ( "b.zak", "include(\"a.zak\")\nlet from_b = 2" )
                        ]
                        "include(\"a.zak\")\ninclude(\"a.zak\")\nreturn from_a + from_b"
                        |> Result.map Tuple.first
                        |> Expect.equal (Ok (Number 3))
            , test "a path the host doesn't know is IncludeNotFound" <|
                \_ ->
                    withFiles [] "include(\"missing.zak\")"
                        |> problem
                        |> Expect.equal (Just (IncludeNotFound "missing.zak"))
            , test "include takes one String" <|
                \_ ->
                    ( withFiles [] "include(1)" |> problem, withFiles [] "include()" |> problem )
                        |> Expect.equal
                            ( Just (TypeError { expected = "String", got = Number 1 })
                            , Just (WrongArgCount { expected = 1, got = 0 })
                            )
            , test "a file that doesn't parse is a SyntaxError naming it, at the include line" <|
                \_ ->
                    case withFiles [ ( "bad.zak", "let = 1" ) ] "let a = 1\ninclude(\"bad.zak\")" of
                        Err error ->
                            ( Zak.errorProblem error, Zak.errorPosition error )
                                |> Expect.equal ( SyntaxError "“bad.zak” failed to parse at line 1, column 5: expected a name", Just { row = 2, col = 1 } )

                        Ok _ ->
                            Expect.fail "expected a SyntaxError"
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
            , test "globals lists the scripts' top-level definitions and setGlobal's, not the natives" <|
                \_ ->
                    withWorld (runIn [ ( "seven", Zak.nativeConstant (Number 7) ) ] "let a = 1\nlet f = function(): let local = 2 end") <|
                        \( _, world ) ->
                            world
                                |> Zak.setGlobal "b" (Bool True)
                                |> Zak.globals
                                |> Dict.keys
                                |> Expect.equal [ "a", "b", "f" ]
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
                                |> List.map Zak.errorProblem
                                |> Expect.equal [ UndefinedName "first", UndefinedName "second" ]
            , test "stopThreads stops one owner's threads, and hasThreads tells which owners still have some" <|
                \_ ->
                    let
                        start world =
                            Zak.run "Thread.start(function(): Thread.wait_for(1.0) end)" world |> Result.map Tuple.second
                    in
                    Zak.init []
                        |> Zak.setThreadOwner "level"
                        |> start
                        |> Result.map (Zak.setThreadOwner "music")
                        |> Result.andThen start
                        |> Result.map (Zak.stopThreads "level")
                        |> Result.map (\world -> ( Zak.threadCount world, Zak.hasThreads "level" world, Zak.hasThreads "music" world ))
                        |> Expect.equal (Ok ( 1, False, True ))
            , test "startThread runs a function as a thread of the given owner" <|
                \_ ->
                    withWorld (runIn [] "return function(): Thread.wait_for(1.0) end") <|
                        \( fn, world ) ->
                            Zak.startThread "cutscene" fn [] world
                                |> Result.map (Tuple.second >> Zak.hasThreads "cutscene")
                                |> Expect.equal (Ok True)
            , test "startThread gives back the thread's id, which a script can join" <|
                \_ ->
                    let
                        startAsCutscene =
                            Zak.nativeFunction
                                (\args world ->
                                    case args of
                                        [ fn ] ->
                                            Zak.startThread "cutscene" fn [] world |> Result.mapError Zak.errorProblem

                                        _ ->
                                            Err (WrongArgCount { expected = 1, got = List.length args })
                                )

                        source =
                            "let log = { value = \"waiting\" }\nThread.start(function():\n    Thread.join(start_as_cutscene(function(): Thread.wait_for(1.0) end))\n    log.value = \"joined\"\nend)\nreturn log"

                        logAfter seconds ( log, world ) =
                            List.foldl (\dt w -> Zak.tick dt w |> Tuple.second) world seconds
                                |> (\w -> Zak.getField "value" log w)
                    in
                    withWorld (runIn [ ( "start_as_cutscene", startAsCutscene ) ] source) <|
                        \started ->
                            ( logAfter [] started, logAfter [ 1.0, 0 ] started )
                                |> Expect.equal ( Just (String "waiting"), Just (String "joined") )
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
            [ test "the standard library's own checks are a Problem with their message" <|
                \_ ->
                    returns [] "return Array.pop([])"
                        |> problem
                        |> Expect.equal (Just (Problem "the array is empty"))
            , test "errorToString shows the line and a caret when given the source" <|
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
