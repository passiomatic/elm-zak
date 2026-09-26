module Zak.Lexer exposing (blankSpace, identifier, keyword, newline, number, reservedWords, spaces, string, symbol)

{-| Low-level lexeme parsers for Zak source text.

Follows the "Tiny Interpreters" convention (<https://blog.tinyinterpreters.dev/posts/>):
a *lexeme* parser recognizes one lexical unit and consumes its own trailing
*horizontal* whitespace (spaces and tabs); leading whitespace is handled once,
at the top of the grammar (not needed yet, since there is no top-level parser
in this module).

Trailing whitespace deliberately does **not** include newlines: Zak's design
uses a newline as the significant separator between two statements (see
`newline` below), so lexemes must not silently swallow it the way they do
plain spaces/tabs.
-}

import Parser as P exposing ((|.), (|=), Parser)
import Set exposing (Set)


{-| A Zak number literal: one or more digits, optionally followed by a `.`
and one or more digits. There is no sign here — Zak's design treats a
negative number as the unary `-` operator applied to a number expression,
not part of the literal itself.
-}
number : Parser Float
number =
    P.succeed ()
        |. chompOneOrMore Char.isDigit
        |. P.oneOf
            [ P.succeed ()
                |. P.symbol "."
                |. chompOneOrMore Char.isDigit
            , P.succeed ()
            ]
        |> P.getChompedString
        |> P.andThen toFloatOrFail
        |> lexeme


toFloatOrFail : String -> Parser Float
toFloatOrFail chomped =
    case String.toFloat chomped of
        Just value ->
            P.succeed value

        Nothing ->
            P.problem ("expected a number, got \"" ++ chomped ++ "\"")


{-| A Zak string literal: double-quoted, with `\` escaping either `"` or
another backslash. Any other use of `\` is a parse error rather than a
recognized escape (e.g. there is no `\n`). There is only one string form:
a second, single-quoted one would have been 100% equivalent to this one,
adding syntax without adding meaning. `'` is just an ordinary character,
no different from any other symbol this grammar doesn't recognize.
-}
string : Parser String
string =
    P.succeed identity
        |. P.chompIf ((==) '"')
        |= P.loop [] stringBody
        |> lexeme


stringBody : List String -> Parser (P.Step (List String) String)
stringBody revChunks =
    P.oneOf
        [ P.succeed (\chunk -> P.Loop (chunk :: revChunks))
            |. P.symbol "\\"
            |= escapedChar
        , P.symbol "\""
            |> P.map (\_ -> P.Done (revChunks |> List.reverse |> String.concat))
        , P.chompIf (\c -> c /= '"' && c /= '\\')
            |> P.getChompedString
            |> P.map (\chunk -> P.Loop (chunk :: revChunks))
        ]


escapedChar : Parser String
escapedChar =
    P.oneOf
        [ P.symbol "\"" |> P.map (\_ -> "\"")
        , P.symbol "\\" |> P.map (\_ -> "\\")
        ]


{-| The structural keywords that are part of the grammar itself (the
grammar's `reserved-word` rule). These are the only names special-cased at the
tokenizer level. `true`, `false`, and `nil` are deliberately **not** here —
they're ordinary pre-bound values, not reserved words.
-}
reservedWords : Set String
reservedWords =
    Set.fromList
        [ "let", "const", "if", "else", "end", "while", "for", "in", "return"
        , "and", "or", "not", "function", "break", "continue"
        ]


{-| A Zak identifier: starts with a letter or underscore, continues with
letters, digits, or underscores, optionally ending in a single `?` (`?`
marks a predicate by convention (e.g. `ready?`); a leading `_` marks a
"semi-private" name by convention (e.g. `_soundid`); nothing here checks
or enforces either meaning). `!` is never part of an identifier: it's
reserved for the `!=` operator, so `done!=x` lexes as `done` then `!=`,
never as a name `done!` followed by `=`. A bare `_` is a valid identifier
in its own right, same as `a` or `A` — there's no pattern-matching
"throwaway" binding for it to collide with. Cannot be one of the
`reservedWords`.

Built by hand rather than with `P.variable` (unlike most of this module):
`P.variable`'s reserved-word check runs on the chomped string *before* a
caller could append anything after it, so it would reject `"let?"` on the
grounds that its first three characters spell the reserved word `let` —
wrong, since `let?` as a whole isn't reserved. Chomping the optional
trailing character first and checking the *complete* string against
`reservedWords` afterward avoids that.

Wrapped in `P.backtrackable`: without it, rejecting a reserved word (which
only happens *after* chomping several characters) counts as "made progress"
to `elm/parser`, so a surrounding `P.oneOf` — e.g. `statement`'s attempt to
parse an expression-statement starting with the literal keyword `end` at the
close of a block — would treat the rejection as a hard failure instead of
trying its next alternative (the real `end` keyword). `P.variable` avoids
this itself internally; doing the check by hand means doing this too.
-}
identifier : Parser String
identifier =
    P.backtrackable
        (P.succeed ()
            |. P.chompIf (\c -> Char.isAlpha c || c == '_')
            |. P.chompWhile (\c -> Char.isAlphaNum c || c == '_')
            |. P.oneOf
                [ P.chompIf ((==) '?')
                , P.succeed ()
                ]
            |> P.getChompedString
            |> P.andThen rejectReservedWord
        )
        |> lexeme


rejectReservedWord : String -> Parser String
rejectReservedWord name =
    if Set.member name reservedWords then
        P.problem ("\"" ++ name ++ "\" is a reserved word, not a valid identifier")

    else
        P.succeed name


{-| Matches one of the structural keywords exactly — e.g. `keyword "if"` —
failing if it's immediately followed by another identifier character (so
`"ifx"` does not match `keyword "if"`). That includes a trailing `?`,
not just a letter/digit/`_`: `P.keyword` alone only knows about the
latter (its own boundary check is fixed, not configurable), so it happily
treats `"function"` as a complete match against `"function?(1)"`, leaving
`"?(1)"` behind — the real bug this extra check exists to close (see
`identifier` above, which already chomps an optional trailing `?` as
part of *its* own definition, for the same reason). Wrapped in
`P.backtrackable` for the same reason `identifier` is: chomping that
trailing `?` before rejecting it still counts as "made progress" to
`elm/parser`, and without backtracking a surrounding `P.oneOf` (e.g.
trying a function-literal keyword before falling through to `identifier`)
would treat that as a committed failure instead of trying its next
alternative.
-}
keyword : String -> Parser ()
keyword kwd =
    P.backtrackable
        (P.keyword kwd
            |. P.oneOf
                [ P.chompIf ((==) '?')
                    |> P.andThen (\_ -> P.problem ("\"" ++ kwd ++ "\" followed by ? is not the keyword"))
                , P.succeed ()
                ]
        )
        |> lexeme


{-| Matches an exact piece of punctuation or an operator — e.g. `symbol "=="`
or `symbol "("`.
-}
symbol : String -> Parser ()
symbol =
    lexeme << P.symbol


{-| The statement separator: at least one newline, followed by any further
blank lines, indentation, or comments, all swallowed together via
`blankSpace` below — once the mandatory first newline is found, any further
blank-line/comment whitespace has no separate meaning and can be consumed
indiscriminately. Deliberately built on `blankSpace`, not our own `spaces`
above: `spaces` stops dead at a newline (by design, since a bare lexeme must
never swallow the significant separator itself), but a *second* newline
found here is exactly the further blank-line whitespace this is meant to
consume.
-}
newline : Parser ()
newline =
    P.succeed ()
        |. P.chompIf ((==) '\n')
        |. blankSpace


chompOneOrMore : (Char -> Bool) -> Parser ()
chompOneOrMore isGood =
    P.succeed ()
        |. P.chompIf isGood
        |. P.chompWhile isGood


lexeme : Parser a -> Parser a
lexeme p =
    P.succeed identity
        |= p
        |. spaces


{-| A `#` line comment: `#` followed by everything up to (but not
including) the next newline, or the end of input. Deliberately doesn't
consume the newline itself — that's still the significant statement
separator (see `newline` above), left for `spaces`/`blankSpace` below to
handle on their own terms. `#`, not `//`: `//` is already Zak's
floor-division operator, and comments are lexer-level trivia recognized
independently of grammar position, so the same two characters can't mean
both without making comment-recognition context-sensitive.
-}
comment : Parser ()
comment =
    P.succeed ()
        |. P.chompIf ((==) '#')
        |. P.chompWhile ((/=) '\n')


{-| Horizontal whitespace and a trailing comment, if any — see the module
comment for why this excludes newlines themselves. Exposed (matching the
"Tiny Interpreters" convention) so a caller can build a custom lexeme out
of raw `elm/parser` combinators when `symbol`/`keyword` aren't quite
enough — e.g. a negative lookahead that needs to inspect a character
before deciding whether to commit to consuming trailing whitespace.
-}
spaces : Parser ()
spaces =
    P.succeed ()
        |. P.chompWhile (\c -> c == ' ' || c == '\t')
        |. P.oneOf [ comment, P.succeed () ]


{-| Every kind of insignificant "gap" *across* line boundaries — blank
lines, indentation, and now full-line or trailing `#` comments — repeated
until none of them match anymore. Unlike `spaces` above (horizontal only,
stops dead at a newline), this is for the specific places a newline
boundary is already insignificant on its own terms: skipping further
blank/comment lines after the one mandatory newline (`newline` above), and
the leading/trailing edges of a block (see `Zak.Parser.block`). Looping is
necessary, not just a style choice: a comment only eats up to its own
newline, so after one is chomped there may still be more blank lines or
comments to skip before the next real token.
-}
blankSpace : Parser ()
blankSpace =
    P.loop () blankSpaceHelp


blankSpaceHelp : () -> Parser (P.Step () ())
blankSpaceHelp _ =
    P.succeed identity
        |. P.chompWhile (\c -> c == ' ' || c == '\t' || c == '\n' || c == '\r')
        |= P.oneOf
            [ P.map (\_ -> P.Loop ()) comment
            , P.succeed (P.Done ())
            ]
