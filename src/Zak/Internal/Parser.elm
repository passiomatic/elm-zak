module Zak.Internal.Parser exposing
    ( Error
    , parseProgram
    , parseExpr
    , program
    , block
    , statement
    , expr
    )

{-| Turns Zak source text into a `Zak.Internal.AST` tree, following the "Tiny
Interpreters" convention (<https://blog.tinyinterpreters.dev/posts/>):
single-pass, directly over the raw string via `elm/parser` combinators, using
`Zak.Internal.Lexer`'s lexeme primitives. Private functions mirror the grammar rules
one-to-one; the exceptions are noted where they diverge.
-}

import Parser as P exposing ((|.), (|=), Parser)
import Set exposing (Set)
import Zak.Internal.AST exposing (AssignTarget(..), BinaryOp(..), Block, Expr(..), PathSegment(..), Position, PositionedStatement, Statement(..), UnaryOp(..))
import Zak.Internal.Lexer as L


type alias Error =
    List P.DeadEnd


parseProgram : String -> Result Error Block
parseProgram =
    P.run program


parseExpr : String -> Result Error Expr
parseExpr =
    P.run (P.succeed identity |. L.blankSpace |= expr)



-- PROGRAM / BLOCK / STATEMENT


{-| `program ::= block`, additionally requiring every byte of input to be
consumed — a program is the only grammar rule that owns the whole input.
The top level is never inside a loop, so `break`/`continue` there are
always a parse error.
-}
program : Parser Block
program =
    P.succeed identity
        |= block False
        |. P.end


{-| `block ::= { statement }`, used both as the top-level program and as the
body of an `if`/`while`/function literal.

Consecutive statements must be separated by at least one newline (Zak's
decided "no semicolon" rule) — implemented as `[ statement { newline
statement } ]` rather than "statement, then an optional trailing separator",
so that two statements with nothing at all between them (not even a space)
is a hard parse error rather than something silently accepted. Leading and
trailing blank-line/comment whitespace around the block's statements is
insignificant and consumed either side of it via `L.blankSpace`.

`insideLoop` says whether `break`/`continue` are valid here — this is a
purely lexical fact (which keywords are in scope for the grammar, not a
runtime/type question), so it's checked during parsing, the same way an
invalid assignment target already is (see `toAssignStatement` below), not
deferred to the interpreter. `ifStmt` passes its own `insideLoop` straight
through to its branches (an `if` doesn't change loop context); `whileStmt`
always parses its own body with `True` regardless of its caller's value
(entering a loop); `functionLiteral` always parses its body with `False`
regardless of its caller's value (a function body is a separate unit of
execution — `break`/`continue` don't cross into or out of one, the same
way `return` doesn't leak into an enclosing loop's control flow either).
-}
block : Bool -> Parser Block
block insideLoop =
    P.succeed identity
        |. L.blankSpace
        |= P.loop [] (blockHelp insideLoop)
        |. L.blankSpace


blockHelp : Bool -> List PositionedStatement -> Parser (P.Step (List PositionedStatement) Block)
blockHelp insideLoop revStatements =
    case revStatements of
        [] ->
            P.oneOf
                [ P.map (\s -> P.Loop [ s ]) (positionedStatement insideLoop)
                , P.succeed (P.Done [])
                ]

        _ ->
            -- Only the newline is backtrackable: at a block's normal end
            -- (`end`, `else`, end of input) every statement parser fails
            -- without consuming anything, so the branch fails uncommitted
            -- and `Done` is taken. Wrapping the statement too would also
            -- swallow a real error partway through it (`print(1 +)`),
            -- leaving only the outer "expected the end of the program".
            P.oneOf
                [ P.succeed identity
                    |. P.backtrackable L.newline
                    |= positionedStatement insideLoop
                    |> P.map (\s -> P.Loop (s :: revStatements))
                , P.succeed (P.Done (List.reverse revStatements))
                ]


