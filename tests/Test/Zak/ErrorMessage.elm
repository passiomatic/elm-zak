module Test.Zak.ErrorMessage exposing (suite)

import Expect
import Test exposing (Test, describe, test)
import Zak


{-| The message a user actually sees for `source`, or `""` if it runs.
-}
errorMessage : String -> String
errorMessage source =
    case Zak.run source (Zak.init () []) of
        Ok _ ->
            ""

        Err error ->
            Zak.errorToString source error


{-| `source`'s error must be reported at (`row`, `col`), with a message
ending in `message`.
-}
testSyntaxError : ( String, ( Int, Int ), String ) -> Test
testSyntaxError ( source, ( row, col ), message ) =
    test (String.replace "\n" "\\n" source) <|
        \_ ->
            let
                actual =
                    errorMessage source
            in
            Expect.all
                [ \s -> s |> String.startsWith ("Syntax error at line " ++ String.fromInt row ++ ", column " ++ String.fromInt col ++ ":") |> Expect.equal True |> Expect.onFail actual
                , \s -> s |> String.endsWith message |> Expect.equal True |> Expect.onFail actual
                ]
                actual


{-| `source`'s error message must end in `message`.
-}
testErrorMessage : ( String, String ) -> Test
testErrorMessage ( source, message ) =
    test (String.replace "\n" "\\n" source) <|
        \_ ->
            let
                actual =
                    errorMessage source
            in
            actual |> String.endsWith message |> Expect.equal True |> Expect.onFail actual


throwawayMessage : String
throwawayMessage =
    "“_” is a throwaway name and can't be used as a value"


suite : Test
suite =
    describe "Zak.Internal.ErrorMessage, through Zak.errorToString"
        [ describe "errorToString: a syntax error is reported where it happens, in any statement of any block -- not swallowed into a generic \"expected the end of the program\" at the start of its line" <|
            List.map testSyntaxError
                [ ( "print(1 +)", ( 1, 10 ), "" )
                , ( "let x = 1\nprint(1 +)", ( 2, 10 ), "" )
                , ( "let x = 1\nlet if = 2", ( 2, 7 ), "\"if\" is a reserved word, not a valid identifier" )
                , ( "let x = 1\nprint(_)", ( 2, 7 ), throwawayMessage )
                , ( "let t = {}\n_.x = 1", ( 2, 1 ), throwawayMessage )

                -- nested: the second statement of an if body, where the
                -- if is itself the second statement of its block
                , ( "let x = 1\nif true:\n    let y = 2\n    print(_)\nend", ( 4, 11 ), throwawayMessage )
                , ( "let f = fn():\n    let y = 2\n    return y +\nend", ( 3, 15 ), "" )
                ]
        , describe "errorToString: a failed chompIf (a name, number or string) never shows up as a vague \"something else here\" -- each case says what was expected" <|
            List.map testSyntaxError
                [ ( "return y +", ( 1, 11 ), "expected an expression" )
                , ( "let x = )", ( 1, 9 ), "expected an expression" )
                , ( "print(1,)", ( 1, 9 ), "expected an expression" )
                , ( "let t = { x = }", ( 1, 15 ), "expected an expression" )
                , ( "let 1 = 2", ( 1, 5 ), "expected a name" )
                , ( "const = 2", ( 1, 7 ), "expected a name" )
                , ( "for 1 in x:\nend", ( 1, 5 ), "expected a name" )
                , ( "let f = fn(a, 1): return 1 end", ( 1, 15 ), "expected a name" )
                , ( "let x = t.1", ( 1, 11 ), "expected a name" )
                , ( "let t = { a = 1, 2 = 3 }", ( 1, 18 ), "expected a name" )
                , ( "let s = \"abc", ( 1, 13 ), "this string is missing its closing “\"”" )
                , ( "let x = 1.", ( 1, 11 ), "expected a digit after the decimal point" )
                , ( "let s = \"a\\q\"", ( 1, 12 ), "“\\q” isn't an escape: in a string, “\\” can only start “\\\"”, “\\\\”, “\\n” or “\\t”" )
                , ( "let s = \"a\\", ( 1, 12 ), "this string is missing its closing “\"”" )

                -- the generic message stays when it's the whole story
                , ( "print(1 2)", ( 1, 9 ), "expected “)”" )
                ]
        , describe "errorToString: a format error names no function, since String.format and Debug.log share one formatter" <|
            List.map testErrorMessage
                [ ( "String.format(\"%s and %s\", [\"a\"])", "the format expected 2 values, got 1" )
                , ( "Debug.log_warning(\"%s\", \"a\", \"b\")", "the format expected 1 value, got 2" )
                , ( "Debug.log(\"%q %s\", 1)", "unknown format directive “%q”" )
                ]
        , describe "errorToString: NotAnInteger names the number, since it's not always an index" <|
            List.map testErrorMessage
                [ ( "let a = [1]\nreturn a[0.5]", "\n\n0.5 is not a whole number" )
                , ( "return Array.range(1, 2.5)", "\n\n2.5 is not a whole number" )
                ]
        , describe "errorToString: `function`, the keyword before `fn`, says so, on the word itself; `fn` is reserved" <|
            List.map testSyntaxError
                [ ( "let f = function(x): return x end", ( 1, 9 ), "“function” is now “fn”" )
                , ( "let x = 1\nfunction(): return 1 end", ( 2, 1 ), "“function” is now “fn”" )
                , ( "Array.map([1], function(x): return x end)", ( 1, 16 ), "“function” is now “fn”" )
                , ( "let fn = 1", ( 1, 7 ), "\"fn\" is a reserved word, not a valid identifier" )
                ]
        , describe "a name that only starts with `function` or `fn` is an ordinary name" <|
            List.map
                (\source -> test source <| \_ -> errorMessage source |> Expect.equal "")
                [ "let functional = 1\nreturn functional"
                , "let fnord = fn(): return 1 end\nreturn fnord()"
                , "let function_name = \"x\"\nreturn function_name"
                ]
        , describe "errorToString: a line no statement can start with still gets the generic message, at that line" <|
            List.map testSyntaxError
                [ ( "let x = 1\n)", ( 2, 1 ), "expected the end of the program" )
                ]
        , describe "blocks still end cleanly at end, else, else if, and the end of input, with trailing blank lines and comments" <|
            List.map
                (\source -> test (String.replace "\n" "\\n" source) <| \_ -> errorMessage source |> Expect.equal "")
                [ "let x = 1\nlet y = 2"
                , "let x = 1\nlet y = 2\n"
                , "let x = 1\nlet y = 2\n\n# done\n\n"
                , "if true:\n    let a = 1\n    let b = 2\nend"
                , "if true:\n    let a = 1\n    let b = 2\n    # trailing\n\nelse:\n    let c = 3\n    let d = 4\nend"
                , "if false:\n    let a = 1\n    let b = 2\nelse if true:\n    let c = 3\n    let d = 4\nend"
                , "let i = 0\nwhile i < 2:\n    i = i + 1\n    continue\nend"
                , "let f = fn():\n    let a = 1\n    return a\nend\nlet b = f()"
                ]
        ]
