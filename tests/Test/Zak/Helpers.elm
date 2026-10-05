module Test.Zak.Helpers exposing (suite)

import Dict
import Expect
import Test exposing (Test, describe, test)
import Zak.Helpers as H
import Zak.Internal.Interpreter as I


{-| The message a user actually sees for `source`, or `""` if it runs.
-}
errorMessage : String -> String
errorMessage source =
    case I.run Dict.empty source of
        Ok _ ->
            ""

        Err error ->
            H.formatError source error


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


throwawayMessage : String
throwawayMessage =
    "“_” is a throwaway name and can't be used as a value"


suite : Test
suite =
    describe "Zak.Helpers"
        [ describe "formatError: a syntax error is reported where it happens, in any statement of any block -- not swallowed into a generic \"expected the end of the program\" at the start of its line" <|
            List.map testSyntaxError
                [ ( "print(1 +)", ( 1, 10 ), "" )
                , ( "let x = 1\nprint(1 +)", ( 2, 10 ), "" )
                , ( "let x = 1\nlet if = 2", ( 2, 7 ), "\"if\" is a reserved word, not a valid identifier" )
                , ( "let x = 1\nprint(_)", ( 2, 7 ), throwawayMessage )
                , ( "let t = {}\n_.x = 1", ( 2, 1 ), throwawayMessage )

                -- nested: the second statement of an if body, where the
                -- if is itself the second statement of its block
                , ( "let x = 1\nif true:\n    let y = 2\n    print(_)\nend", ( 4, 11 ), throwawayMessage )
                , ( "let f = function():\n    let y = 2\n    return y +\nend", ( 3, 15 ), "" )
                ]
        , describe "formatError: a failed chompIf (a name, number or string) never shows up as a vague \"something else here\" -- each case says what was expected" <|
            List.map testSyntaxError
                [ ( "return y +", ( 1, 11 ), "expected an expression" )
                , ( "let x = )", ( 1, 9 ), "expected an expression" )
                , ( "print(1,)", ( 1, 9 ), "expected an expression" )
                , ( "let t = { x = }", ( 1, 15 ), "expected an expression" )
                , ( "let 1 = 2", ( 1, 5 ), "expected a name" )
                , ( "const = 2", ( 1, 7 ), "expected a name" )
                , ( "for 1 in x:\nend", ( 1, 5 ), "expected a name" )
                , ( "let f = function(a, 1): return 1 end", ( 1, 21 ), "expected a name" )
                , ( "let x = t.1", ( 1, 11 ), "expected a name" )
                , ( "let t = { a = 1, 2 = 3 }", ( 1, 18 ), "expected a name" )
                , ( "let s = \"abc", ( 1, 13 ), "this string is missing its closing “\"”" )
                , ( "let x = 1.", ( 1, 11 ), "expected a digit after the decimal point" )

                -- the generic list stays when it's the whole story
                , ( "let s = \"a\\q\"", ( 1, 12 ), "expected “\"”, or “\\”" )
                ]
        , describe "formatError: a line no statement can start with still gets the generic message, at that line" <|
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
                , "let f = function():\n    let a = 1\n    return a\nend\nlet b = f()"
                ]
        ]
