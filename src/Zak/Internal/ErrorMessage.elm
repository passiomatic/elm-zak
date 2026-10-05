module Zak.Internal.ErrorMessage exposing (describeRuntimeError, describeRuntimeErrorAt, formatRuntimeError, formatSyntaxError)

{-| Error text: a syntax error or a `RuntimeError` as a message a person
can read, with the source line and a `^` under the column when there's
source to show. Imports nothing from `Zak.Internal.Interpreter`, so the
interpreter itself can use it (to log a broken `NativeZakExpr`, say).
`Zak.errorToString` picks between `formatSyntaxError` and
`formatRuntimeError`.
-}

import Parser exposing (DeadEnd, Problem(..))
import Zak.Internal.AST exposing (Position)
import Zak.Internal.Runtime exposing (RuntimeError(..), Value(..))


{-| A `RuntimeError` reaching here is usually `WithPosition`-tagged in
practice: every statement `execStatements` executes (and so everything
run through `runIncremental`) gets tagged on its way out (see that
function's own doc in `Zak.Internal.Interpreter`) — only `runExpr` deliberately
never tags a position. A caller that runs a second, synthesized snippet
(say `"return main()"`) against the same state gets positions relative to
that snippet, not to `source` — `errorBlock` below still renders them
against `source` regardless, so the line it points at is coincidental,
not meaningful. The untagged branch below still exists because
`RuntimeError` itself carries no such guarantee structurally — only
degrading to a positionless message instead of refusing to compile or
crashing outright, if that guarantee were ever weakened later.
-}
formatRuntimeError : String -> RuntimeError -> String
formatRuntimeError source runtimeError =
    case runtimeError of
        WithPosition position innerError ->
            errorBlock "Runtime error" position source (describeRuntimeError innerError)

        untaggedError ->
            "Runtime error: " ++ describeRuntimeError untaggedError


{-| A one-line description for when there's no source text to show a
snippet from (e.g. an error inside a thread or an embedder-called Zak
function, which carries no file identity): keeps the row/column an
`WithPosition` wrapper carries, which `describeRuntimeError` alone drops.
`"line 3, column 7: “x” is not defined"`, or just the message when there's
no position -- callers add their own prefix (`"Zak thread error: " ++ …`).
-}
describeRuntimeErrorAt : RuntimeError -> String
describeRuntimeErrorAt runtimeError =
    case runtimeError of
        WithPosition position inner ->
            "line " ++ String.fromInt position.row ++ ", column " ++ String.fromInt position.col ++ ": " ++ describeRuntimeError inner

        _ ->
            describeRuntimeError runtimeError


{-| The leaf `RuntimeError` variants, one plain-English sentence each.
-}
describeRuntimeError : RuntimeError -> String
describeRuntimeError runtimeError =
    case runtimeError of
        UndefinedName name ->
            "“" ++ name ++ "” is not defined"

        AlreadyDefined name ->
            "“" ++ name ++ "” is already defined in this scope"

        ConstReassigned name ->
            "“" ++ name ++ "” is const and cannot be reassigned"

        UndefinedField field ->
            "there is no field named “" ++ field ++ "”"

        NotATable value field ->
            describeValue value ++ " has no field “" ++ field ++ "” — it is not a table"

        NotAFunction value ->
            describeValue value ++ " is not a function, and cannot be called"

        WrongArgCount { expected, got } ->
            "expected " ++ pluralize expected "argument" ++ ", got " ++ String.fromInt got

        TypeError { expected, got } ->
            "expected a " ++ expected ++ ", but got " ++ describeValue got

        DivisionByZero explanation ->
            explanation

        DomainError explanation ->
            explanation

        AssertionFailed message ->
            message

        InternalError message ->
            "internal interpreter error: " ++ message

        IndexOutOfBounds { index, length } ->
            "index " ++ formatNumber index ++ " is out of bounds — the array has " ++ pluralize length "element"

        NotAnInteger { index } ->
            "index " ++ formatNumber index ++ " is not a whole number"

        NegativeIndex { index } ->
            "index " ++ formatNumber index ++ " can't be negative"

        EmptyArray ->
            "the array is empty"

        SuspendedNotAllowed ->
            "a waiting call must be a statement on its own, inside a thread"

        FormatArgMismatch { expected, got } ->
            "String.format expected " ++ pluralize expected "argument" ++ ", got " ++ String.fromInt got

        UnknownFormatDirective directive ->
            "unknown String.format directive “" ++ directive ++ "”"

        IncludeNotFound path ->
            "“" ++ path ++ "” was not found among the loaded Zak sources"

        IncludeParseError path deadEnds ->
            case deepestDeadEnds deadEnds of
                Just ( position, problems ) ->
                    "“" ++ path ++ "” failed to parse at line " ++ String.fromInt position.row ++ ", column " ++ String.fromInt position.col ++ ": " ++ describeProblems problems

                Nothing ->
                    "“" ++ path ++ "” failed to parse"

        WithPosition _ innerError ->
            -- `tagPosition` only ever wraps once (see its own doc), so
            -- this never actually recurses in practice — kept only so
            -- this match stays exhaustive without a wildcard swallowing
            -- a real future variant by accident.
            describeRuntimeError innerError


{-| A value mentioned *inside* a `RuntimeError` (`NotATable`'s/
`NotAFunction`'s/`TypeError`'s own payload) can't be rendered the same
way a successful result can be by an embedder's own full rendering: that
needs a `State` to resolve a `VArray`/`VTable` id against its heap, and
`runIncremental` returns no `State` at all on `Err` — evaluation stopped
before producing one. So this stays deliberately shallow: enough to say
*what kind* of thing was found, not a full recursive rendering of its
contents.
-}
describeValue : Value -> String
describeValue value =
    case value of
        VString s ->
            "the string \"" ++ s ++ "\""

        VNumber n ->
            "the number " ++ formatNumber n

        VBool True ->
            "the boolean true"

        VBool False ->
            "the boolean false"

        VNil ->
            "nil"

        VArray _ ->
            "an array"

        VTable _ ->
            "a table"

        VFunction _ _ _ ->
            "a function"

        VNative _ ->
            "a function"

        VNativeThread _ ->
            "a function"


{-| `elm/parser` accumulates one `DeadEnd` per alternative a `P.oneOf`
tried and abandoned, not just the one that "really" failed — most of
them are shallow, uninteresting backtracks (an earlier alternative bailing
after only a character or two). The `DeadEnd`(s) that got *furthest*
into the input before giving up are the ones actually worth showing;
picking the single deepest `(row, col)` and keeping only the `DeadEnd`s
that reached it is `elm/parser`'s own documented technique for this
(see the "Tiny Interpreters" series `Zak.Internal.Parser`'s own doc already cites),
not something invented here.
-}
formatSyntaxError : String -> List DeadEnd -> String
formatSyntaxError source deadEnds =
    case deepestDeadEnds deadEnds of
        Nothing ->
            -- `Parser.run` only ever produces a non-empty `DeadEnd` list
            -- on `Err` — this branch is unreachable in practice, kept
            -- only so this function stays total.
            "Syntax error."

        Just ( position, problems ) ->
            errorBlock "Syntax error" position source (describeProblems problems)


deepestDeadEnds : List DeadEnd -> Maybe ( Position, List Problem )
deepestDeadEnds deadEnds =
    case deadEnds of
        [] ->
            Nothing

        first :: rest ->
            let
                deepest =
                    List.foldl
                        (\candidate best ->
                            if ( candidate.row, candidate.col ) > ( best.row, best.col ) then
                                candidate

                            else
                                best
                        )
                        first
                        rest
            in
            Just
                ( { row = deepest.row, col = deepest.col }
                , (first :: rest)
                    |> List.filter (\d -> d.row == deepest.row && d.col == deepest.col)
                    |> List.map .problem
                    |> dedupe
                )


{-| A custom `Zak.Internal.Parser`/`Zak.Internal.Lexer` message (`P.problem "..."`, e.g.
"break can only appear inside a while/for loop body") is already a
complete, specific sentence — shown as-is, in preference to whatever
generic `ExpectingSymbol`/`ExpectingKeyword` alternatives failed
alongside it at the same position, since those would only restate the
same spot in vaguer terms. Only once every alternative at the deepest
position turns out to be one of `elm/parser`'s own generic problems does
this fall back to combining them into one "expected ... or ..." sentence.

`UnexpectedChar` (a failed `chompIf`) says nothing about what was
expected, so it's left out of that sentence. The parser and lexer give
the common cases their own message instead ("expected an expression",
"expected a name", ...); if it's all that's left, the message says so.
-}
describeProblems : List Problem -> String
describeProblems problems =
    let
        customMessages =
            problems
                |> List.filterMap
                    (\p ->
                        case p of
                            Problem message ->
                                Just message

                            _ ->
                                Nothing
                    )

        expectations =
            List.filter ((/=) UnexpectedChar) problems
    in
    if not (List.isEmpty customMessages) then
        String.join "; " customMessages

    else if List.isEmpty expectations then
        "unexpected character"

    else
        "expected " ++ String.join ", or " (List.map expectationText expectations)


{-| What `elm/parser` was expecting to find next, phrased to slot
directly after "expected " in `describeProblems` above. Zak's own
lexer/parser only ever actually produces `ExpectingSymbol`/
`ExpectingKeyword`/`UnexpectedChar`/`ExpectingEnd`/`Problem` in
practice (see `Zak.Internal.Lexer`/`Zak.Internal.Parser`'s own combinator choices — no
`P.int`/`P.float`/`P.variable` anywhere in either), but this still
covers every constructor `elm/parser`'s own `Problem` type has, so this
stays exhaustive rather than silently going generic if a future change
ever introduces one of the others.
-}
expectationText : Problem -> String
expectationText problem =
    case problem of
        Expecting s ->
            "“" ++ s ++ "”"

        ExpectingInt ->
            "a whole number"

        ExpectingHex ->
            "a hexadecimal number"

        ExpectingOctal ->
            "an octal number"

        ExpectingBinary ->
            "a binary number"

        ExpectingFloat ->
            "a number"

        ExpectingNumber ->
            "a number"

        ExpectingVariable ->
            "a name"

        ExpectingSymbol s ->
            "“" ++ s ++ "”"

        ExpectingKeyword s ->
            "“" ++ s ++ "”"

        ExpectingEnd ->
            "the end of the program"

        UnexpectedChar ->
            -- never reached: `describeProblems` filters it out
            "a different character"

        Problem message ->
            message

        BadRepeat ->
            "something else here"


{-| The shared rendering both `formatRuntimeError` and `formatSyntaxError`
funnel through: a header naming what kind of error this is and where, the
exact source line at `position.row` with a `^` under `position.col`, and
`message` underneath — or, when `source` is `""` (there's no text to
show, as for an error inside a thread), the same on one line.
`position.row`/`.col` are both 1-based, matching
`elm/parser`'s own convention (and `Zak.Internal.Parser.position`'s, which reads
them straight from it) — subtracted back down to 0-based only where this
needs to index into `sourceLines`.
-}
errorBlock : String -> Position -> String -> String -> String
errorBlock kind position source message =
    if String.isEmpty source then
        kind ++ " at line " ++ String.fromInt position.row ++ ", column " ++ String.fromInt position.col ++ ": " ++ message

    else
        kind
            ++ " at line "
            ++ String.fromInt position.row
            ++ ", column "
            ++ String.fromInt position.col
            ++ ":\n\n"
            ++ sourceLineSnippet source position
            ++ "\n\n"
            ++ message


{-| The one source line `position.row` names, indented under a caret
pointing at `position.col` — `""` (so `errorBlock` above prints two bare
newlines, not a broken snippet) if `position.row` somehow doesn't name a
real line in `source` at all, which is only possible if this were ever
called against a `source` other than the one that actually produced
`position` in the first place.
-}
sourceLineSnippet : String -> Position -> String
sourceLineSnippet source position =
    case List.head (List.drop (position.row - 1) (String.split "\n" source)) of
        Nothing ->
            ""

        Just line ->
            "    " ++ line ++ "\n    " ++ String.repeat (max 0 (position.col - 1)) " " ++ "^"


pluralize : Int -> String -> String
pluralize count singular =
    String.fromInt count
        ++ " "
        ++ singular
        ++ (if count == 1 then
                ""

            else
                "s"
           )


{-| `index`/`Math` results are always a `Float` under the hood (Zak has
only one `Number` type), but a whole-number index displayed as `3.0`
reads as a mistake, not a value — shown as `3` whenever it actually is
one, the fractional form only when it genuinely isn't (which is
precisely the interesting case for `NotAnInteger`'s own message).
-}
formatNumber : Float -> String
formatNumber n =
    if n == toFloat (round n) then
        String.fromInt (round n)

    else
        String.fromFloat n


dedupe : List a -> List a
dedupe =
    List.foldl
        (\x acc ->
            if List.member x acc then
                acc

            else
                acc ++ [ x ]
        )
        []