{-| A statement, paired with where it starts — captured via `position`
*before* `statement` itself runs, so it's the position of the statement's
own first token, not wherever parsing happens to land afterward.
-}
positionedStatement : Bool -> Parser PositionedStatement
positionedStatement insideLoop =
    P.succeed PositionedStatement
        |= position
        |= statement insideLoop


{-| `elm/parser` already tracks row/col live as it consumes input — the
same state a `DeadEnd` reads from on a *syntax* error (`P.getRow`/
`P.getCol`, confirmed against `elm/parser`'s own installed source, not
assumed) — so this is a free read of state already being maintained, not
new tracking machinery. `P.getPosition` returns the raw `(Int, Int)` pair
`elm/parser` itself uses; mapped here into Zak's own named `Position`
record so `Zak.Internal.AST` doesn't need to know `elm/parser`'s tuple convention.
-}
position : Parser Position
position =
    P.map (\( row, col ) -> Position row col) P.getPosition


statement : Bool -> Parser Statement
statement insideLoop =
    P.oneOf
        [ letStmt
        , constStmt
        , ifStmt insideLoop
        , whileStmt
        , forStmt
        , breakStmt insideLoop
        , continueStmt insideLoop
        , returnStmt
        , assignOrExprStmt
        ]


letStmt : Parser Statement
letStmt =
    P.succeed Let
        |. L.keyword "let"
        |= requiredName
        |. L.symbol "="
        |= P.lazy (\_ -> expr)


{-| `const name = expr` — a direct structural copy of `letStmt` above,
differing only in the keyword and the AST constructor it builds.
Unambiguous with `letStmt` the same way every other statement-starting
keyword already is: both start by consuming their own reserved word, so
`P.oneOf` never needs to backtrack between them.
-}
constStmt : Parser Statement
constStmt =
    P.succeed Const
        |. L.keyword "const"
        |= requiredName
        |. L.symbol "="
        |= P.lazy (\_ -> expr)


ifStmt : Bool -> Parser Statement
ifStmt insideLoop =
    P.succeed If
        |. L.keyword "if"
        |= P.lazy (\_ -> expr)
        |. L.symbol ":"
        |= P.lazy (\_ -> block insideLoop)
        |= P.lazy (\_ -> elseBranch insideLoop)
        |. L.keyword "end"


{-| The `else` part of an `if`, if there is one at all — tried in order:

  - `else if cond: ...` — a chained `else if`. Desugars directly into a
    nested `If`, wrapped as a single-statement `Block` at the position
    the nested `if` itself starts — exactly the shape you'd get by
    hand-nesting `else: if cond: ... end end` yourself, just without
    needing to write the extra `end`/indentation. Recurses into another
    `elseBranch` for *its own* `else`/`else if`, so any number of
    `else if`s can chain — all sharing the *one* `end` the outermost
    `ifStmt` consumes; none of the nested `If`s parse an `end` of their
    own.
  - `else:` — a plain final block.
  - nothing at all — `Nothing`.

No new `Zak.Internal.AST` node and no `Zak.Internal.Interpreter` change needed for any of
this: `else if` is pure parser sugar over the `If Expr Block (Maybe
Block)` shape that already exists — it was always able to represent a
chain, once nested this way, the same way hand-writing nested `if`/`else`
already could before this existed.
-}
elseBranch : Bool -> Parser (Maybe Block)
elseBranch insideLoop =
    P.oneOf
        [ P.succeed identity
            |. L.keyword "else"
            |= P.oneOf
                [ P.succeed (\pos cond thenBlock elseBlock -> Just [ PositionedStatement pos (If cond thenBlock elseBlock) ])
                    |= position
                    |. L.keyword "if"
                    |= P.lazy (\_ -> expr)
                    |. L.symbol ":"
                    |= P.lazy (\_ -> block insideLoop)
                    |= P.lazy (\_ -> elseBranch insideLoop)
                , P.succeed Just
                    |. L.symbol ":"
                    |= P.lazy (\_ -> block insideLoop)
                ]
        , P.succeed Nothing
        ]


