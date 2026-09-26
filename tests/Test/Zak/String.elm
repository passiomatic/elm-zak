module Test.Zak.String exposing (suite)

import Dict
import Expect
import Test exposing (Test, describe, test)
import Zak.Interpreter as I exposing (Error(..))
import Zak.Runtime exposing (RuntimeError(..), Value(..))
import Zak.String as ZakString


{-| `String` is seeded by `Zak.Interpreter.run` itself now, automatically
— no natives need passing in here at all.
-}
run : String -> Result Error Value
run =
    I.run Dict.empty


{-| `runExpr` deliberately does *not* auto-include `String` (see
`Zak.Interpreter`'s own doc) — so unlike `run` above, this still has to
pass `ZakString.natives` in by hand to exercise `String.from` here.
-}
runExpr : String -> Result Error Value
runExpr =
    I.runExpr ZakString.natives


suite : Test
suite =
    describe "Zak.String (from, length, is_empty, reverse, replace, slice, append)"
        [ describe "from (accepts any value — the only possible error is arity)" <|
            [ test "a string comes back unquoted, unchanged" <|
                \_ -> runExpr "String.from(\"hi\")" |> Expect.equal (Ok (VString "hi"))
            , test "a whole number prints without a trailing .0" <|
                \_ -> runExpr "String.from(99)" |> Expect.equal (Ok (VString "99"))
            , test "a fractional number" <|
                \_ -> runExpr "String.from(3.14)" |> Expect.equal (Ok (VString "3.14"))
            , test "a negative number" <|
                \_ -> runExpr "String.from(-3)" |> Expect.equal (Ok (VString "-3"))
            , test "true/false" <|
                \_ ->
                    Expect.all
                        [ \_ -> runExpr "String.from(true)" |> Expect.equal (Ok (VString "true"))
                        , \_ -> runExpr "String.from(false)" |> Expect.equal (Ok (VString "false"))
                        ]
                        ()
            , test "nil" <|
                \_ -> runExpr "String.from(nil)" |> Expect.equal (Ok (VString "nil"))
            , test "an array gets a fixed placeholder, not a recursive rendering" <|
                \_ -> runExpr "String.from([1, 2, 3])" |> Expect.equal (Ok (VString "<array>"))
            , test "a table gets a fixed placeholder" <|
                \_ -> runExpr "String.from({ x = 1 })" |> Expect.equal (Ok (VString "<table>"))
            , test "a function gets a fixed placeholder" <|
                \_ -> runExpr "String.from(function(): end)" |> Expect.equal (Ok (VString "<function>"))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "String.from(1, 2)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            , test "the motivating case: building a message with ++" <|
                \_ ->
                    run "let shots = 99\nreturn \"I have \" ++ String.from(shots) ++ \" shots left\""
                        |> Expect.equal (Ok (VString "I have 99 shots left"))
            ]
        , describe "length" <|
            [ test "of an empty string" <|
                \_ -> runExpr "String.length(\"\")" |> Expect.equal (Ok (VNumber 0))
            , test "of a non-empty string" <|
                \_ -> runExpr "String.length(\"hello\")" |> Expect.equal (Ok (VNumber 5))
            , test "wrong argument type" <|
                \_ ->
                    runExpr "String.length(1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "String.length(\"a\", \"b\")"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            ]
        , describe "is_empty (predicate — matching Array.is_empty exactly)" <|
            [ test "true for an empty string" <|
                \_ -> runExpr "String.is_empty(\"\")" |> Expect.equal (Ok (VBool True))
            , test "false for a non-empty string" <|
                \_ -> runExpr "String.is_empty(\"a\")" |> Expect.equal (Ok (VBool False))
            , test "wrong argument type" <|
                \_ ->
                    runExpr "String.is_empty(1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "String.is_empty(\"a\", \"b\")"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            ]
        , describe "reverse (pure — String has no identity to mutate, so there's no mutating form to choose between)" <|
            [ test "reverses a simple string" <|
                \_ -> runExpr "String.reverse(\"hello\")" |> Expect.equal (Ok (VString "olleh"))
            , test "the empty string reverses to itself" <|
                \_ -> runExpr "String.reverse(\"\")" |> Expect.equal (Ok (VString ""))
            , test "does not mutate — a plain VString has nothing to mutate in the first place" <|
                \_ ->
                    run "let a = \"hello\"\nlet b = String.reverse(a)\nreturn a"
                        |> Expect.equal (Ok (VString "hello"))
            , test "wrong argument type" <|
                \_ ->
                    runExpr "String.reverse(1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "String.reverse(\"a\", \"b\")"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            ]
        , describe "replace (string, needle, replacement — subject first, matching String.append/String.format and Lua's string.gsub)" <|
            [ test "replaces every occurrence, not just the first" <|
                \_ -> runExpr "String.replace(\"banana\", \"a\", \"o\")" |> Expect.equal (Ok (VString "bonono"))
            , test "no occurrence at all leaves the string unchanged" <|
                \_ -> runExpr "String.replace(\"banana\", \"z\", \"o\")" |> Expect.equal (Ok (VString "banana"))
            , test "an empty needle inserts replacement between every character — mirrors Elm's String.replace verbatim, not guarded against" <|
                \_ -> runExpr "String.replace(\"abc\", \"\", \"-\")" |> Expect.equal (Ok (VString "a-b-c"))
            , test "wrong first argument type" <|
                \_ ->
                    runExpr "String.replace(1, \"a\", \"o\")"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong second argument type" <|
                \_ ->
                    runExpr "String.replace(\"banana\", 1, \"o\")"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong third argument type" <|
                \_ ->
                    runExpr "String.replace(\"banana\", \"a\", 1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "String.replace(\"banana\", \"a\")"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 3, got = 2 })))
            ]
        , describe "slice (string, start, end=nil — half-open, 0-based, no negative-index wraparound)" <|
            [ test "a plain 3-arg slice" <|
                \_ -> runExpr "String.slice(\"verb_dance\", 5, 10)" |> Expect.equal (Ok (VString "dance"))
            , test "omitting end slices through the end of the string" <|
                \_ -> runExpr "String.slice(\"verb_dance\", 5)" |> Expect.equal (Ok (VString "dance"))
            , test "the motivating case: deriving an okverb-style name" <|
                \_ ->
                    run "let verb = \"verb_dance\"\nreturn \"verb_ok_\" ++ String.slice(verb, String.length(\"verb_\"))"
                        |> Expect.equal (Ok (VString "verb_ok_dance"))
            , test "start == 0 and end == length returns the whole string" <|
                \_ -> runExpr "String.slice(\"abc\", 0, 3)" |> Expect.equal (Ok (VString "abc"))
            , test "an end past the string's own length clamps silently, no error" <|
                \_ -> runExpr "String.slice(\"abc\", 0, 999)" |> Expect.equal (Ok (VString "abc"))
            , test "start >= end (after clamping) yields the empty string, no error" <|
                \_ ->
                    Expect.all
                        [ \_ -> runExpr "String.slice(\"abc\", 2, 1)" |> Expect.equal (Ok (VString ""))
                        , \_ -> runExpr "String.slice(\"abc\", 2, 2)" |> Expect.equal (Ok (VString ""))
                        , \_ -> runExpr "String.slice(\"abc\", 999, 999)" |> Expect.equal (Ok (VString ""))
                        ]
                        ()
            , test "a negative start is a NegativeIndex error, not a count-from-the-end" <|
                \_ ->
                    runExpr "String.slice(\"abc\", -1, 2)"
                        |> Expect.equal (Err (RuntimeError (NegativeIndex { index = -1 })))
            , test "a negative end is a NegativeIndex error" <|
                \_ ->
                    runExpr "String.slice(\"abc\", 0, -1)"
                        |> Expect.equal (Err (RuntimeError (NegativeIndex { index = -1 })))
            , test "a non-whole-number start is a NotAnInteger error" <|
                \_ ->
                    runExpr "String.slice(\"abc\", 0.5, 2)"
                        |> Expect.equal (Err (RuntimeError (NotAnInteger { index = 0.5 })))
            , test "a non-whole-number end is a NotAnInteger error" <|
                \_ ->
                    runExpr "String.slice(\"abc\", 0, 2.5)"
                        |> Expect.equal (Err (RuntimeError (NotAnInteger { index = 2.5 })))
            , test "wrong first argument type" <|
                \_ ->
                    runExpr "String.slice(1, 0, 1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong second argument type (2-arg call)" <|
                \_ ->
                    runExpr "String.slice(\"abc\", \"x\")"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            , test "wrong third argument type" <|
                \_ ->
                    runExpr "String.slice(\"abc\", 0, \"x\")"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            , test "wrong argument count: none" <|
                \_ ->
                    runExpr "String.slice()"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 0 })))
            , test "wrong argument count: one" <|
                \_ ->
                    runExpr "String.slice(\"abc\")"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            , test "wrong argument count: four" <|
                \_ ->
                    runExpr "String.slice(\"abc\", 0, 1, 2)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 3, got = 4 })))
            ]
        , describe "append (a callable spelling of ++, mainly useful as a first-class function value)" <|
            [ test "concatenates two strings, same as ++" <|
                \_ -> runExpr "String.append(\"foo\", \"bar\")" |> Expect.equal (Ok (VString "foobar"))
            , test "either side empty" <|
                \_ ->
                    Expect.all
                        [ \_ -> runExpr "String.append(\"\", \"bar\")" |> Expect.equal (Ok (VString "bar"))
                        , \_ -> runExpr "String.append(\"foo\", \"\")" |> Expect.equal (Ok (VString "foo"))
                        ]
                        ()
            , test "usable as a first-class function value via Array.foldr (not foldl — see the source doc comment)" <|
                \_ ->
                    run "return Array.foldr([\"a\", \"b\", \"c\"], String.append, \"\")"
                        |> Expect.equal (Ok (VString "abc"))
            , test "wrong first argument type" <|
                \_ ->
                    runExpr "String.append(1, \"bar\")"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong second argument type" <|
                \_ ->
                    runExpr "String.append(\"foo\", 1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "String.append(\"foo\")"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            ]
        , describe "format (%s/%d/%f/%x/%X/%% substitution, exact arity, deferred flags/width/precision)" <|
            [ test "the doc's own headline example: %d and %s mixed in one format" <|
                \_ ->
                    runExpr "String.format(\"One %d and two %s\", [1, \"strings\"])"
                        |> Expect.equal (Ok (VString "One 1 and two strings"))
            , test "%d truncates a fractional value toward zero, not rounds" <|
                \_ ->
                    runExpr "String.format(\"%d apples\", [3.9])"
                        |> Expect.equal (Ok (VString "3 apples"))
            , test "%d truncation toward zero on a negative value" <|
                \_ ->
                    runExpr "String.format(\"%d\", [-5.7])"
                        |> Expect.equal (Ok (VString "-5"))
            , test "%f shows the full value, no fixed decimal-place count yet" <|
                \_ ->
                    runExpr "String.format(\"%f meters\", [3.14159])"
                        |> Expect.equal (Ok (VString "3.14159 meters"))
            , test "%f on a whole number prints without a trailing .0, matching String.from's Number case" <|
                \_ ->
                    runExpr "String.format(\"%f\", [5])"
                        |> Expect.equal (Ok (VString "5"))
            , test "%x formats a positive value as lowercase hex" <|
                \_ ->
                    runExpr "String.format(\"%x\", [255])"
                        |> Expect.equal (Ok (VString "ff"))
            , test "%X formats a positive value as uppercase hex" <|
                \_ ->
                    runExpr "String.format(\"%X\", [255])"
                        |> Expect.equal (Ok (VString "FF"))
            , test "%x truncates a fractional value toward zero, not rounds" <|
                \_ ->
                    runExpr "String.format(\"%x\", [255.9])"
                        |> Expect.equal (Ok (VString "ff"))
            , test "%x on a negative value sign-prefixes rather than wrapping" <|
                \_ ->
                    runExpr "String.format(\"%x\", [-255])"
                        |> Expect.equal (Ok (VString "-ff"))
            , test "%% is a literal percent sign and consumes no argument" <|
                \_ ->
                    runExpr "String.format(\"100%%\", [])"
                        |> Expect.equal (Ok (VString "100%"))
            , test "%s accepts any value via the same formatter String.from uses" <|
                \_ ->
                    runExpr "String.format(\"%s\", [true])"
                        |> Expect.equal (Ok (VString "true"))
            , test "too few arguments for the placeholders is a hard error" <|
                \_ ->
                    runExpr "String.format(\"%s and %s\", [\"a\"])"
                        |> Expect.equal (Err (RuntimeError (FormatArgMismatch { expected = 2, got = 1 })))
            , test "too many arguments for the placeholders is also a hard error" <|
                \_ ->
                    runExpr "String.format(\"%s\", [\"a\", \"b\"])"
                        |> Expect.equal (Err (RuntimeError (FormatArgMismatch { expected = 1, got = 2 })))
            , test "a non-Number argument to %d is a TypeError" <|
                \_ ->
                    runExpr "String.format(\"%d\", [\"x\"])"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            , test "a non-Number argument to %f is a TypeError" <|
                \_ ->
                    runExpr "String.format(\"%f\", [\"x\"])"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            , test "a non-Number argument to %x is a TypeError" <|
                \_ ->
                    runExpr "String.format(\"%x\", [\"x\"])"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            , test "a non-Number argument to %X is a TypeError" <|
                \_ ->
                    runExpr "String.format(\"%X\", [\"x\"])"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            , test "an unknown directive is a hard error, not silently passed through" <|
                \_ ->
                    runExpr "String.format(\"%q\", [])"
                        |> Expect.equal (Err (RuntimeError (UnknownFormatDirective "%q")))
            , test "wrong first argument type" <|
                \_ ->
                    runExpr "String.format(1, [])"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong second argument type" <|
                \_ ->
                    runExpr "String.format(\"hi\", 1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "String.format(\"hi\")"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            ]
        , test "a script can still shadow String itself with its own let, same as any other global" <|
            \_ ->
                run "let String = { from = function(v): return 999 end }\nreturn String.from(1)"
                    |> Expect.equal (Ok (VNumber 999))
        ]
