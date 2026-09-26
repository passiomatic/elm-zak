module Test.Zak.Parser exposing (suite)

import Expect
import Test exposing (Test, describe, test)
import Zak.AST exposing (AssignTarget(..), BinaryOp(..), Block, Expr(..), PathSegment(..), Position, Statement(..), UnaryOp(..))
import Zak.Parser as P


{-| Table-driven positive/negative case runner (same convention as
`Test.Zak.Lexer`): a `Just` expected value means the input must parse
successfully to that value, `Nothing` means the input must fail to parse.
Used directly for `parseExpr`-based cases below, where the actual and
expected sides are already the same type (`Expr`); `parseProgram`-based
cases use `testProgram` instead (see its own doc for why that one isn't
just `testValue` applied to `Block`).

`normalize` lets a caller strip whatever it doesn't want compared exactly
— every `parseExpr` call site below passes either `identity` (nothing to
strip) or `normalizeExpr` (see its own doc below): `Block` gained a
`Position` per statement, and these existing cases were written to test
parsed *structure*, not to hand-verify an exact row/col for every single
one of them — see the dedicated "captures real source positions" describe
block further down for the small, hand-checked set that actually does
that.
-}
testValue : (a -> a) -> (String -> Result e a) -> ( String, Maybe a ) -> Test
testValue normalize run ( input, expected ) =
    test (Debug.toString input) <|
        \_ ->
            case ( Result.map normalize (run input), Maybe.map normalize expected ) of
                ( Ok actual, Just wanted ) ->
                    Expect.equal wanted actual

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


{-| `parseProgram`'s own test runner — deliberately *not* `testValue`
applied to `Block`, because the actual and expected sides can't be the
same type here the way they can for `testValue`: `Block` is `List
PositionedStatement` now, but every existing test literal below (`Just [
Let "x" (NumberLiteral 1) ]`, etc.) already writes the pre-position shape
(`List Statement`) directly, and there's no way to make that literal
*mean* `Block` without editing every single one of the ~80 cases that use
it. Instead, this keeps the expected side exactly as `List Statement` —
so none of those literals change at all — and does the type-crossing in
one place: `dummyBlock` lifts the expected `List Statement` up to `Block`
(tagging everything with the same placeholder position), while
`normalizeBlock` brings the actual, really-parsed `Block` back down to
that same placeholder, so the two compare equal whenever the *structure*
matches, regardless of the real positions the parser actually produced.
-}
testProgram : ( String, Maybe (List Statement) ) -> Test
testProgram ( input, expected ) =
    test (Debug.toString input) <|
        \_ ->
            case ( Result.map normalizeBlock (P.parseProgram input), Maybe.map dummyBlock expected ) of
                ( Ok actual, Just wanted ) ->
                    Expect.equal wanted actual

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


{-| Replaces every captured `Position` in a `Block` — including inside
any nested `If`/`While`/`For`/`FunctionLiteral` body, arbitrarily deep —
with a single fixed placeholder, so a test asserting *structure* doesn't
also have to hand-compute the exact row/col `elm/parser` would produce
for its own source string. `dummyPosition`'s actual value never matters,
only that it's applied uniformly wherever a `Position` is needed for a
comparison to hold (here, and in `dummyBlock`/`testFn`/`testIf`/
`testWhile`/`testFor` below) — this never masks a genuine structural
difference, it only ever erases position, which is exactly the point.
-}
normalizeBlock : Block -> Block
normalizeBlock block =
    List.map (\p -> { position = dummyPosition, statement = normalizeStatement p.statement }) block