whileStmt : Parser Statement
whileStmt =
    P.succeed While
        |. L.keyword "while"
        |= P.lazy (\_ -> expr)
        |. L.symbol ":"
        |= P.lazy (\_ -> block True)
        |. L.keyword "end"


{-| `for el in collection: ... end` — no `let`, unlike an earlier version
of this grammar. `let` elsewhere in the language earns its keep
disambiguating two competing forms that share the same `name = expr`
shape: `let x = ...` (a new binding) vs. bare `x = ...` (reassigning an
existing one). `for`'s loop variable was never actually in that
situation — there's no second, "reuse an existing name" form of `for`
for a keyword to disambiguate against, the same reason a function's own
parameters (`function(a, b): ... end`) never needed `let` either: a
fresh per-call binding with no competing form isn't the thing `let`
exists to mark. Zak's own function parameters already establish this
precedent.

Like `whileStmt`, its own body always parses with `insideLoop = True`
regardless of the caller's value, since entering a `for` starts a new loop
context of its own.
-}
forStmt : Parser Statement
forStmt =
    P.succeed For
        |. L.keyword "for"
        |= requiredName
        |. L.keyword "in"
        |= P.lazy (\_ -> expr)
        |. L.symbol ":"
        |= P.lazy (\_ -> block True)
        |. L.keyword "end"


{-| `break`/`continue` always recognize their keyword first, regardless of
`insideLoop` — so a misplaced one gets a specific, clear parse error
("break can only appear inside a loop body") rather than falling through
to `oneOf`'s next alternative and failing with some unrelated, confusing
message once the reserved word can't parse as an identifier either.
-}
breakStmt : Bool -> Parser Statement
breakStmt insideLoop =
    P.succeed ()
        |. L.keyword "break"
        |> P.andThen
            (\_ ->
                if insideLoop then
                    P.succeed Break

                else
                    P.problem "break can only appear inside a while/for loop body"
            )


continueStmt : Bool -> Parser Statement
continueStmt insideLoop =
    P.succeed ()
        |. L.keyword "continue"
        |> P.andThen
            (\_ ->
                if insideLoop then
                    P.succeed Continue

                else
                    P.problem "continue can only appear inside a while/for loop body"
            )


returnStmt : Parser Statement
returnStmt =
    P.succeed Return
        |. L.keyword "return"
        |= P.oneOf
            [ P.map Just (P.lazy (\_ -> expr))
            , P.succeed Nothing
            ]


{-| `assign-stmt` and `expr-stmt` share a prefix: both start by parsing a
full expression (an assignment target is always syntactically a valid
expression too — a name, or a field/index chain ending in one, off of
any base expression). If a bare `=` follows, it's an assignment, and the
already-parsed expression is re-checked as a valid `AssignTarget`;
otherwise it's an expression statement.

This never gets confused with `==`: `expr` already consumes `==` itself as
part of a comparison (see `comparisonOp`), so a bare `=` left over afterward
can only mean assignment.
-}
assignOrExprStmt : Parser Statement
assignOrExprStmt =
    P.lazy (\_ -> expr)
        |> P.andThen
            (\parsed ->
                P.oneOf
                    [ P.succeed identity
                        |. L.symbol "="
                        |= P.lazy (\_ -> expr)
                        |> P.andThen (toAssignStatement parsed)
                    , P.succeed (ExprStatement parsed)
                    ]
            )


toAssignStatement : Expr -> Expr -> Parser Statement
toAssignStatement targetExpr rhs =
    case exprToAssignTarget targetExpr of
        Just target ->
            P.succeed (Assign target rhs)

        Nothing ->
            P.problem "invalid assignment target: a bare name, or a field/index chain ending in one (e.g. player.health, items[0], get().health) can be assigned to"


