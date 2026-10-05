module Test.Zak.Lexer exposing (suite)

import Expect
import Parser as P
import Test exposing (Test, describe, test)
import Zak.Internal.Lexer as L


{-| Table-driven positive/negative case runner, following the "Tiny
Interpreters" `Test.Lib.testValue` convention: a `Just` expected value means
the input must parse successfully to that value, `Nothing` means the input
must fail to parse. `matches` decides equality for the parsed value (plain
`Expect.equal` for most types, `Expect.within` for `Float`).
-}
testValue : (a -> a -> Expect.Expectation) -> (String -> Result e a) -> ( String, Maybe a ) -> Test
testValue matches run ( input, expected ) =
    test (Debug.toString input) <|
        \_ ->
            case ( run input, expected ) of
                ( Ok actual, Just wanted ) ->
                    matches wanted actual

                ( Ok actual, Nothing ) ->
                    Expect.fail ("expected a parse failure, but got: " ++ Debug.toString actual)

                ( Err _, Nothing ) ->
                    Expect.pass

                ( Err err, Just wanted ) ->
                    Expect.fail
                        ("expected "
                            ++ Debug.toString wanted
                            ++ ", but parsing failed: "
                            ++ Debug.toString err
                        )


floatEqual : Float -> Float -> Expect.Expectation
floatEqual =
    Expect.within (Expect.Absolute 0.000001)