{-| The inverse of `normalizeBlock`'s own tagging step — lifts a bare
`List Statement` (the shape every existing test literal already writes)
up into a `Block` by tagging each one with `dummyPosition`, the same
placeholder `normalizeBlock` reduces a *real* parsed `Block` down to.
Shallow, deliberately: it only tags this list's own top-level elements,
trusting that any `Statement` already in the list (built via `testIf`/
`testWhile`/`testFor` below, if it's one of those) already has its own
nested `Block`s correctly tagged too, at the point it was built — not
something this needs to reach into and redo.
-}
dummyBlock : List Statement -> Block
dummyBlock statements =
    List.map (\s -> { position = dummyPosition, statement = s }) statements


dummyPosition : Position
dummyPosition =
    { row = 0, col = 0 }


{-| Test-literal-only stand-ins for `If`/`While`/`For`/`FunctionLiteral` —
same shape as the real constructors, except they take a bare `List
Statement` for a body instead of `Block`, and tag it with `dummyPosition`
via `dummyBlock` internally. Exist purely so the ~90 test cases below can
keep writing `testIf (Name "true") [ ... ] Nothing` the same way they
always wrote `If (Name "true") [ ... ] Nothing`, without needing to
`dummyBlock`-wrap every nested body by hand at every call site — each of
these does exactly that wrapping, once, right where the real constructor
needs it.
-}
testIf : Expr -> List Statement -> Maybe (List Statement) -> Statement
testIf condExpr thenStatements maybeElseStatements =
    If condExpr (dummyBlock thenStatements) (Maybe.map dummyBlock maybeElseStatements)


testWhile : Expr -> List Statement -> Statement
testWhile condExpr bodyStatements =
    While condExpr (dummyBlock bodyStatements)


testFor : String -> Expr -> List Statement -> Statement
testFor loopVar collectionExpr bodyStatements =
    For loopVar collectionExpr (dummyBlock bodyStatements)


{-| Takes bare parameter names, same as always — every one of the ~90
existing call sites below is a function with no defaulted parameters at
all, so this stays convenient for the common case rather than forcing
every one of them to spell out `( name, Nothing )` by hand. Wraps each
name as `( name, Nothing )` internally to match `FunctionLiteral`'s own
`List ( String, Maybe Expr )` shape. A test case that actually needs a
defaulted parameter (see the dedicated "default parameter values"
describe block) builds `FunctionLiteral`/`dummyBlock` directly instead of
going through this helper.
-}
testFn : List String -> List Statement -> Expr
testFn params bodyStatements =
    FunctionLiteral (List.map (\name -> ( name, Nothing )) params) (dummyBlock bodyStatements)


normalizeStatement : Statement -> Statement
normalizeStatement stmt =
    case stmt of
        Let name valueExpr ->
            Let name (normalizeExpr valueExpr)

        Const name valueExpr ->
            Const name (normalizeExpr valueExpr)

        Assign target rhsExpr ->
            Assign (normalizeAssignTarget target) (normalizeExpr rhsExpr)

        If cond thenBlock maybeElseBlock ->
            If (normalizeExpr cond) (normalizeBlock thenBlock) (Maybe.map normalizeBlock maybeElseBlock)

        While cond body ->
            While (normalizeExpr cond) (normalizeBlock body)

        For name collectionExpr body ->
            For name (normalizeExpr collectionExpr) (normalizeBlock body)

        Break ->
            Break

        Continue ->
            Continue

        Return maybeExpr ->
            Return (Maybe.map normalizeExpr maybeExpr)

        ExprStatement valueExpr ->
            ExprStatement (normalizeExpr valueExpr)


normalizeAssignTarget : AssignTarget -> AssignTarget
normalizeAssignTarget (AssignTarget base segments) =
    AssignTarget (normalizeExpr base) (List.map normalizePathSegment segments)


normalizePathSegment : PathSegment -> PathSegment
normalizePathSegment segment =
    case segment of
        FieldSegment name ->
            FieldSegment name

        IndexSegment indexExpr ->
            IndexSegment (normalizeExpr indexExpr)


{-| Only `FunctionLiteral` can ever embed a `Block` inside an `Expr` — but
since a function literal can appear arbitrarily deep in an expression
tree (a callback argument, say), every constructor still needs walking
to find one, not just `FunctionLiteral` itself.
-}
normalizeExpr : Expr -> Expr
normalizeExpr expression =
    case expression of
        StringLiteral _ ->
            expression

        NumberLiteral _ ->
            expression

        Name _ ->
            expression

        ArrayLiteral items ->
            ArrayLiteral (List.map normalizeExpr items)

        TableLiteral fields ->
            TableLiteral (List.map (\( name, valueExpr ) -> ( name, normalizeExpr valueExpr )) fields)

        FunctionLiteral params body ->
            FunctionLiteral
                (List.map (\( name, maybeDefault ) -> ( name, Maybe.map normalizeExpr maybeDefault )) params)
                (normalizeBlock body)

        FieldAccess target field ->
            FieldAccess (normalizeExpr target) field

        Index target indexExpr ->
            Index (normalizeExpr target) (normalizeExpr indexExpr)

        Call callee args ->
            Call (normalizeExpr callee) (List.map normalizeExpr args)

        Unary op operand ->
            Unary op (normalizeExpr operand)

        Binary op left right ->
            Binary op (normalizeExpr left) (normalizeExpr right)


suite : Test
suite =
    describe "Zak.Parser"
        [ describe "expr: literals" <|
            List.map (testValue identity P.parseExpr)
                [ ( "1", Just (NumberLiteral 1) )
                , ( "0.99", Just (NumberLiteral 0.99) )

                -- parseExpr must tolerate leading whitespace/newlines, same
                -- as parseProgram already does via `block`'s own leading
                -- P.spaces — a real gap until this was fixed
                , ( "  1", Just (NumberLiteral 1) )
                , ( "\n\n  1", Just (NumberLiteral 1) )
                , ( "\"hi\"", Just (StringLiteral "hi") )

                -- single-quoted strings were dropped -- "'" is now just
                -- an unrecognized character at expression position, the
                -- same as any other symbol this grammar doesn't have
                -- (e.g. "@"/"$"), not a second string-literal form
                , ( "'hi'", Nothing )
                , ( "Taylor", Just (Name "Taylor") )
                , ( "[]", Just (ArrayLiteral []) )
                , ( "[1, 2, 3]", Just (ArrayLiteral [ NumberLiteral 1, NumberLiteral 2, NumberLiteral 3 ]) )

                -- no trailing comma anywhere, by design — see
                -- `Zak.Parser.commaSeparated`'s own doc for why
                , ( "[1, 2, 3,]", Nothing )
                , ( "{}", Just (TableLiteral []) )
                , ( "{ x = 1 }", Just (TableLiteral [ ( "x", NumberLiteral 1 ) ]) )
                , ( "{ x = 1, y = 2 }", Just (TableLiteral [ ( "x", NumberLiteral 1 ), ( "y", NumberLiteral 2 ) ]) )
                , ( "{ x = 1, y = 2, }", Nothing )
                , ( "nil", Just (Name "nil") )
                , ( "true", Just (Name "true") )
                , ( "foo?", Just (Name "foo?") )
                , ( "empty?", Just (Name "empty?") )
                , ( "push!", Just (Name "push!") )
                ]
        , describe "expr: field access and calls" <|
            List.map (testValue identity P.parseExpr)
                [ ( "Taylor.health", Just (FieldAccess (Name "Taylor") "health") )
                , ( "Taylor.a.b.c", Just (FieldAccess (FieldAccess (FieldAccess (Name "Taylor") "a") "b") "c") )
                , ( "Taylor.empty?", Just (FieldAccess (Name "Taylor") "empty?") )
                , ( "Array.set!", Just (FieldAccess (Name "Array") "set!") )
                , ( "is_valid?(Taylor)", Just (Call (Name "is_valid?") [ Name "Taylor" ]) )
                , ( "Array.set!(0, 99, a)"
                  , Just (Call (FieldAccess (Name "Array") "set!") [ NumberLiteral 0, NumberLiteral 99, Name "a" ])
                  )
                , ( "walk_to()", Just (Call (Name "walk_to") []) )
                , ( "walk_to(Taylor, 100, 200)"
                  , Just (Call (Name "walk_to") [ Name "Taylor", NumberLiteral 100, NumberLiteral 200 ])
                  )

                -- no trailing comma anywhere, arguments included — same
                -- rule as array/table literals above
                , ( "walk_to(Taylor, 100, 200,)", Nothing )
                , ( "make_counter()()", Just (Call (Call (Name "make_counter") []) []) )
                ]
        , describe "expr: unary" <|
            List.map (testValue identity P.parseExpr)
                [ ( "-5", Just (Unary Negate (NumberLiteral 5)) )
                , ( "- - 5", Just (Unary Negate (Unary Negate (NumberLiteral 5))) )
                , ( "not true", Just (Unary Not (Name "true")) )
                , ( "not not x", Just (Unary Not (Unary Not (Name "x"))) )
                , ( "-(a + b)", Just (Unary Negate (Binary Add (Name "a") (Name "b"))) )
                ]
        , describe "expr: operator precedence" <|
            List.map (testValue identity P.parseExpr)
                [ ( "1 + 2 * 3", Just (Binary Add (NumberLiteral 1) (Binary Mul (NumberLiteral 2) (NumberLiteral 3))) )
                , ( "1 * 2 + 3", Just (Binary Add (Binary Mul (NumberLiteral 1) (NumberLiteral 2)) (NumberLiteral 3)) )
                , ( "-5 - 3", Just (Binary Sub (Unary Negate (NumberLiteral 5)) (NumberLiteral 3)) )
                , ( "1 + 2 - 3", Just (Binary Sub (Binary Add (NumberLiteral 1) (NumberLiteral 2)) (NumberLiteral 3)) )
                , ( "2 * 3 // 4", Just (Binary FloorDiv (Binary Mul (NumberLiteral 2) (NumberLiteral 3)) (NumberLiteral 4)) )
                , ( "a == b", Just (Binary Eq (Name "a") (Name "b")) )

                -- non-associative: parseExpr stops after the first
                -- comparison and leaves "== c" unconsumed, same "prefix
                -- parse" behavior as Zak.Lexer's own tests (e.g. "1.0abc").
                -- The program-level test below confirms this is a hard
                -- error once full consumption is required.
                , ( "a == b == c", Just (Binary Eq (Name "a") (Name "b")) )

                -- "in" sits at the same comparison-operator tier -- binds
                -- looser than "+" (its own left operand can be an
                -- additive-expr), and is just as non-associative
                , ( "a in b", Just (Binary In (Name "a") (Name "b")) )
                , ( "1 + 1 in [2]", Just (Binary In (Binary Add (NumberLiteral 1) (NumberLiteral 1)) (ArrayLiteral [ NumberLiteral 2 ])) )
                , ( "a in b in c", Just (Binary In (Name "a") (Name "b")) )
                , ( "a + b == c and d or not e"
                  , Just
                        (Binary Or
                            (Binary And
                                (Binary Eq (Binary Add (Name "a") (Name "b")) (Name "c"))
                                (Name "d")
                            )
                            (Unary Not (Name "e"))
                        )
                  )
                ]
        , describe "expr: maximal munch" <|
            List.map (testValue identity P.parseExpr)
                [ ( "1 // 2", Just (Binary FloorDiv (NumberLiteral 1) (NumberLiteral 2)) )
                , ( "1 / 2", Just (Binary Div (NumberLiteral 1) (NumberLiteral 2)) )
                , ( "\"a\" ++ \"b\"", Just (Binary Concat (StringLiteral "a") (StringLiteral "b")) )
                , ( "a /= b", Just (Binary NotEq (Name "a") (Name "b")) )
                , ( "a >= b", Just (Binary GtEq (Name "a") (Name "b")) )
                ]
        , describe "expr: function literal" <|
            List.map (testValue normalizeExpr P.parseExpr)
                [ ( "function(): return 1 end", Just (testFn [] [ Return (Just (NumberLiteral 1)) ]) )
                , ( "function(a, b): return a + b end"
                  , Just (testFn [ "a", "b" ] [ Return (Just (Binary Add (Name "a") (Name "b"))) ])
                  )

                -- no trailing comma anywhere, parameters included — the
                -- fourth and last of the "all four agree" positions
                , ( "function(a, b,): return a + b end", Nothing )
                ]
        , describe "expr: function literal, default parameter values (positional-fill, trailing-only)" <|
            List.map (testValue normalizeExpr P.parseExpr)
                [ ( "function(a=1): return a end"
                  , Just (FunctionLiteral [ ( "a", Just (NumberLiteral 1) ) ] (dummyBlock [ Return (Just (Name "a")) ]))
                  )
                , ( "function(a, b=1, c=2): return a end"
                  , Just
                        (FunctionLiteral
                            [ ( "a", Nothing ), ( "b", Just (NumberLiteral 1) ), ( "c", Just (NumberLiteral 2) ) ]
                            (dummyBlock [ Return (Just (Name "a")) ])
                        )
                  )

                -- a default isn't restricted to a literal -- any expression
                -- is accepted, same as a table field's own value
                , ( "function(a=1+2): return a end"
                  , Just (FunctionLiteral [ ( "a", Just (Binary Add (NumberLiteral 1) (NumberLiteral 2)) ) ] (dummyBlock [ Return (Just (Name "a")) ]))
                  )

                -- trailing-only: a plain parameter can never follow a
                -- defaulted one -- both a single plain param right after one default,
                -- and two plain params after one, are rejected
                , ( "function(a=1, b): return a end", Nothing )
                , ( "function(a=1, b, c): return a end", Nothing )
                ]
        , describe "expr: array/table literals, call arguments, and grouping tolerate blank lines and comments inside brackets — a newline is only the significant statement separator outside one" <|
            List.map (testValue normalizeExpr P.parseExpr)
                [ ( "[\n    1,\n    2\n]", Just (ArrayLiteral [ NumberLiteral 1, NumberLiteral 2 ]) )
                , ( "{\n    x = 1,\n    y = 2\n}"
                  , Just (TableLiteral [ ( "x", NumberLiteral 1 ), ( "y", NumberLiteral 2 ) ])
                  )
                , ( "{\n}", Just (TableLiteral []) )
                , ( "walk_to(\n    Taylor,\n    100,\n    200\n)"
                  , Just (Call (Name "walk_to") [ Name "Taylor", NumberLiteral 100, NumberLiteral 200 ])
                  )
                , ( "a[\n    0\n]", Just (Index (Name "a") (NumberLiteral 0)) )
                , ( "(\n    1 + 2\n)", Just (Binary Add (NumberLiteral 1) (NumberLiteral 2)) )

                -- blank lines and a comment together, matching how a
                -- realistic multi-line table-argument call is actually
                -- written
                , ( """define_actor("Taylor", {
    # a comment on its own line
    health = 100,

    talk_to = function(self):
        return self.health
    end
})"""
                  , Just
                        (Call (Name "define_actor")
                            [ StringLiteral "Taylor"
                            , TableLiteral
                                [ ( "health", NumberLiteral 100 )
                                , ( "talk_to", testFn [ "self" ] [ Return (Just (FieldAccess (Name "self") "health")) ] )
                                ]
                            ]
                        )
                  )
                ]
        , describe "statement: let" <|
            List.map testProgram
                [ ( "let x = 1", Just [ Let "x" (NumberLiteral 1) ] )
                , ( "let x = 1 + 2", Just [ Let "x" (Binary Add (NumberLiteral 1) (NumberLiteral 2)) ] )

                -- true/false/nil are ordinary pre-bound values, not reserved
                -- words, so a script can legally shadow them with its own
                -- let (see "Identifiers and reserved words" in the
                -- reference manual) — this must succeed, not fail.
                , ( "let true = 5", Just [ Let "true" (NumberLiteral 5) ] )
                , ( "let if = 5", Nothing )

                -- a trailing "?" is a legal identifier character (see
                -- Zak.Lexer's "identifier" tests) — must flow through the
                -- parser end to end, not just the raw lexeme
                , ( "let empty? = true", Just [ Let "empty?" (Name "true") ] )

                -- a multi-line call as a let's value doesn't leak its new
                -- blank-space tolerance past its own closing bracket — the
                -- very next line is still an ordinary, separate statement,
                -- exactly the shape a realistic multi-line table-argument
                -- call needs (see the "array/table literals..."
                -- describe block above for the expression-level version
                -- of this same fix)
                , ( """let a = define_actor("Taylor", {
    health = 100
})
let b = 2"""
                  , Just
                        [ Let "a" (Call (Name "define_actor") [ StringLiteral "Taylor", TableLiteral [ ( "health", NumberLiteral 100 ) ] ])
                        , Let "b" (NumberLiteral 2)
                        ]
                  )

                -- the reserved-word check applies to the whole identifier
                -- including the suffix, so "let?" is not the "let" keyword
                , ( "let let? = 5", Just [ Let "let?" (NumberLiteral 5) ] )

                -- the same "?"/"!" boundary rule applies to a *call*, not
                -- just a definition: "function?" parses as an ordinary
                -- Name, not the "function" keyword plus a stray "?"
                , ( "let f = function?(1)", Just [ Let "f" (Call (Name "function?") [ NumberLiteral 1 ]) ] )
                ]
        , describe "statement: const (a direct structural copy of let, own reserved keyword)" <|
            List.map testProgram
                [ ( "const x = 1", Just [ Const "x" (NumberLiteral 1) ] )
                , ( "const x = 1 + 2", Just [ Const "x" (Binary Add (NumberLiteral 1) (NumberLiteral 2)) ] )

                -- accepts any expression, same as let -- deliberately not
                -- restricted to literals
                , ( "const t = { x = 1 }", Just [ Const "t" (TableLiteral [ ( "x", NumberLiteral 1 ) ]) ] )

                -- "const" is now reserved, the same way "let" already is
                , ( "let const = 5", Nothing )
                ]
        , describe "statement: assignment vs expr-statement" <|
            List.map testProgram
                [ ( "Taylor.health = 99", Just [ Assign (AssignTarget (Name "Taylor") [ FieldSegment "health" ]) (NumberLiteral 99) ] )
                , ( "Taylor.a.b.c = 99"
                  , Just [ Assign (AssignTarget (Name "Taylor") [ FieldSegment "a", FieldSegment "b", FieldSegment "c" ]) (NumberLiteral 99) ]
                  )
                , ( "Taylor.health", Just [ ExprStatement (FieldAccess (Name "Taylor") "health") ] )
                , ( "ary[0] = 99", Just [ Assign (AssignTarget (Name "ary") [ IndexSegment (NumberLiteral 0) ]) (NumberLiteral 99) ] )
                , ( "matrix[0][1] = 99"
                  , Just
                        [ Assign
                            (AssignTarget (Name "matrix") [ IndexSegment (NumberLiteral 0), IndexSegment (NumberLiteral 1) ])
                            (NumberLiteral 99)
                        ]
                  )
                , ( "Taylor.items[0].name = key"
                  , Just
                        [ Assign
                            (AssignTarget (Name "Taylor") [ FieldSegment "items", IndexSegment (NumberLiteral 0), FieldSegment "name" ])
                            (Name "key")
                        ]
                  )
                , ( "ary[0]", Just [ ExprStatement (Index (Name "ary") (NumberLiteral 0)) ] )
                , ( "walk_to(Taylor, 100, 200)"
                  , Just [ ExprStatement (Call (Name "walk_to") [ Name "Taylor", NumberLiteral 100, NumberLiteral 200 ]) ]
                  )

                -- a bare call, no field/index chain -- still nothing to
                -- assign *to*, unchanged by the base-expression relaxation
                -- below
                , ( "walk_to(Taylor, 100, 200) = 1", Nothing )

                -- the actual new capability: a call (or any other
                -- non-Name expression) is now a valid assignment-target
                -- base, as long as there's
                -- at least one field/index step to actually write through
                , ( "Actor.current().health = 100"
                  , Just
                        [ Assign
                            (AssignTarget (Call (FieldAccess (Name "Actor") "current") []) [ FieldSegment "health" ])
                            (NumberLiteral 100)
                        ]
                  )
                , ( "get_inventory()[0] = item"
                  , Just
                        [ Assign
                            (AssignTarget (Call (Name "get_inventory") []) [ IndexSegment (NumberLiteral 0) ])
                            (Name "item")
                        ]
                  )

                -- still no slot to rebind for a totally bare non-Name
                -- expression -- same reasoning as "walk_to(...) = 1" above,
                -- just for a literal instead of a call
                , ( "(1 + 1) = 2", Nothing )
                ]
        , describe "statement: if" <|
            List.map testProgram
                [ ( "if true:\n    let x = 1\nend"
                  , Just [ testIf (Name "true") [ Let "x" (NumberLiteral 1) ] Nothing ]
                  )
                , ( "if true:\n    let x = 1\nelse:\n    let x = 2\nend"
                  , Just [ testIf (Name "true") [ Let "x" (NumberLiteral 1) ] (Just [ Let "x" (NumberLiteral 2) ]) ]
                  )
                , ( "if true: end", Just [ testIf (Name "true") [] Nothing ] )

                -- `else if` desugars to a nested `if` sharing the outer
                -- `end` — no separate AST shape of its own, so this is
                -- exactly the same tree `if a: A else: if b: B end end`
                -- (hand-nested) would already produce.
                , ( "if a:\n    let x = 1\nelse if b:\n    let x = 2\nend"
                  , Just
                        [ testIf (Name "a")
                            [ Let "x" (NumberLiteral 1) ]
                            (Just [ testIf (Name "b") [ Let "x" (NumberLiteral 2) ] Nothing ])
                        ]
                  )
                , ( "if a:\n    let x = 1\nelse if b:\n    let x = 2\nelse:\n    let x = 3\nend"
                  , Just
                        [ testIf (Name "a")
                            [ Let "x" (NumberLiteral 1) ]
                            (Just
                                [ testIf (Name "b")
                                    [ Let "x" (NumberLiteral 2) ]
                                    (Just [ Let "x" (NumberLiteral 3) ])
                                ]
                            )
                        ]
                  )

                -- any number of `else if`s chain, all still sharing the
                -- one final `end`
                , ( "if a:\n    let x = 1\nelse if b:\n    let x = 2\nelse if c:\n    let x = 3\nelse:\n    let x = 4\nend"
                  , Just
                        [ testIf (Name "a")
                            [ Let "x" (NumberLiteral 1) ]
                            (Just
                                [ testIf (Name "b")
                                    [ Let "x" (NumberLiteral 2) ]
                                    (Just
                                        [ testIf (Name "c")
                                            [ Let "x" (NumberLiteral 3) ]
                                            (Just [ Let "x" (NumberLiteral 4) ])
                                        ]
                                    )
                                ]
                            )
                        ]
                  )

                -- a bare `else if` with no trailing `else` at all is
                -- fine too -- the innermost nested `if` just has `Nothing`
                , ( "if a:\n    let x = 1\nelse if b:\n    let x = 2\nelse if c:\n    let x = 3\nend"
                  , Just
                        [ testIf (Name "a")
                            [ Let "x" (NumberLiteral 1) ]
                            (Just
                                [ testIf (Name "b")
                                    [ Let "x" (NumberLiteral 2) ]
                                    (Just [ testIf (Name "c") [ Let "x" (NumberLiteral 3) ] Nothing ])
                                ]
                            )
                        ]
                  )
                ]
        , describe "statement: while" <|
            List.map testProgram
                [ ( "let count = 0\nwhile count < 3:\n    count = count + 1\nend"
                  , Just
                        [ Let "count" (NumberLiteral 0)
                        , testWhile (Binary Lt (Name "count") (NumberLiteral 3))
                            [ Assign (AssignTarget (Name "count") []) (Binary Add (Name "count") (NumberLiteral 1)) ]
                        ]
                  )
                ]
        , describe "statement: for" <|
            List.map testProgram
                [ ( "for x in [1, 2, 3]:\n    let y = x\nend"
                  , Just [ testFor "x" (ArrayLiteral [ NumberLiteral 1, NumberLiteral 2, NumberLiteral 3 ]) [ Let "y" (Name "x") ] ]
                  )
                , ( "for x in items:\nend", Just [ testFor "x" (Name "items") [] ] )

                -- a for body is a loop body too, same as while's
                , ( "for x in items:\n    break\nend", Just [ testFor "x" (Name "items") [ Break ] ] )
                , ( "for x in items:\n    continue\nend", Just [ testFor "x" (Name "items") [ Continue ] ] )

                -- "for"/"in" are reserved, can't be used as identifiers
                , ( "let for = 1", Nothing )
                , ( "let in = 1", Nothing )

                -- "let" is no longer accepted here at all — removed
                -- (see the language reference's "for" section for why it
                -- was never actually doing disambiguating work the way it
                -- does in a `let x = ...` statement)
                , ( "for let x in items:\nend", Nothing )
                ]
        , describe "statement: break/continue — valid only lexically inside a while/for body" <|
            List.map testProgram
                [ ( "while true:\n    break\nend", Just [ testWhile (Name "true") [ Break ] ] )
                , ( "while true:\n    continue\nend", Just [ testWhile (Name "true") [ Continue ] ] )

                -- an `if` doesn't change loop context, so break/continue
                -- inside one nested in a while are still valid
                , ( "while true:\n    if true:\n        break\n    end\nend"
                  , Just [ testWhile (Name "true") [ testIf (Name "true") [ Break ] Nothing ] ]
                  )

                -- outside any loop at all — a parse error, not a runtime one
                , ( "break", Nothing )
                , ( "continue", Nothing )
                , ( "if true:\n    break\nend", Nothing )

                -- a function literal resets loop context even when the
                -- literal itself is written inside a while — break/continue
                -- don't cross into a nested function body
                , ( "while true:\n    let f = function():\n        break\n    end\nend", Nothing )

                -- for establishes loop context exactly the same way while does
                , ( "for x in items:\n    if true:\n        continue\n    end\nend"
                  , Just [ testFor "x" (Name "items") [ testIf (Name "true") [ Continue ] Nothing ] ]
                  )
                , ( "for x in items:\n    let f = function():\n        break\n    end\nend", Nothing )
                ]
        , describe "statement: return" <|
            List.map testProgram
                [ ( "return", Just [ Return Nothing ] )
                , ( "return 1", Just [ Return (Just (NumberLiteral 1)) ] )
                , ( "return -n", Just [ Return (Just (Unary Negate (Name "n"))) ] )
                ]
        , describe "program: statement separation" <|
            List.map testProgram
                [ ( "let x = 1\nlet y = 2", Just [ Let "x" (NumberLiteral 1), Let "y" (NumberLiteral 2) ] )
                , ( "let x = 1\n\n\nlet y = 2", Just [ Let "x" (NumberLiteral 1), Let "y" (NumberLiteral 2) ] )
                , ( "\nlet x = 1\n", Just [ Let "x" (NumberLiteral 1) ] )
                , ( "", Just [] )

                -- two statements with no newline between them must fail,
                -- not silently run together or silently drop the second
                , ( "let x = 1 let y = 2", Nothing )
                , ( "Taylor.a = 1 Taylor.b = 2", Nothing )

                -- a full program consisting of just a chained comparison
                -- must fail: parseProgram requires consuming everything
                -- (unlike parseExpr), so the unconsumed "== c" left over
                -- by comparisonExpr's non-associativity is a hard error here.
                , ( "a == b == c", Nothing )
                , ( "a in b in c", Nothing )
                ]
        , describe "program: end-to-end examples from the reference manual" <|
            List.map testProgram
                [ ( """let abs = function(n):
    if n < 0:
        return -n
    end
    return n
end"""
                  , Just
                        [ Let "abs"
                            (testFn [ "n" ]
                                [ testIf (Binary Lt (Name "n") (NumberLiteral 0))
                                    [ Return (Just (Unary Negate (Name "n"))) ]
                                    Nothing
                                , Return (Just (Name "n"))
                                ]
                            )
                        ]
                  )
                , ( """let factorial = function(n):
    if n == 0:
        return 1
    end
    return n * factorial(n - 1)
end"""
                  , Just
                        [ Let "factorial"
                            (testFn [ "n" ]
                                [ testIf (Binary Eq (Name "n") (NumberLiteral 0))
                                    [ Return (Just (NumberLiteral 1)) ]
                                    Nothing
                                , Return (Just (Binary Mul (Name "n") (Call (Name "factorial") [ Binary Sub (Name "n") (NumberLiteral 1) ])))
                                ]
                            )
                        ]
                  )
                ]
        , describe "captures real source positions — the small, hand-checked set testProgram's own dummy-position comparisons deliberately don't cover" <|
            [ test "a single statement is tagged with its own real (row, col), not the dummy every other test above compares against" <|
                \_ ->
                    P.parseProgram "return 1"
                        |> Expect.equal (Ok [ { position = { row = 1, col = 1 }, statement = Return (Just (NumberLiteral 1)) } ])
            , test "a second statement is tagged with its own line, not the first statement's" <|
                \_ ->
                    P.parseProgram "let x = 1\nreturn x"
                        |> Expect.equal
                            (Ok
                                [ { position = { row = 1, col = 1 }, statement = Let "x" (NumberLiteral 1) }
                                , { position = { row = 2, col = 1 }, statement = Return (Just (Name "x")) }
                                ]
                            )
            , test "leading blank lines and indentation both advance the position, same as elm/parser's own row/col tracking would for any other source" <|
                \_ ->
                    P.parseProgram "\n  return 1"
                        |> Expect.equal (Ok [ { position = { row = 2, col = 3 }, statement = Return (Just (NumberLiteral 1)) } ])
            , test "a statement nested inside an if body is tagged with its own position, not the enclosing if's" <|
                \_ ->
                    P.parseProgram "if true:\n    return 1\nend"
                        |> Expect.equal
                            (Ok
                                [ { position = { row = 1, col = 1 }
                                  , statement =
                                        If (Name "true")
                                            [ { position = { row = 2, col = 5 }, statement = Return (Just (NumberLiteral 1)) } ]
                                            Nothing
                                  }
                                ]
                            )
            ]
        ]