{-| Walks a `.field`/`[index]` chain back to its base, same as before —
the one change is what counts as a valid *base*. A `Name` is always valid
(segments or not — that's the ordinary `x = 1`/`Taylor.health = 1` cases).
Anything else (a `Call`, a parenthesized expression, ...) is valid only
once there's at least one segment to actually write through — a call is
allowed as an assignment's base, but there's still nothing to assign *to*
for a bare `f() = 1` (see `AssignTarget`'s own doc in `Zak.Internal.AST` for the
full rationale).
-}
exprToAssignTarget : Expr -> Maybe AssignTarget
exprToAssignTarget =
    let
        go e segments =
            case e of
                FieldAccess inner field ->
                    go inner (FieldSegment field :: segments)

                Index inner indexExpr ->
                    go inner (IndexSegment indexExpr :: segments)

                Name _ ->
                    Just (AssignTarget e segments)

                _ ->
                    if List.isEmpty segments then
                        Nothing

                    else
                        Just (AssignTarget e segments)
    in
    \e -> go e []



-- EXPRESSIONS
--
-- One function per precedence level, from loosest (`orExpr`) to tightest
-- (`unaryExpr`). Each level
-- calls the next-tighter level for its operands.


expr : Parser Expr
expr =
    orExpr


orExpr : Parser Expr
orExpr =
    andExpr |> P.andThen orExprHelp


orExprHelp : Expr -> Parser Expr
orExprHelp left =
    P.oneOf
        [ P.succeed (Binary Or left)
            |. L.keyword "or"
            |= andExpr
            |> P.andThen orExprHelp
        , P.succeed left
        ]


andExpr : Parser Expr
andExpr =
    notExpr |> P.andThen andExprHelp


andExprHelp : Expr -> Parser Expr
andExprHelp left =
    P.oneOf
        [ P.succeed (Binary And left)
            |. L.keyword "and"
            |= notExpr
            |> P.andThen andExprHelp
        , P.succeed left
        ]


{-| `not` is a prefix operator (right-recursive on itself, e.g. `not not
x`), sitting between `and`/`or` and the comparisons in precedence.
-}
notExpr : Parser Expr
notExpr =
    P.oneOf
        [ P.succeed (Unary Not)
            |. L.keyword "not"
            |= P.lazy (\_ -> notExpr)
        , comparisonExpr
        ]


{-| Comparisons are **non-associative**: at most one comparison operator per
expression, so `a == b == c` has no valid parse — encoded here as an
optional single `[ comparisonOp additiveExpr ]`, not a repeating loop.
-}
comparisonExpr : Parser Expr
comparisonExpr =
    additiveExpr
        |> P.andThen
            (\left ->
                P.oneOf
                    [ P.succeed (\op right -> Binary op left right)
                        |= comparisonOp
                        |= additiveExpr
                    , P.succeed left
                    ]
            )


comparisonOp : Parser BinaryOp
comparisonOp =
    P.oneOf
        [ P.map (\_ -> Eq) (L.symbol "==")
        , P.map (\_ -> NotEq) (L.symbol "!=")
        , P.map (\_ -> GtEq) (L.symbol ">=")
        , P.map (\_ -> LtEq) (L.symbol "<=")
        , P.map (\_ -> Gt) (L.symbol ">")
        , P.map (\_ -> Lt) (L.symbol "<")
        , P.map (\_ -> In) (L.keyword "in")
        ]


additiveExpr : Parser Expr
additiveExpr =
    multiplicativeExpr |> P.andThen additiveExprHelp


additiveExprHelp : Expr -> Parser Expr
additiveExprHelp left =
    P.oneOf
        [ P.succeed (\op right -> Binary op left right)
            |= additiveOp
            |= multiplicativeExpr
            |> P.andThen additiveExprHelp
        , P.succeed left
        ]


{-| `++` is tried before `+` — it's a longer operator that shares `+`'s
first character, so it must win the match first (maximal munch).
-}
additiveOp : Parser BinaryOp
additiveOp =
    P.oneOf
        [ P.map (\_ -> Concat) (L.symbol "++")
        , P.map (\_ -> Add) (L.symbol "+")
        , P.map (\_ -> Sub) (L.symbol "-")
        ]


multiplicativeExpr : Parser Expr
multiplicativeExpr =
    unaryExpr |> P.andThen multiplicativeExprHelp


multiplicativeExprHelp : Expr -> Parser Expr
multiplicativeExprHelp left =
    P.oneOf
        [ P.succeed (\op right -> Binary op left right)
            |= multiplicativeOp
            |= unaryExpr
            |> P.andThen multiplicativeExprHelp
        , P.succeed left
        ]


{-| `//` is tried before `/` for the same maximal-munch reason as `++`/`+`
(same `oneOf`, so ordering alone resolves it).
-}
multiplicativeOp : Parser BinaryOp
multiplicativeOp =
    P.oneOf
        [ P.map (\_ -> FloorDiv) (L.symbol "//")
        , P.map (\_ -> Mul) (L.symbol "*")
        , P.map (\_ -> Div) (L.symbol "/")
        ]


{-| Unary `-` is right-recursive on itself (e.g. `- - x`) and binds tighter
than every binary operator, including multiplication.
-}
unaryExpr : Parser Expr
unaryExpr =
    P.oneOf
        [ P.succeed (Unary Negate)
            |. L.symbol "-"
            |= P.lazy (\_ -> unaryExpr)
        , postfixExpr
        ]


postfixExpr : Parser Expr
postfixExpr =
    primaryExpr |> P.andThen postfixExprHelp


postfixExprHelp : Expr -> Parser Expr
postfixExprHelp target =
    P.oneOf
        [ P.succeed (FieldAccess target)
            |. L.symbol "."
            |= requiredName
            |> P.andThen postfixExprHelp
        , P.succeed (Index target)
            |. L.symbol "["
            |. L.blankSpace
            |= P.lazy (\_ -> expr)
            |. L.blankSpace
            |. L.symbol "]"
            |> P.andThen postfixExprHelp
        , P.succeed (Call target)
            |. L.symbol "("
            |= commaSeparated (P.lazy (\_ -> expr))
            |. L.symbol ")"
            |> P.andThen postfixExprHelp
        , P.succeed target
        ]


primaryExpr : Parser Expr
primaryExpr =
    P.oneOf
        [ P.map StringLiteral L.string
        , P.map NumberLiteral L.number
        , functionLiteral
        , tableLiteral
        , arrayLiteral
        , P.succeed Name
            |. rejectThrowaway
            |= L.identifier
        , P.succeed identity
            |. L.symbol "("
            |. L.blankSpace
            |= P.lazy (\_ -> expr)
            |. L.blankSpace
            |. L.symbol ")"

        -- names, numbers and strings start with a bare `chompIf`, which
        -- can only report "unexpected character", so without this the
        -- message would list `{`, `[`, `(`... and leave those out
        , P.problem "expected an expression"
        ]


{-| A bare `_` is the throwaway name: `let`, `const`, a parameter or a
`for` loop variable can bind it any number of times, but nothing is ever
stored under it, so reading it is a hard parse-time error. Assignment
targets are parsed as expressions first (`assignOrExprStmt`), so this
single check also rejects `_ = 1`, `_.x = 1` and `_[0] = 1`. A field
*named* `_` (`t._`, `{ _ = 1 }`) is a field, not a binding, and is
unaffected.

Checked by peeking at the source *before* `L.identifier` chomps anything,
then failing with `P.commit`: `L.identifier` is `P.backtrackable`, so a
problem raised after it counts as no progress, and an enclosing `P.oneOf`
or statement loop would swallow it ("expected the end of the program").
Peeking first also puts the error's position on the `_` itself.
-}
rejectThrowaway : Parser ()
rejectThrowaway =
    P.succeed (\offset source -> String.slice offset (offset + 2) source)
        |= P.getOffset
        |= P.getSource
        |> P.andThen
            (\next ->
                if isBareThrowaway next then
                    P.commit () |> P.andThen (\_ -> P.problem "“_” is a throwaway name and can't be used as a value")

                else
                    P.succeed ()
            )


{-| `next` is the (up to) two characters at the current offset: a bare `_`
is one not followed by any further identifier character (`_base`, `_?`
and `_1` are ordinary names).
-}
isBareThrowaway : String -> Bool
isBareThrowaway next =
    case String.toList next of
        [ '_' ] ->
            True

        [ '_', c ] ->
            not (Char.isAlphaNum c || c == '_' || c == '?')

        _ ->
            False


arrayLiteral : Parser Expr
arrayLiteral =
    P.succeed ArrayLiteral
        |. L.symbol "["
        |= commaSeparated (P.lazy (\_ -> expr))
        |. L.symbol "]"


tableLiteral : Parser Expr
tableLiteral =
    P.succeed TableLiteral
        |. L.symbol "{"
        |= (commaSeparated tableField |> P.andThen validateUniqueFields)
        |. L.symbol "}"


{-| `{ x = 1, x = 2 }` is a hard parse-time error rather than "last one
wins": a repeated field name in a single literal is almost always a typo,
and nothing about it depends on runtime state, so it's rejected here the
same way `validateUniqueParams` rejects a repeated parameter name.
-}
validateUniqueFields : List ( String, Expr ) -> Parser (List ( String, Expr ))
validateUniqueFields fields =
    case firstDuplicate (List.map Tuple.first fields) of
        Just name ->
            P.problem ("field “" ++ name ++ "” appears more than once in this table")

        Nothing ->
            P.succeed fields


tableField : Parser ( String, Expr )
tableField =
    P.succeed Tuple.pair
        |= requiredName
        |. L.symbol "="
        |= P.lazy (\_ -> expr)


functionLiteral : Parser Expr
functionLiteral =
    P.succeed FunctionLiteral
        |. L.keyword "function"
        |. L.symbol "("
        |= (commaSeparated parameter |> P.andThen validateTrailingDefaults |> P.andThen validateUniqueParams)
        |. L.symbol ")"
        |. L.symbol ":"
        |= P.lazy (\_ -> block False)
        |. L.keyword "end"


{-| `identifier ["=" expression]` — templated directly on `tableField`
above (`identifier "=" expression`), just with the `"=" expression` part
made optional via `P.oneOf` instead of mandatory.
-}
parameter : Parser ( String, Maybe Expr )
parameter =
    P.succeed Tuple.pair
        |= requiredName
        |= P.oneOf
            [ P.succeed Just |. L.symbol "=" |= P.lazy (\_ -> expr)
            , P.succeed Nothing
            ]


{-| Once a parameter has a default, every parameter after it must too —
`function(a=1, b)` is invalid, a hard parse-time error. `commaSeparated` itself has no notion
of ordering constraints between the items it collects, so this is
checked as a separate pass afterward, the same structural,
parse-time-not-runtime treatment `breakStmt`/`continueStmt`'s
outside-a-loop check and `toAssignStatement`'s invalid-target check
already get in this file.
-}
validateTrailingDefaults : List ( String, Maybe Expr ) -> Parser (List ( String, Maybe Expr ))
validateTrailingDefaults params =
    if isTrailingDefaultsOnly params then
        P.succeed params

    else
        P.problem "a parameter without a default cannot follow one that has a default"


isTrailingDefaultsOnly : List ( String, Maybe Expr ) -> Bool
isTrailingDefaultsOnly params =
    case params of
        [] ->
            True

        ( _, Nothing ) :: rest ->
            isTrailingDefaultsOnly rest

        ( _, Just _ ) :: rest ->
            List.all (\( _, default ) -> default /= Nothing) rest


{-| `function(a, a)` is a hard parse-time error — otherwise the later
argument silently wins, which is almost always a typo. The throwaway
name `_` (see `rejectThrowaway`) is the one exception: `function(_, _)` is
fine, since nothing is ever bound under it. Same
separate-pass-after-`commaSeparated` shape as `validateTrailingDefaults`
above.
-}
validateUniqueParams : List ( String, Maybe Expr ) -> Parser (List ( String, Maybe Expr ))
validateUniqueParams params =
    case firstDuplicate (List.filter ((/=) "_") (List.map Tuple.first params)) of
        Just name ->
            P.problem ("parameter “" ++ name ++ "” appears more than once")

        Nothing ->
            P.succeed params


{-| The first name in `names` that already appeared earlier in the list,
if any. Shared by `validateUniqueParams` and `validateUniqueFields`.
-}
firstDuplicate : List String -> Maybe String
firstDuplicate names =
    firstDuplicateHelp Set.empty names


firstDuplicateHelp : Set String -> List String -> Maybe String
firstDuplicateHelp seen names =
    case names of
        [] ->
            Nothing

        name :: rest ->
            if Set.member name seen then
                Just name

            else
                firstDuplicateHelp (Set.insert name seen) rest



-- SHARED HELPERS


{-| `L.identifier` where a name is required: a `let`/`const`/`for`
variable, a parameter, a table field, or a field after `.`. An identifier
starts with a bare `chompIf`, which can only report "unexpected
character"; this says what was expected instead. A reserved word
(`let if = 2`) still gets the lexer's own message, since that one is
raised further into the input.
-}
requiredName : Parser String
requiredName =
    P.oneOf
        [ L.identifier
        , P.problem "expected a name"
        ]


{-| Zero or more `item`s separated by commas — **no** trailing comma after
the last one; used for array elements, table fields, call arguments, and
function parameters alike, so all four agree on this. (A trailing comma
isn't worth carrying at all, in any position — not just in some of them.)

Tolerant of blank lines/comments (via `L.blankSpace`) around every gap —
before the first item, around each comma, and after the last item — so a
multi-line literal like

    define_actor("Taylor", {
        health = 100,
        talk_to = function(self): ... end
    })

parses. This is deliberately *not* what `L.spaces` (plain horizontal
whitespace, stops dead at a newline — see `Zak.Internal.Lexer`'s own doc) already
gives every other lexeme for free: a newline is still the significant
statement separator everywhere outside a `(`/`[`/`{` — only inside one,
where there's no such ambiguity (we're unambiguously still mid-expression
until the matching close), is a bare newline just more insignificant
whitespace, the same way it already is at a block's own leading/trailing
edge (`block` above).
-}
commaSeparated : Parser a -> Parser (List a)
commaSeparated item =
    P.succeed identity
        |. L.blankSpace
        |= P.oneOf
            [ item |> P.andThen (\first -> P.loop [ first ] (commaSeparatedHelp item))
            , P.succeed []
            ]
        |. L.blankSpace


{-| No `P.backtrackable` needed on the comma branch below, unlike when a
trailing comma was still allowed: once a `,` is actually consumed, another
`item` is now unconditionally required to follow it, so there's nothing
left for `P.oneOf` to backtrack *to* — a comma with nothing meaningful
after it (`[1, 2,]`) is a genuine, uncaught syntax error now, exactly the
same as a missing item anywhere else.
-}
commaSeparatedHelp : Parser a -> List a -> Parser (P.Step (List a) (List a))
commaSeparatedHelp item revItems =
    P.succeed identity
        |. L.blankSpace
        |= P.oneOf
            [ P.succeed identity
                |. L.symbol ","
                |. L.blankSpace
                |= item
                |> P.map (\x -> P.Loop (x :: revItems))
            , P.succeed (P.Done (List.reverse revItems))
            ]
