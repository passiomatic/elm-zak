module Zak.AST exposing
    ( Block
    , PositionedStatement
    , Position
    , Statement(..)
    , AssignTarget(..)
    , PathSegment(..)
    , Expr(..)
    , UnaryOp(..)
    , BinaryOp(..)
    )

{-| The abstract syntax tree for Zak, mirroring the grammar rules
one-to-one. These are pure type definitions, no
parsing or evaluation logic — that's `Zak.Parser`'s and (eventually)
`Zak.Interpreter`'s job.
-}


{-| A sequence of statements, each tagged with where it starts in the
source. This is `block ::= { statement }` from the grammar — it's used
both as the top-level program and as the body of an `if`/`while`/`for`/
function, since those are all the same grammar rule.

`Statement`/`Expr` themselves carry no position at all, deliberately.
Attaching one to every node (would mean every one of `Statement`'s 9 and
`Expr`'s 11 constructors changing shape) buys precision a runtime error
doesn't need: reporting the *line* is enough, a sub-expression range adds
little. Tagging only here, at the
list `Block` already is, gets every statement — including ones nested
inside a loop/conditional/function body, since `If`/`While`/`For`/
`FunctionLiteral` all embed a `Block` — a real position with the
smallest structural change available: nothing about `Statement`'s or
`Expr`'s own constructors changes at all, only what a `Block` holds.
-}
type alias Block =
    List PositionedStatement


{-| One statement, paired with the `Position` it starts at. `Zak.Parser`
captures this via `elm/parser`'s own live row/col tracking (`P.getPosition`
— free, since the parser already maintains this internally for every
`DeadEnd` a *syntax* error would carry); `Zak.Interpreter` reads it back
to tag a `RuntimeError` with *where* it happened, not just what happened.
-}
type alias PositionedStatement =
    { position : Position
    , statement : Statement
    }


{-| A 1-based row/column in the original source — same field names as
`elm/parser`'s own `DeadEnd`, deliberately, so a syntax error and a
runtime error can eventually be formatted through the same
`"row:col: message"` shape rather than two different vocabularies.
-}
type alias Position =
    { row : Int
    , col : Int
    }


type Statement
    = Let String Expr
    | Const String Expr
    | Assign AssignTarget Expr
    | If Expr Block (Maybe Block)
    | While Expr Block
    | For String Expr Block
    | Break
    | Continue
    | Return (Maybe Expr)
    | ExprStatement Expr


{-| The left-hand side of an assignment: a base expression plus a chain of
`.field` and `[index]` steps in whatever order they appear — e.g.
`Taylor.items[0].name` is `AssignTarget (Name "Taylor") [ FieldSegment
"items", IndexSegment (NumberLiteral 0), FieldSegment "name" ]`.

`base` is a full `Expr`, not just a bare name — so a function call
(`getTable().x = 99`) or any parenthesized expression can be an assignment
target's base, matching Zak's own *read*-side `postfix-expr` grammar, which
already lets `.field`/`[index]`/`(args)` chain onto any primary expression
— only the write side used to disagree. `Zak.Parser.exprToAssignTarget` is what
actually enforces the one remaining restriction this type can't express on
its own: a bare, segment-less target (`x = 1`, `AssignTarget base []`) is
only ever valid when `base` is a `Name` — there's no slot to rebind
otherwise (`f() = 1`/`(a + b) = 1` stay hard errors, same as before) — a
*non*-`Name` base is only valid once at least one `.field`/`[index]` step
gives it somewhere to write.
-}
type AssignTarget
    = AssignTarget Expr (List PathSegment)


type PathSegment
    = FieldSegment String
    | IndexSegment Expr


type Expr
    = StringLiteral String
    | NumberLiteral Float
    | Name String
    | ArrayLiteral (List Expr)
    | TableLiteral (List ( String, Expr ))
    | FunctionLiteral (List ( String, Maybe Expr )) Block
    | FieldAccess Expr String
    | Index Expr Expr
    | Call Expr (List Expr)
    | Unary UnaryOp Expr
    | Binary BinaryOp Expr Expr


type UnaryOp
    = Negate
    | Not


type BinaryOp
    = Add
    | Sub
    | Mul
    | Div
    | FloorDiv
    | Concat
    | Eq
    | NotEq
    | Gt
    | Lt
    | GtEq
    | LtEq
    | And
    | Or
    | In