suite : Test
suite =
    describe "Zak.Internal.Lexer"
        [ describe "number" <|
            List.map (testValue floatEqual (P.run L.number))
                [ ( "1", Just 1.0 )
                , ( "1.0", Just 1.0 )
                , ( "0.99", Just 0.99 )
                , ( "42 ", Just 42.0 )
                , ( "1.0abc", Just 1.0 )
                , ( "-5", Nothing )
                , ( ".5", Nothing )
                , ( "1.", Nothing )
                , ( "abc", Nothing )
                , ( "", Nothing )
                ]
        , describe "string" <|
            List.map (testValue Expect.equal (P.run L.string))
                [ ( "\"This is a sample string\"", Just "This is a sample string" )
                , ( "\"\"", Just "" )
                , ( "\"This is a \\\"quote\\\" inside a string\"", Just "This is a \"quote\" inside a string" )
                , ( "\"This is a \\\\ inside a string\"", Just "This is a \\ inside a string" )
                , ( "\"unterminated", Nothing )
                , ( "\"bad escape: \\n\"", Nothing )

                -- "'" is no longer a delimiter at all -- an unescaped
                -- apostrophe inside a double-quoted string is just an
                -- ordinary character, the one practical need
                -- single-quoted strings used to serve, still covered
                -- with no special handling needed
                , ( "\"it's fine\"", Just "it's fine" )

                -- still fails, but now because the closing "\"" is never
                -- found (an unterminated string) -- not because "'" was
                -- ever a recognized-but-mismatched delimiter type, since
                -- it isn't a delimiter at all anymore
                , ( "\"mismatched quotes'", Nothing )
                , ( "no quotes at all", Nothing )
                , ( "", Nothing )
                ]
        , describe "identifier" <|
            List.map (testValue Expect.equal (P.run L.identifier))
                [ ( "Taylor", Just "Taylor" )
                , ( "intro_scene", Just "intro_scene" )
                , ( "bank123", Just "bank123" )
                , ( "CityClock", Just "CityClock" )
                , ( "Taylor ", Just "Taylor" )
                , ( "Taylor.health", Just "Taylor" )

                -- a trailing "?" is a legal (single, final) identifier character
                , ( "foo?", Just "foo?" )
                , ( "empty?", Just "empty?" )
                , ( "foo? ", Just "foo?" )
                , ( "foo?.bar", Just "foo?" )
                , ( "a?", Just "a?" )
                , ( "?foo", Nothing )

                -- only a single trailing "?" is consumed — leftover input is
                -- fine (P.run doesn't require full consumption, same as the
                -- "Taylor.health" case above), but the parsed value proves
                -- identifier itself never swallows a second "?" or one that
                -- isn't at the point where the letter/digit/underscore run stops
                , ( "foo??", Just "foo?" )
                , ( "fo?o", Just "fo?" )

                -- the reserved-word check applies to the whole identifier,
                -- including the suffix — "let?" is not the reserved word
                -- "let", so it's a valid identifier in its own right
                , ( "let?", Just "let?" )

                -- "!" is not an identifier character at all, trailing or
                -- otherwise — it's reserved for the "!=" inequality
                -- operator, so "done!=x" must lex as "done" followed by
                -- "!=", never as a name "done!" followed by "=". Leftover
                -- input is fine here (same as "foo??" above): the parsed
                -- value proves identifier stops right before the "!"
                , ( "push!", Just "push" )
                , ( "done!=x", Just "done" )
                , ( "push!.bar", Just "push" )
                , ( "!foo", Nothing )
                , ( "let!", Nothing )
                , ( "foo?!", Just "foo?" )

                -- reserved words are not valid identifiers
                , ( "let", Nothing )
                , ( "if", Nothing )
                , ( "else", Nothing )
                , ( "end", Nothing )
                , ( "while", Nothing )
                , ( "for", Nothing )
                , ( "in", Nothing )
                , ( "return", Nothing )
                , ( "and", Nothing )
                , ( "or", Nothing )
                , ( "not", Nothing )
                , ( "function", Nothing )
                , ( "break", Nothing )
                , ( "continue", Nothing )

                -- must start with a letter or underscore, not a digit
                , ( "123abc", Nothing )
                , ( "", Nothing )

                -- a leading "_" is legal too — the "semi-private"
                -- naming convention (e.g. `_soundid`), purely conventional
                -- like the trailing "?" case above
                , ( "_private", Just "_private" )
                , ( "_valid", Just "_valid" )
                , ( "_AlsoValid", Just "_AlsoValid" )
                , ( "_", Just "_" )
                , ( "_?", Just "_?" )
                , ( "__double", Just "__double" )
                ]
        , describe "keyword" <|
            List.map (testValue Expect.equal (P.run (L.keyword "if")))
                [ ( "if", Just () )
                , ( "if ", Just () )
                , ( "if true", Just () )

                -- "ifx"/"iffy" are identifiers, not the "if" keyword
                , ( "ifx", Nothing )
                , ( "iffy", Nothing )
                , ( "endif", Nothing )
                , ( "", Nothing )

                -- a trailing "?" is also not the "if" keyword, same
                -- reasoning as "ifx" above -- identifier's own trailing
                -- "?" rule applies at the keyword boundary too
                , ( "if?", Nothing )

                -- "!" is not an identifier character, so it's a clean
                -- boundary, like a space or "("
                , ( "if!", Just () )
                ]
        , describe "keyword \"function\" against a name that collides with it (the real motivating bug)" <|
            List.map (testValue Expect.equal (P.run (L.keyword "function")))
                [ ( "function", Just () )
                , ( "function ", Just () )
                , ( "function(x)", Just () )

                -- "function?" is an identifier (e.g. the
                -- "callable?" predicate could have been named this),
                -- not the "function" keyword -- previously "function"
                -- matched here regardless, leaving a stray "?(1)"/"!(1)"
                -- behind for whatever came next to choke on
                , ( "function?", Nothing )
                , ( "function?(1)", Nothing )
                , ( "function!", Just () )
                ]
        , describe "symbol \"==\"" <|
            List.map (testValue Expect.equal (P.run (L.symbol "==")))
                [ ( "==", Just () )
                , ( "== ", Just () )
                , ( "==x", Just () )
                , ( "=", Nothing )
                , ( "", Nothing )
                ]

        -- `symbol` matches exactly the text given, with no "maximal munch"
        -- of its own: `symbol "="` happily matches just the first `=` of
        -- "==", leaving the second one unconsumed (P.run doesn't require
        -- consuming the whole input). This is exactly why the future
        -- Zak.Internal.Parser will need to try longer operators (like "==") before
        -- their shorter prefixes (like "=") wherever both are possible at
        -- a given position — `Zak.Internal.Lexer` alone doesn't resolve that.
        , describe "symbol \"=\" against a longer operator" <|
            List.map (testValue Expect.equal (P.run (L.symbol "=")))
                [ ( "=", Just () )
                , ( "==", Just () )
                ]
        , describe "newline" <|
            List.map (testValue Expect.equal (P.run L.newline))
                [ ( "\n", Just () )
                , ( "\n\n\n", Just () )
                , ( "\n    ", Just () )
                , ( "\n  \nlet x = 1", Just () )
                , ( " ", Nothing )
                , ( "", Nothing )
                ]
        ]
