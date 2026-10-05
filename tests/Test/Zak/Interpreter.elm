module Test.Zak.Interpreter exposing (suite)

import Dict exposing (Dict)
import Expect
import Test exposing (Test, describe, test)
import Zak.Interpreter as I exposing (Error(..))
import Zak.Helpers
import Zak.Runtime as Runtime exposing (Effect(..), LogLevel(..), NativeValue(..), RuntimeError(..), Value(..))


{-| `I.run`, with any `WithPosition` a `RuntimeError` comes back wrapped in
stripped off — this suite (mostly) pins down *which* `RuntimeError` each
case produces, the same as before position-tracking existed; *where* it
happened has its own dedicated describe block below
("position tracking"), not re-asserted at every other call site.
`I.runExpr` deliberately isn't wrapped the same way — it never gets
`WithPosition` in the first place, per `Zak.Interpreter`'s own doc.
-}
run : Dict String NativeValue -> String -> Result Error Value
run natives source =
    I.run natives source |> Result.mapError dropRuntimePosition


dropRuntimePosition : Error -> Error
dropRuntimePosition error =
    case error of
        RuntimeError e ->
            RuntimeError (Runtime.dropPosition e)

        SyntaxError _ ->
            error


{-| Table-driven positive/negative case runner (same convention as the
Lexer/Parser test suites): a `Just` expected value means the input must run
successfully to that value, `Nothing` means it must fail (either a syntax
error or a runtime error — this suite doesn't distinguish which, since each
case's comment/grouping already makes that clear).
-}
testValue : (String -> Result e Value) -> ( String, Maybe Value ) -> Test
testValue runFn ( input, expected ) =
    test (Debug.toString input) <|
        \_ ->
            case ( runFn input, expected ) of
                ( Ok actual, Just wanted ) ->
                    Expect.equal wanted actual

                ( Ok actual, Nothing ) ->
                    Expect.fail ("expected a failure, but got: " ++ Debug.toString actual)

                ( Err _, Nothing ) ->
                    Expect.pass

                ( Err err, Just wanted ) ->
                    Expect.fail ("expected " ++ Debug.toString wanted ++ ", but failed: " ++ Debug.toString err)


noNatives : Dict String NativeValue
noNatives =
    Dict.empty


suite : Test
suite =
    describe "Zak.Interpreter"
        [ describe "runExpr: literals" <|
            List.map (testValue (I.runExpr noNatives))
                [ ( "1", Just (VNumber 1) )
                , ( "\"hi\"", Just (VString "hi") )
                , ( "true", Just (VBool True) )
                , ( "false", Just (VBool False) )
                , ( "nil", Just VNil )
                , ( "undefined_name", Nothing )
                ]
        , describe "run: comments (# to end of line)" <|
            [ test "a trailing comment after a statement is ignored" <|
                \_ ->
                    run noNatives "let x = 1 # this sets x\nreturn x"
                        |> Expect.equal (Ok (VNumber 1))
            , test "a full-line comment before the first statement is ignored" <|
                \_ ->
                    run noNatives "# a header comment\nreturn 1"
                        |> Expect.equal (Ok (VNumber 1))
            , test "a full-line comment between two statements is ignored" <|
                \_ ->
                    run noNatives "let x = 1\n# a comment on its own line\nreturn x"
                        |> Expect.equal (Ok (VNumber 1))
            , test "a comment-only program returns nil, same as an empty one" <|
                \_ -> run noNatives "# nothing but a comment" |> Expect.equal (Ok VNil)
            , test "a comment right before the closing 'end' is ignored, not swallowing the keyword itself" <|
                \_ ->
                    run noNatives "if true:\n    let x = 1\n    # trailing comment inside the if\nend\nreturn 1"
                        |> Expect.equal (Ok (VNumber 1))
            , test "a comment with no trailing newline at the very end of the file is ignored" <|
                \_ -> run noNatives "return 1 # no newline after this" |> Expect.equal (Ok (VNumber 1))
            , test "blank lines and comments can interleave freely between statements" <|
                \_ ->
                    run noNatives
                        "let x = 1\n\n# a comment after a blank line\n\n# another comment\nreturn x"
                        |> Expect.equal (Ok (VNumber 1))
            , test "'#' inside a string literal is ordinary text, not a comment" <|
                \_ -> I.runExpr noNatives "\"a # b\"" |> Expect.equal (Ok (VString "a # b"))
            , test "floor division (//) still works, untouched by # comment support" <|
                \_ -> I.runExpr noNatives "7 // 2 # comment" |> Expect.equal (Ok (VNumber 3))
            ]
        , describe "runExpr: arithmetic" <|
            List.map (testValue (I.runExpr noNatives))
                [ ( "1 + 2", Just (VNumber 3) )
                , ( "2 * 3 + 1", Just (VNumber 7) )
                , ( "1 - 2", Just (VNumber -1) )
                , ( "7 / 2", Just (VNumber 3.5) )
                , ( "7 // 2", Just (VNumber 3) )
                , ( "-5", Just (VNumber -5) )
                , ( "\"a\" ++ \"b\"", Just (VString "ab") )
                , ( "1 + \"a\"", Nothing )
                , ( "\"a\" ++ 1", Nothing )
                , ( "-\"a\"", Nothing )
                ]
        , describe "runExpr: division by zero" <|
            List.map (testValue (I.runExpr noNatives))
                [ ( "1 / 0", Nothing )
                , ( "1 // 0", Nothing )
                , ( "0 / 0", Nothing )
                , ( "1 / 2", Just (VNumber 0.5) )

                -- a runtime error, not a silent NaN/Infinity that would
                -- otherwise make equality behave surprisingly
                , ( "(1 / 0) == (1 / 0)", Nothing )
                ]
        , describe "runExpr: comparisons" <|
            List.map (testValue (I.runExpr noNatives))
                [ ( "1 == 1", Just (VBool True) )
                , ( "1 == 1.0", Just (VBool True) )
                , ( "1 == \"1\"", Just (VBool False) )
                , ( "1 != 2", Just (VBool True) )
                , ( "\"a\" == \"a\"", Just (VBool True) )
                , ( "nil == nil", Just (VBool True) )
                , ( "1 < 2", Just (VBool True) )
                , ( "2 <= 2", Just (VBool True) )
                , ( "\"a\" < \"b\"", Just (VBool True) )
                , ( "\"b\" < \"a\"", Just (VBool False) )
                , ( "\"a\" <= \"a\"", Just (VBool True) )
                , ( "\"b\" > \"a\"", Just (VBool True) )
                , ( "\"a\" >= \"a\"", Just (VBool True) )
                , ( "\"ab\" < \"b\"", Just (VBool True) )
                , ( "true < false", Nothing )
                , ( "nil < nil", Nothing )
                , ( "1 < \"1\"", Nothing )
                ]
        , describe "runExpr: in (x in array/table — sugar for Array.contains/Table.contains, value-based on arrays, not index-based)" <|
            List.map (testValue (I.runExpr noNatives))
                [ ( "1 in [1, 2, 3]", Just (VBool True) )
                , ( "4 in [1, 2, 3]", Just (VBool False) )
                , ( "\"a\" in { a = 1 }", Just (VBool True) )
                , ( "\"z\" in { a = 1 }", Just (VBool False) )

                -- own-keys-only, same as Table.contains -- there's no
                -- delegate chain yet to even test against
                , ( "\"a\" in { b = 1 }", Just (VBool False) )

                -- "in" sits at the comparison tier, tighter than "and"/
                -- "or"/"not" but looser than "+" -- (1 + 1) in [2]
                , ( "1 + 1 in [2]", Just (VBool True) )

                -- no fused "!in"/"not in" token -- plain "not" composes
                -- with it like any other expression
                , ( "not (1 in [2, 3])", Just (VBool True) )

                -- a hard error, not a silent false, for a
                -- non-Array/Table right-hand side or a non-String table key
                , ( "1 in 5", Nothing )
                , ( "1 in { a = 1 }", Nothing )
                ]
        , describe "runExpr: logical operators short-circuit" <|
            List.map (testValue (I.runExpr noNatives))
                [ ( "true and true", Just (VBool True) )
                , ( "true and false", Just (VBool False) )
                , ( "false and true", Just (VBool False) )
                , ( "true or false", Just (VBool True) )
                , ( "false or false", Just (VBool False) )
                , ( "not true", Just (VBool False) )

                -- short-circuit: the right side is never evaluated, so an
                -- undefined name there doesn't cause a failure
                , ( "false and undefined_name", Just (VBool False) )
                , ( "true or undefined_name", Just (VBool True) )

                -- but when the left side doesn't decide it, the right side
                -- both runs AND is required
                , ( "true and undefined_name", Nothing )
                , ( "false or undefined_name", Nothing )
                , ( "1 and true", Nothing )
                ]
        , describe "runExpr: tables" <|
            List.map (testValue (I.runExpr noNatives))
                [ ( "{ x = 1 }.x", Just (VNumber 1) )
                , ( "{ x = 1, y = 2 }.y", Just (VNumber 2) )
                , ( "{ x = { y = 5 } }.x.y", Just (VNumber 5) )
                , ( "{}.x", Nothing )
                , ( "1.x", Nothing )
                ]
        , describe "runExpr: array indexing ([index]), no Array natives required" <|
            List.map (testValue (I.runExpr noNatives))
                [ ( "[10, 20, 30][0]", Just (VNumber 10) )
                , ( "[10, 20, 30][2]", Just (VNumber 30) )
                , ( "[[1, 2], [3, 4]][1][0]", Just (VNumber 3) )
                , ( "[{ x = 1 }][0].x", Just (VNumber 1) )
                , ( "[10, 20, 30][-1]", Nothing )
                , ( "[10, 20, 30][3]", Nothing )
                , ( "1[0]", Nothing )
                , ( "[1, 2][\"x\"]", Nothing )

                -- a whole-number float is fine, indistinguishable from an
                -- integer literal; a genuinely fractional one is now a
                -- hard error rather than silently rounding to a neighbor
                , ( "[10, 20, 30][2.0]", Just (VNumber 30) )
                , ( "[10, 20, 30][4 / 2]", Just (VNumber 30) )
                , ( "[10, 20, 30][2.5]", Nothing )
                , ( "[10, 20, 30][5 / 2]", Nothing )
                ]
        , describe "runExpr: function calls" <|
            List.map (testValue (I.runExpr noNatives))
                [ ( "function(a, b): return a + b end(1, 2)", Just (VNumber 3) )
                , ( "function(): return 1 end()", Just (VNumber 1) )

                -- no explicit return -> nil
                , ( "function(): let x = 1 end()", Just VNil )

                -- wrong arity
                , ( "function(a, b): return a + b end(1)", Nothing )

                -- calling a non-function
                , ( "(1)(2)", Nothing )
                ]
        , describe "runExpr: default parameter values (positional-fill, trailing-only)" <|
            List.map (testValue (I.runExpr noNatives))
                [ -- a 3-param function, 2 defaulted, called with 1/2/3 args
                  ( "function(a, b=10, c=20): return a + b + c end(1)", Just (VNumber 31) )
                , ( "function(a, b=10, c=20): return a + b + c end(1, 2)", Just (VNumber 23) )
                , ( "function(a, b=10, c=20): return a + b + c end(1, 2, 3)", Just (VNumber 6) )

                -- too few: fewer than the mandatory (non-defaulted) params
                , ( "function(a, b=10, c=20): return a + b + c end()", Nothing )

                -- too many: more than every param, defaulted ones included
                , ( "function(a, b=10, c=20): return a + b + c end(1, 2, 3, 4)", Nothing )
                ]
        , describe "runExpr: default parameter values -- exact error shapes" <|
            [ test "too few arguments reports the minimum (mandatory-only) arity as \"expected\"" <|
                \_ ->
                    I.runExpr noNatives "function(a, b=1, c=2): return a end()"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 0 })))
            , test "too many arguments reports the maximum (every param) arity as \"expected\"" <|
                \_ ->
                    I.runExpr noNatives "function(a, b=1, c=2): return a end(1, 2, 3, 4)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 3, got = 4 })))
            , test "no defaults at all is unaffected -- min == max == the old exact-arity check" <|
                \_ ->
                    I.runExpr noNatives "function(a, b): return a end(1)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            ]
        , describe "runExpr: default parameter values -- evaluated fresh per call, in the enclosing scope, not once at definition time" <|
            [ test "no shared-mutable-default bug: an array-literal default is an independent value on every call that falls back to it, not one instance mutated in place across all of them (the classic \"mutable default argument\" gotcha, deliberately avoided here)" <|
                \_ ->
                    run noNatives
                        """
                        let f = function(a, list=[]):
                            Array.push(list, a)
                            return Array.length(list)
                        end
                        let one = f(1)
                        let two = f(2)
                        let three = f(3)
                        return one == 1 and two == 1 and three == 1
                        """
                        |> Expect.equal (Ok (VBool True))
            , test "a default's own side effect runs once per call that actually falls back to it -- confirms fresh-per-call evaluation, not once ever" <|
                \_ ->
                    run noNatives
                        """
                        let counter = { value = 0 }
                        let next = function():
                            counter.value = counter.value + 1
                            return counter.value
                        end
                        let f = function(a, b=next()):
                            return b
                        end
                        let first = f(1)
                        let second = f(1)
                        return first == 1 and second == 2 and counter.value == 2
                        """
                        |> Expect.equal (Ok (VBool True))
            , test "a default is never evaluated at all for a call that supplies every argument -- confirms laziness, not just freshness" <|
                \_ ->
                    run noNatives
                        """
                        let counter = { value = 0 }
                        let next = function():
                            counter.value = counter.value + 1
                            return counter.value
                        end
                        let f = function(a, b=next()):
                            return a + b
                        end
                        let result = f(1, 100)
                        return result == 101 and counter.value == 0
                        """
                        |> Expect.equal (Ok (VBool True))
            , test "a default cannot reference an earlier parameter" <|
                \_ ->
                    I.runExpr noNatives "function(a, b=a): return b end(1)"
                        |> Expect.equal (Err (RuntimeError (UndefinedName "a")))
            , test "a default CAN reference a legitimate outer-scope name -- ordinary closure capture, not a sibling parameter" <|
                \_ ->
                    run noNatives
                        """
                        let outer = 99
                        let f = function(a, b=outer):
                            return b
                        end
                        return f(1)
                        """
                        |> Expect.equal (Ok (VNumber 99))
            ]
        , describe "run: tables mutate in place" <|
            List.map (testValue (run noNatives))
                [ ( """let r = { health = 100 }
r.health = r.health - 1
return r.health"""
                  , Just (VNumber 99)
                  )
                , ( """let r = { health = 100 }
let f = function(rec):
    rec.health = rec.health - 1
end
f(r)
return r.health"""
                  , Just (VNumber 99)
                  )

                -- assigning to a field that doesn't exist yet creates it,
                -- paired with Array.set/Array.push's targeted-edit-mutates
                -- rule rather than erroring
                , ( """let r = { x = 1 }
r.y = 2
return r.y"""
                  , Just (VNumber 2)
                  )

                -- creating a field this way is visible through an alias,
                -- same as updating an existing one
                , ( """let r = { x = 1 }
let s = r
r.y = 2
return s.y"""
                  , Just (VNumber 2)
                  )

                -- ...and through a function argument, same as updating
                , ( """let r = { x = 1 }
let f = function(rec):
    rec.y = 2
end
f(r)
return r.y"""
                  , Just (VNumber 2)
                  )

                -- creating a field via a mixed .field/[index] chain
                , ( """let a = [{ x = 1 }]
a[0].y = 2
return a[0].y"""
                  , Just (VNumber 2)
                  )

                -- no auto-vivification of *intermediate* steps, though:
                -- every step but the last must already exist and already
                -- be a table — only the chain's last step can be created
                , ( """let r = { a = 1 }
r.a.b = 2"""
                  , Nothing
                  )
                ]
        , describe "run: an assignment target's base can be any expression, not just a name (e.g. a call)" <|
            List.map (testValue (run noNatives))
                [ ( """let r = { health = 100 }
let get_actor = function():
    return r
end
get_actor().health = 99
return r.health"""
                  , Just (VNumber 99)
                  )

                -- the call is only evaluated once — if it had side effects,
                -- a second, spurious call would double them, which this
                -- pins down by making the "get" itself something observable
                , ( """let calls = { count = 0 }
let r = { x = 1 }
let get_actor = function():
    calls.count = calls.count + 1
    return r
end
get_actor().x = 99
return calls.count"""
                  , Just (VNumber 1)
                  )

                -- index-chain form, and a call nested deeper in the chain
                -- (not just as the immediate base)
                , ( """let inventory = [{ name = "sword" }]
let get_actor = function():
    return { inventory = inventory }
end
get_actor().inventory[0].name = "shield"
return inventory[0].name"""
                  , Just (VString "shield")
                  )

                -- still no slot to rebind for a bare call with no
                -- field/index chain — unchanged from before this relaxation
                , ( """let f = function(): return 1 end
f() = 2"""
                  , Nothing
                  )
                ]
        , describe "run: [index] assignment mutates the array in place, no Array natives required" <|
            List.map (testValue (run noNatives))
                [ ( """let a = [1, 2, 3]
a[0] = 99
return a[0]"""
                  , Just (VNumber 99)
                  )
                , ( """let a = [1, 2, 3]
let b = a
a[0] = 99
return b[0]"""
                  , Just (VNumber 99)
                  )
                , ( """let a = [1, 2, 3]
let f = function(ary):
    ary[0] = 99
end
f(a)
return a[0]"""
                  , Just (VNumber 99)
                  )

                -- mixed .field/[index] chains, in both orders
                , ( """let r = { items = [1, 2, 3] }
r.items[0] = 99
return r.items[0]"""
                  , Just (VNumber 99)
                  )
                , ( """let a = [{ x = 1 }, { x = 2 }]
a[0].x = 99
return a[0].x"""
                  , Just (VNumber 99)
                  )
                , ( """let m = [[1, 2], [3, 4]]
m[0][1] = 99
return m[0][1]"""
                  , Just (VNumber 99)
                  )

                -- same bounds/type rules as reading
                , ( """let a = [1, 2, 3]
a[3] = 99"""
                  , Nothing
                  )
                , ( """let r = { x = 1 }
r[0] = 99"""
                  , Nothing
                  )
                ]
        , describe "run: let/assignment/scoping" <|
            List.map (testValue (run noNatives))
                [ ( "let x = 1\nreturn x", Just (VNumber 1) )
                , ( "let x = 1\nx = 2\nreturn x", Just (VNumber 2) )

                -- reassigning an undeclared name is an error
                , ( "x = 1", Nothing )

                -- redeclaring in the same scope is an error
                , ( "let x = 1\nlet x = 2", Nothing )

                -- shadowing in a nested scope is fine, and doesn't leak
                -- back out once that block ends
                , ( """let x = 1
if true:
    let x = 2
end
return x"""
                  , Just (VNumber 1)
                  )

                -- the while-loop accumulator pattern from the reference
                -- manual: declared before the loop, updated (not
                -- redeclared) inside it
                , ( """let count = 0
while count < 5:
    count = count + 1
end
return count"""
                  , Just (VNumber 5)
                  )
                ]
        , describe "run: throwaway name `_` — evaluated, never bound" <|
            List.map (testValue (run noNatives))
                [ -- repeated in one scope, by let and const alike, and
                  -- the value is still evaluated for its effects
                  ( """let t = { n = 0 }
let bump = function():
    t.n = t.n + 1
    return t.n
end
let _ = bump()
let _ = bump()
const _ = bump()
return t.n"""
                  , Just (VNumber 3)
                  )
                , ( "let f = function(_, b): return b end\nreturn f(1, 2)", Just (VNumber 2) )
                , ( "let f = function(_, _): return 3 end\nreturn f(1, 2)", Just (VNumber 3) )

                -- a defaulted `_` still evaluates its default
                , ( "let f = function(a, _ = 1): return a end\nreturn f(5)", Just (VNumber 5) )

                -- nothing is stored, so an outer `let _` and a `_`
                -- parameter or loop variable never collide
                , ( """let _ = 1
let f = function(_):
    let _ = 2
    return 4
end
return f(3)"""
                  , Just (VNumber 4)
                  )
                , ( """let n = 0
for _ in [1, 2, 3]:
    let _ = n
    n = n + 1
end
return n"""
                  , Just (VNumber 3)
                  )
                ]
        , describe "run: const — exactly like let, except a bare reassignment is a hard error" <|
            List.map (testValue (run noNatives))
                [ ( "const x = 1\nreturn x", Just (VNumber 1) )

                -- reassigning a const is an error (exact RuntimeError shape
                -- pinned down separately, in "exact RuntimeError returned"
                -- below)
                , ( "const x = 1\nx = 2", Nothing )

                -- shadowing works exactly like let's own — a nested `let`
                -- with the same name doesn't touch the outer const at all,
                -- it's a brand new binding
                , ( """const x = 1
if true:
    let x = 2
    return x
end"""
                  , Just (VNumber 2)
                  )

                -- scoped exactly like let -- a const
                -- declared inside a function body is gone once it returns
                , ( """let f = function():
    const x = 1
    return x
end
f()
return x"""
                  , Nothing
                  )

                -- const accepts any expression, not just a literal --
                -- deliberately not restricted to literals
                , ( """const greet = function(name): return "hi " ++ name end
return greet("Taylor")"""
                  , Just (VString "hi Taylor")
                  )

                -- shallow const: rebinding the name is blocked,
                -- but mutating a const-bound table's own field is not --
                -- that's a field write, not a reassignment of `t` itself
                , ( """const t = { x = 1 }
t.x = 2
return t.x"""
                  , Just (VNumber 2)
                  )

                -- same shallow-mutation argument, array side: Array.push
                -- mutates the array cell a const-bound name points at, it
                -- never rebinds the name
                , ( """const a = [1, 2]
Array.push(a, 3)
return Array.length(a)"""
                  , Just (VNumber 3)
                  )
                ]
        , describe "run: true/false/nil are const at the top level — reassignment errors, shadowing doesn't" <|
            List.map (testValue (run noNatives))
                [ -- a bare reassignment reaching all the way to the seeded
                  -- global is blocked (exact RuntimeError shape pinned down
                  -- separately, in "exact RuntimeError returned" below)
                  ( "true = false\nreturn true", Nothing )
                , ( "nil = 1\nreturn nil", Nothing )

                -- shadowing via let is completely unaffected -- a nested
                -- `let true = ...` never touches the outermost frame's
                -- constNames at all, it's a brand new binding
                , ( """let x = true
if true:
    let true = false
    x = true
end
return x"""
                  , Just (VBool False)
                  )
                ]
        , describe "run: else if — pure parser sugar (desugars to a nested if), so this is really an end-to-end proof the desugaring is wired correctly, not new interpreter behavior" <|
            List.map (testValue (run noNatives))
                [ ( "if false:\n    return 1\nelse if true:\n    return 2\nend", Just (VNumber 2) )

                -- picks the *first* matching branch, not the last
                , ( "if false:\n    return 1\nelse if true:\n    return 2\nelse if true:\n    return 3\nend", Just (VNumber 2) )

                -- falls all the way to the final plain else
                , ( "if false:\n    return 1\nelse if false:\n    return 2\nelse:\n    return 3\nend", Just (VNumber 3) )

                -- no matching branch and no final else at all — falls
                -- through with no return, same as an ordinary `if` with
                -- no `else` and a false condition
                , ( "if false:\n    return 1\nelse if false:\n    return 2\nend\nreturn 4", Just (VNumber 4) )
                ]
        , describe "run: break/continue" <|
            List.map (testValue (run noNatives))
                [ ( """let count = 0
while count < 10:
    if count == 3:
        break
    end
    count = count + 1
end
return count"""
                  , Just (VNumber 3)
                  )
                , ( """let i = 0
let sum = 0
while i < 5:
    i = i + 1
    if i == 3:
        continue
    end
    sum = sum + i
end
return sum"""
                  , Just (VNumber 12)
                  )

                -- break only stops the *nearest* enclosing loop — the
                -- outer loop keeps running its remaining 3 passes; if
                -- break had wrongly propagated past the inner while too,
                -- innerRuns would come out as 2, not 6
                , ( """let outerCount = 0
let innerRuns = 0
while outerCount < 3:
    let innerCount = 0
    while innerCount < 10:
        if innerCount == 2:
            break
        end
        innerCount = innerCount + 1
        innerRuns = innerRuns + 1
    end
    outerCount = outerCount + 1
end
return innerRuns"""
                  , Just (VNumber 6)
                  )

                -- return still propagates all the way out through an
                -- enclosing while, unaffected by break/continue's own
                -- narrower propagation
                , ( """let f = function():
    let i = 0
    while true:
        if i == 3:
            return i
        end
        i = i + 1
    end
end
return f()"""
                  , Just (VNumber 3)
                  )
                ]
        , describe "run: for" <|
            List.map (testValue (run noNatives))
                [ ( """let sum = 0
for x in [1, 2, 3]:
    sum = sum + x
end
return sum"""
                  , Just (VNumber 6)
                  )
                , ( """for x in []:
end
return 0"""
                  , Just (VNumber 0)
                  )

                -- the loop variable doesn't leak past the loop — it's
                -- undefined once the for statement ends
                , ( """for x in [1, 2, 3]:
end
x = 1"""
                  , Nothing
                  )

                -- the body gets its own nested scope, separate from the
                -- frame holding the loop variable — a `let` shadowing the
                -- loop variable's own name is not a redeclaration error
                , ( """let result = 0
for x in [10]:
    let x = x + 1
    result = x
end
return result"""
                  , Just (VNumber 11)
                  )
                , ( """let a = [1, 2, 3]
for x in a:
    if x == 2:
        break
    end
end
return x"""
                  , Nothing
                  )

                -- "let" is no longer accepted in a for-loop header at all
                -- (see the language reference's "for" section for why)
                , ( "for let x in [1, 2, 3]:\nend", Nothing )
                ]
        , describe "run: for is live — mutating the array being iterated is visible to later iterations (a deliberately revisitable choice, see the language reference's \"for\" section)" <|
            List.map (testValue (run noNatives))
                [ ( """let a = [1, 2]
let count = 0
for x in a:
    count = count + 1
    if count == 1:
        Array.push(a, 3)
    end
end
return count"""
                  , Just (VNumber 3)
                  )
                , ( """let a = [1, 2, 3, 4, 5]
let seen = []
for x in a:
    if x == 3:
        break
    end
    Array.push(seen, x)
end
return Array.length(seen)"""
                  , Just (VNumber 2)
                  )
                , ( """let a = [1, 2, 3, 4, 5]
let seen = []
for x in a:
    if x == 3:
        continue
    end
    Array.push(seen, x)
end
return Array.length(seen)"""
                  , Just (VNumber 4)
                  )
                ]
        , describe "runIncremental: multiple scripts share one accumulating world scope" <|
            [ test "a later script sees an earlier script's globals" <|
                \_ ->
                    let
                        ( env, state1 ) =
                            I.initialWorld noNatives
                    in
                    case I.runIncremental env state1 "let x = 1" of
                        Err _ ->
                            Expect.fail "first script failed to run"

                        Ok ( _, state2 ) ->
                            I.runIncremental env state2 "return x"
                                |> Result.map Tuple.first
                                |> Expect.equal (Ok (VNumber 1))
            , test "a closure created in one script can reference a name only defined by a later one, resolved once it's actually called — the deferred cross-file reference pattern this exists for" <|
                \_ ->
                    let
                        ( env, state1 ) =
                            I.initialWorld noNatives
                    in
                    case I.runIncremental env state1 "let get_y = function(): return y end" of
                        Err _ ->
                            Expect.fail "first script failed to run"

                        Ok ( _, state2 ) ->
                            case I.runIncremental env state2 "let y = 2" of
                                Err _ ->
                                    Expect.fail "second script failed to run"

                                Ok ( _, state3 ) ->
                                    I.runIncremental env state3 "return get_y()"
                                        |> Result.map Tuple.first
                                        |> Expect.equal (Ok (VNumber 2))
            , test "redeclaring a name a previous script already defined is AlreadyDefined, the same as redeclaring within one file" <|
                \_ ->
                    let
                        ( env, state1 ) =
                            I.initialWorld noNatives
                    in
                    case I.runIncremental env state1 "let x = 1" of
                        Err _ ->
                            Expect.fail "first script failed to run"

                        Ok ( _, state2 ) ->
                            I.runIncremental env state2 "let x = 2"
                                |> Result.mapError dropRuntimePosition
                                |> Expect.equal (Err (RuntimeError (AlreadyDefined "x")))
            , test "mutation from one script is visible to a later one, same as tables already being references" <|
                \_ ->
                    let
                        ( env, state1 ) =
                            I.initialWorld noNatives
                    in
                    case I.runIncremental env state1 "let r = { count = 0 }" of
                        Err _ ->
                            Expect.fail "first script failed to run"

                        Ok ( _, state2 ) ->
                            case I.runIncremental env state2 "r.count = r.count + 1" of
                                Err _ ->
                                    Expect.fail "second script failed to run"

                                Ok ( _, state3 ) ->
                                    I.runIncremental env state3 "return r.count"
                                        |> Result.map Tuple.first
                                        |> Expect.equal (Ok (VNumber 1))
            , test "Array/Table are still seeded, same as run/runExpr" <|
                \_ ->
                    let
                        ( env, state1 ) =
                            I.initialWorld noNatives
                    in
                    I.runIncremental env state1 "return Array.length([1, 2, 3])"
                        |> Result.map Tuple.first
                        |> Expect.equal (Ok (VNumber 3))
            , test "a caller's own natives are seeded too, same as run/runExpr" <|
                \_ ->
                    let
                        natives =
                            Dict.singleton "walk_to" (NativeFunction (\state _ -> Ok ( VNumber 42, state )))

                        ( env, state1 ) =
                            I.initialWorld natives
                    in
                    I.runIncremental env state1 "return walk_to()"
                        |> Result.map Tuple.first
                        |> Expect.equal (Ok (VNumber 42))
            , test "a NativeZakExpr whose source doesn't parse is left undefined, instead of crashing" <|
                \_ ->
                    run (Dict.singleton "broken" (NativeZakExpr "function(:")) "return broken"
                        |> Expect.equal (Err (RuntimeError (UndefinedName "broken")))
            , test "a NativeZakExpr whose source fails to evaluate is left undefined too" <|
                \_ ->
                    run (Dict.singleton "broken" (NativeZakExpr "not_defined_anywhere")) "return broken"
                        |> Expect.equal (Err (RuntimeError (UndefinedName "broken")))
            , test "a broken NativeZakExpr doesn't take the other natives down with it" <|
                \_ ->
                    run
                        (Dict.fromList
                            [ ( "broken", NativeZakExpr "function(:" )
                            , ( "one", NativeZakExpr "function(): return 1 end" )
                            ]
                        )
                        "return one()"
                        |> Expect.equal (Ok (VNumber 1))
            , test "a NativeZakExpr that doesn't parse queues one LogError naming it, with the syntax error and its line" <|
                \_ ->
                    let
                        ( _, state ) =
                            I.initialWorld (Dict.singleton "broken" (NativeZakExpr "function(:"))
                    in
                    case state.pendingEffects of
                        [ Log LogError message ] ->
                            Expect.all
                                [ \_ -> message |> String.startsWith "native “broken” is left undefined, because its expression is broken.\n\nSyntax error at line 1" |> Expect.equal True
                                , \_ -> message |> String.contains "    function(:\n" |> Expect.equal True
                                ]
                                ()

                        other ->
                            Expect.fail ("expected one LogError, got: " ++ Debug.toString other)
            , test "a NativeZakExpr that fails to evaluate queues a LogError with the runtime error" <|
                \_ ->
                    let
                        ( _, state ) =
                            I.initialWorld (Dict.singleton "broken" (NativeZakExpr "not_defined_anywhere"))
                    in
                    state.pendingEffects
                        |> Expect.equal [ Log LogError "native “broken” is left undefined, because its expression is broken.\n\nRuntime error: “not_defined_anywhere” is not defined" ]
            , test "a broken NativeZakExpr inside a namespace is logged by its full dotted path" <|
                \_ ->
                    let
                        ( _, state ) =
                            I.initialWorld (Dict.singleton "Util" (NativeNamespace (Dict.singleton "triple" (NativeZakExpr "not_defined_anywhere"))))
                    in
                    case state.pendingEffects of
                        [ Log LogError message ] ->
                            message |> String.startsWith "native “Util.triple” is left undefined" |> Expect.equal True

                        other ->
                            Expect.fail ("expected one LogError, got: " ++ Debug.toString other)
            , test "working natives queue nothing" <|
                \_ ->
                    let
                        ( _, state ) =
                            I.initialWorld (Dict.singleton "one" (NativeZakExpr "function(): return 1 end"))
                    in
                    state.pendingEffects |> Expect.equal []
            ]
        , describe "Runtime.mapOutcomeResult (mapOutcome for a mapping that can fail)" <|
            let
                positive n =
                    if n > 0 then
                        Ok (n * 2)

                    else
                        Err (InternalError "not positive")

                ( _, state ) =
                    I.initialWorld noNatives

                resumed outcome =
                    case outcome of
                        Ok (Runtime.Suspended _ resume) ->
                            resume state |> Result.map Tuple.first

                        other ->
                            other
            in
            [ test "a Done outcome is mapped right away" <|
                \_ ->
                    Runtime.mapOutcomeResult positive (Runtime.Done 2)
                        |> Expect.equal (Ok (Runtime.Done 4))
            , test "a failing mapping on a Done outcome is an error right away" <|
                \_ ->
                    Runtime.mapOutcomeResult positive (Runtime.Done 0)
                        |> Expect.equal (Err (InternalError "not positive"))
            , test "a Suspended outcome is mapped once it resumes, and a failure surfaces then" <|
                \_ ->
                    ( Runtime.mapOutcomeResult positive (Runtime.Suspended (Runtime.Seconds 1) (\s -> Ok ( Runtime.Done 3, s )))
                        |> resumed
                    , Runtime.mapOutcomeResult positive (Runtime.Suspended (Runtime.Seconds 1) (\s -> Ok ( Runtime.Done -1, s )))
                        |> resumed
                    )
                        |> Expect.equal ( Ok (Runtime.Done 6), Err (InternalError "not positive") )
            , test "an InternalError reads as an interpreter bug, not a script problem" <|
                \_ ->
                    Zak.Helpers.describeRuntimeError (InternalError "a break signal escaped its enclosing loop")
                        |> Expect.equal "internal interpreter error: a break signal escaped its enclosing loop"
            ]
        , describe "include -- an embedder's `include(path)` native can be a thin wrapper around this" <|
            [ test "a file's own top-level statements land in the shared world scope, visible to code that runs after it" <|
                \_ ->
                    let
                        ( env, state1 ) =
                            I.initialWorld noNatives
                    in
                    case I.include "Helpers.zak" "let x = 1" state1 of
                        Err _ ->
                            Expect.fail "import failed"

                        Ok ( _, state2 ) ->
                            I.runIncremental env state2 "return x"
                                |> Result.map Tuple.first
                                |> Expect.equal (Ok (VNumber 1))
            , test "including the same path twice is a no-op the second time -- not a re-run, not an AlreadyDefined error (this is also the whole include-cycle guard)" <|
                \_ ->
                    let
                        ( _, state1 ) =
                            I.initialWorld noNatives
                    in
                    case I.include "Helpers.zak" "let x = 1" state1 of
                        Err _ ->
                            Expect.fail "first import failed"

                        Ok ( _, state2 ) ->
                            I.include "Helpers.zak" "let x = 1" state2
                                |> Result.map Tuple.first
                                |> Expect.equal (Ok VNil)
            , test "a genuinely different second file still runs normally after the first (the no-op above is keyed by path, not a blanket one-import-ever limit)" <|
                \_ ->
                    let
                        ( env, state1 ) =
                            I.initialWorld noNatives
                    in
                    case I.include "A.zak" "let x = 1" state1 of
                        Err _ ->
                            Expect.fail "first import failed"

                        Ok ( _, state2 ) ->
                            case I.include "B.zak" "let y = 2" state2 of
                                Err _ ->
                                    Expect.fail "second import failed"

                                Ok ( _, state3 ) ->
                                    I.runIncremental env state3 "return x + y"
                                        |> Result.map Tuple.first
                                        |> Expect.equal (Ok (VNumber 3))
            , test "a syntax error in the included source is a real IncludeParseError naming the path, not a crash" <|
                \_ ->
                    let
                        ( _, state1 ) =
                            I.initialWorld noNatives
                    in
                    case I.include "Broken.zak" "let x = " state1 of
                        Err (IncludeParseError path _) ->
                            path |> Expect.equal "Broken.zak"

                        other ->
                            Expect.fail ("expected an IncludeParseError, got: " ++ Debug.toString other)
            ]
        , describe "run: functions, recursion, and closures" <|
            List.map (testValue (run noNatives))
                [ ( """let factorial = function(n):
    if n == 0:
        return 1
    end
    return n * factorial(n - 1)
end
return factorial(5)"""
                  , Just (VNumber 120)
                  )
                , ( """let abs = function(n):
    if n < 0:
        return -n
    end
    return n
end
return abs(-7)"""
                  , Just (VNumber 7)
                  )

                -- the counter-closure example: each call to make_counter
                -- produces an independent, privately-mutated counter
                , ( """let make_counter = function():
    let count = 0
    return function():
        count = count + 1
        return count
    end
end
let next = make_counter()
next()
next()
return next()"""
                  , Just (VNumber 3)
                  )
                , ( """let make_counter = function():
    let count = 0
    return function():
        count = count + 1
        return count
    end
end
let counter_a = make_counter()
let counter_b = make_counter()
counter_a()
counter_a()
counter_b()
return counter_a()"""
                  , Just (VNumber 3)
                  )

                -- a "?"-suffixed name works as a definition *and* a call,
                -- not just the former -- pins the Zak.Lexer.keyword fix
                -- end to end (lex -> parse -> eval), not just at the
                -- parser level: "function?" used to fail to parse as a
                -- call, reading as the bare "function" keyword plus a
                -- stray "?" instead of an ordinary Name
                , ( """let function? = function(x):
    return type(x) == "function"
end
return function?(function?)"""
                  , Just (VBool True)
                  )
                ]
        , describe "run: natives" <|
            [ test "a flat native function can be called like any other" <|
                \_ ->
                    let
                        natives =
                            Dict.singleton "double" (NativeFunction doubleNative)

                        doubleNative state args =
                            case args of
                                [ VNumber n ] ->
                                    Ok ( VNumber (n * 2), state )

                                _ ->
                                    Err (TypeError { expected = "Number", got = VNil })
                    in
                    run natives "return double(21)"
                        |> Expect.equal (Ok (VNumber 42))
            , test "a native namespace is seeded as a real table, callable via Namespace.fn(...)" <|
                \_ ->
                    let
                        natives =
                            Dict.singleton "Util"
                                (NativeNamespace
                                    (Dict.singleton "double"
                                        (NativeFunction
                                            (\state args ->
                                                case args of
                                                    [ VNumber n ] ->
                                                        Ok ( VNumber (n * 2), state )

                                                    _ ->
                                                        Err (TypeError { expected = "Number", got = VNil })
                                            )
                                        )
                                    )
                                )
                    in
                    run natives "return Util.double(21)"
                        |> Expect.equal (Ok (VNumber 42))
            , test "a NativeZakExpr is parsed and evaluated once, exactly like a hand-written function" <|
                \_ ->
                    let
                        natives =
                            Dict.singleton "triple" (NativeZakExpr "function(n): return n * 3 end")
                    in
                    run natives "return triple(7)"
                        |> Expect.equal (Ok (VNumber 21))
            , test "a NativeZakExpr can live inside a namespace alongside plain natives, built as one table" <|
                \_ ->
                    let
                        natives =
                            Dict.singleton "Util"
                                (NativeNamespace
                                    (Dict.fromList
                                        [ ( "double", NativeFunction (\state args -> case args of
                                                [ VNumber n ] -> Ok ( VNumber (n * 2), state )
                                                _ -> Err (TypeError { expected = "Number", got = VNil })
                                            )
                                          )
                                        , ( "triple", NativeZakExpr "function(n): return n * 3 end" )
                                        ]
                                    )
                                )
                    in
                    run natives "return Util.double(3) + Util.triple(3)"
                        |> Expect.equal (Ok (VNumber 15))
            , test "true/false/nil can still be shadowed by natives... no, natives don't override them" <|
                \_ ->
                    -- natives merge in first, then true/false/nil are
                    -- inserted afterward, so a native can never accidentally
                    -- shadow one of these three
                    let
                        natives =
                            Dict.singleton "true" (NativeFunction (\state _ -> Ok ( VNumber 999, state )))
                    in
                    run natives "return true"
                        |> Expect.equal (Ok (VBool True))
            , test "Array/Table are seeded by Interpreter.run itself, even with zero natives passed in" <|
                \_ ->
                    run noNatives "return Array.length([1, 2, 3]) + Table.get({ x = 1 }, \"x\")"
                        |> Expect.equal (Ok (VNumber 4))
            , test "a caller cannot override the built-in Array/Table — builtinNatives always wins, same protection true/false/nil get" <|
                \_ ->
                    let
                        natives =
                            Dict.fromList
                                [ ( "Array", NativeFunction (\state _ -> Ok ( VNumber 999, state )) )
                                , ( "Table", NativeFunction (\state _ -> Ok ( VNumber 999, state )) )
                                ]
                    in
                    run natives "return Array.length([1, 2, 3]) + Table.get({ x = 1 }, \"x\")"
                        |> Expect.equal (Ok (VNumber 4))
            , test "Math/String/Debug/type are also seeded by Interpreter.run itself, even with zero natives passed in — full coverage of each lives in Test.Zak.Math/Test.Zak.String/Test.Zak.Debug/Test.Zak.Globals" <|
                \_ ->
                    run noNatives "Debug.log(String.from(Math.round(2.5)))\nreturn type(Math.pi)"
                        |> Expect.equal (Ok (VString "number"))
            , test "a caller cannot override Math/String/Debug/type either — same builtinNatives-over-stdlib-over-caller precedence" <|
                \_ ->
                    let
                        natives =
                            Dict.fromList
                                [ ( "Math", NativeFunction (\state _ -> Ok ( VNumber 999, state )) )
                                , ( "String", NativeFunction (\state _ -> Ok ( VNumber 999, state )) )
                                , ( "Debug", NativeFunction (\state _ -> Ok ( VNumber 999, state )) )
                                , ( "type", NativeFunction (\state _ -> Ok ( VNumber 999, state )) )
                                ]
                    in
                    run natives "let s = String.from(Math.abs(-5))\nDebug.log(s)\nreturn type(1) == \"number\" and s == \"5\""
                        |> Expect.equal (Ok (VBool True))
            , test "runExpr, unlike run, does NOT auto-include Math/String/Debug/type — the one deliberate asymmetry this design rests on" <|
                \_ ->
                    Expect.all
                        [ \_ -> I.runExpr noNatives "Math.pi" |> Expect.equal (Err (RuntimeError (UndefinedName "Math")))
                        , \_ -> I.runExpr noNatives "String.from(1)" |> Expect.equal (Err (RuntimeError (UndefinedName "String")))
                        , \_ -> I.runExpr noNatives "Debug.log(\"hi\")" |> Expect.equal (Err (RuntimeError (UndefinedName "Debug")))
                        , \_ -> I.runExpr noNatives "type(1)" |> Expect.equal (Err (RuntimeError (UndefinedName "type")))

                        -- but Array/Table still are, since those are unconditional everywhere
                        , \_ -> I.runExpr noNatives "Array.length([1])" |> Expect.equal (Ok (VNumber 1))
                        ]
                        ()
            ]
        , describe "runExpr: array equality is reference identity, not structural (Array.* natives themselves are tested in Test.Zak.Array)" <|
            [ test "two separately-built arrays with equal contents are not ==" <|
                \_ -> I.runExpr noNatives "[1, 2] == [1, 2]" |> Expect.equal (Ok (VBool False))
            , test "the same array reached through two different names is ==" <|
                \_ ->
                    run noNatives "let a = [1, 2]\nlet b = a\nreturn a == b"
                        |> Expect.equal (Ok (VBool True))
            ]
        , describe "exact RuntimeError returned (not just \"some\" failure)" <|
            -- `testValue`'s Just/Nothing convention above only proves an
            -- input fails, not that it fails for the *specific* reason
            -- intended — a bug that swapped in the wrong RuntimeError
            -- variant (or even a SyntaxError) would still pass those. These
            -- pin down the exact error for each RuntimeError case.
            [ test "undefined name" <|
                \_ ->
                    I.runExpr noNatives "undefined_name"
                        |> Expect.equal (Err (RuntimeError (UndefinedName "undefined_name")))
            , test "redeclaring a name in the same scope" <|
                \_ ->
                    run noNatives "let x = 1\nlet x = 2"
                        |> Expect.equal (Err (RuntimeError (AlreadyDefined "x")))
            , test "assigning to an undeclared name" <|
                \_ ->
                    run noNatives "x = 1"
                        |> Expect.equal (Err (RuntimeError (UndefinedName "x")))
            , test "reassigning a const-declared name" <|
                \_ ->
                    run noNatives "const x = 1\nx = 2"
                        |> Expect.equal (Err (RuntimeError (ConstReassigned "x")))
            , test "reassigning true is a ConstReassigned error, same as any other const" <|
                \_ ->
                    run noNatives "true = false"
                        |> Expect.equal (Err (RuntimeError (ConstReassigned "true")))
            , test "ordering two booleans is a hard error — no invented Bool ordering" <|
                \_ ->
                    I.runExpr noNatives "true < false"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number or String", got = VBool True })))
            , test "ordering two nils is a hard error — no invented Nil ordering" <|
                \_ ->
                    I.runExpr noNatives "nil < nil"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number or String", got = VNil })))
            , test "ordering a Number against a String is a hard error, no coercion either way" <|
                \_ ->
                    I.runExpr noNatives "1 < \"1\""
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "1" })))
            , test "ordering a String against a Number reports String as the type the left side actually is" <|
                \_ ->
                    I.runExpr noNatives "\"1\" < 1"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "in with a non-Array/Table right-hand side is a hard TypeError, not a silent false" <|
                \_ ->
                    I.runExpr noNatives "1 in 5"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array or Table", got = VNumber 5 })))
            , test "in with a non-String table key is a hard TypeError" <|
                \_ ->
                    I.runExpr noNatives "1 in { a = 1 }"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "for over a non-array" <|
                \_ ->
                    -- id 9, not 1: run's seven seeded NativeNamespaces
                    -- (Array, Debug, Math, Random, String, Table, Thread —
                    -- `type` is a plain function, no cell) each get a heap
                    -- cell during initialStateFull (ids 1-7, alphabetical
                    -- Dict.foldl order), before this script's own `for`
                    -- ever runs — id 0 is globals, id 8 is the top-level
                    -- block's own frame, so `{ a = 1 }`'s table cell lands
                    -- on 9
                    run noNatives "for x in { a = 1 }:\nend"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VTable 9 })))
            , test "reading a field that doesn't exist" <|
                \_ ->
                    I.runExpr noNatives "{ x = 1 }.y"
                        |> Expect.equal (Err (RuntimeError (UndefinedField "y")))
            , test "no auto-vivification of an intermediate step in a field chain" <|
                \_ ->
                    run noNatives "let r = { a = 1 }\nr.a.b = 2"
                        |> Expect.equal (Err (RuntimeError (NotATable (VNumber 1) "b")))
            , test "field access on a non-table" <|
                \_ ->
                    I.runExpr noNatives "(1).x"
                        |> Expect.equal (Err (RuntimeError (NotATable (VNumber 1) "x")))
            , test "index out of bounds, reading" <|
                \_ ->
                    I.runExpr noNatives "[1, 2, 3][3]"
                        |> Expect.equal (Err (RuntimeError (IndexOutOfBounds { index = 3, length = 3 })))
            , test "index out of bounds, assigning" <|
                \_ ->
                    run noNatives "let a = [1, 2, 3]\na[-1] = 99"
                        |> Expect.equal (Err (RuntimeError (IndexOutOfBounds { index = -1, length = 3 })))
            , test "indexing a non-array" <|
                \_ ->
                    I.runExpr noNatives "(1)[0]"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "indexing with a non-number" <|
                \_ ->
                    I.runExpr noNatives "[1, 2][\"x\"]"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            , test "indexing with a fractional number, reading" <|
                \_ ->
                    I.runExpr noNatives "[1, 2, 3][2.5]"
                        |> Expect.equal (Err (RuntimeError (NotAnInteger { index = 2.5 })))
            , test "indexing with a fractional number, assigning" <|
                \_ ->
                    run noNatives "let a = [1, 2, 3]\na[2.5] = 99"
                        |> Expect.equal (Err (RuntimeError (NotAnInteger { index = 2.5 })))
            , test "[index] assignment on a non-array" <|
                \_ ->
                    -- id 9, not 1: run's seven seeded NativeNamespaces
                    -- (Array, Debug, Math, Random, String, Table, Thread —
                    -- `type` is a plain function, no cell) each get a heap
                    -- cell during initialStateFull (ids 1-7, alphabetical
                    -- Dict.foldl order), before this script's own `let r`
                    -- ever runs — id 0 is globals, id 8 is the top-level
                    -- block's own frame, so r's table cell lands on 9
                    run noNatives "let r = { x = 1 }\nr[0] = 99"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VTable 9 })))
            , test "calling a non-function" <|
                \_ ->
                    I.runExpr noNatives "(1)(2)"
                        |> Expect.equal (Err (RuntimeError (NotAFunction (VNumber 1))))
            , test "wrong argument count" <|
                \_ ->
                    I.runExpr noNatives "function(a, b): return a end(1)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            , test "type error: adding a string to a number" <|
                \_ ->
                    I.runExpr noNatives "1 + \"a\""
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "a" })))
            , test "division by zero" <|
                \_ ->
                    I.runExpr noNatives "1 / 0"
                        |> Expect.equal (Err (RuntimeError (DivisionByZero "1 / 0 is undefined")))
            , test "floor-division by zero" <|
                \_ ->
                    I.runExpr noNatives "1 // 0"
                        |> Expect.equal (Err (RuntimeError (DivisionByZero "1 // 0 is undefined")))
            ]
        , describe "let/const shadowing an outer const queues a LogWarning (not an error — the binding still succeeds, same as shadowing anything else already does)" <|
            [ test "shadowing true at the top level warns, with the exact message" <|
                \_ ->
                    let
                        ( env, state1 ) =
                            I.initialWorld noNatives
                    in
                    case I.runIncremental env state1 "let true = false\nreturn true" of
                        Ok ( value, state2 ) ->
                            Expect.all
                                [ \_ -> value |> Expect.equal (VBool False)
                                , \_ ->
                                    state2.pendingEffects
                                        |> Expect.equal [ Log LogWarning "“true” shadows a const of the same name from an outer scope" ]
                                ]
                                ()

                        Err error ->
                            Expect.fail ("expected success, got: " ++ Debug.toString error)
            , test "a nested if body's let shadowing an outer const warns, and the shadowed value is used correctly inside" <|
                \_ ->
                    let
                        ( env, state1 ) =
                            I.initialWorld noNatives
                    in
                    case I.runIncremental env state1 "const x = 1\nlet y = 0\nif true:\n    let x = 2\n    y = x\nend\nreturn y" of
                        Ok ( value, state2 ) ->
                            Expect.all
                                [ \_ -> value |> Expect.equal (VNumber 2)
                                , \_ ->
                                    state2.pendingEffects
                                        |> Expect.equal [ Log LogWarning "“x” shadows a const of the same name from an outer scope" ]
                                ]
                                ()

                        Err error ->
                            Expect.fail ("expected success, got: " ++ Debug.toString error)
            , test "const shadowing an outer const also warns, not just let" <|
                \_ ->
                    let
                        ( env, state1 ) =
                            I.initialWorld noNatives
                    in
                    case I.runIncremental env state1 "const x = 1\nif true:\n    const x = 2\nend\nreturn x" of
                        Ok ( _, state2 ) ->
                            state2.pendingEffects
                                |> Expect.equal [ Log LogWarning "“x” shadows a const of the same name from an outer scope" ]

                        Err error ->
                            Expect.fail ("expected success, got: " ++ Debug.toString error)
            , test "shadowing an ordinary (non-const) outer let does not warn" <|
                \_ ->
                    let
                        ( env, state1 ) =
                            I.initialWorld noNatives
                    in
                    case I.runIncremental env state1 "let x = 1\nif true:\n    let x = 2\nend\nreturn x" of
                        Ok ( _, state2 ) ->
                            state2.pendingEffects |> Expect.equal []

                        Err error ->
                            Expect.fail ("expected success, got: " ++ Debug.toString error)
            , test "a plain top-level let with nothing to shadow does not warn" <|
                \_ ->
                    let
                        ( env, state1 ) =
                            I.initialWorld noNatives
                    in
                    case I.runIncremental env state1 "let x = 1\nreturn x" of
                        Ok ( _, state2 ) ->
                            state2.pendingEffects |> Expect.equal []

                        Err error ->
                            Expect.fail ("expected success, got: " ++ Debug.toString error)
            , test "same-frame redeclaration of a const name is still the existing AlreadyDefined error, not a warning" <|
                \_ ->
                    let
                        ( env, state1 ) =
                            I.initialWorld noNatives
                    in
                    I.runIncremental env state1 "const x = 1\nlet x = 2"
                        |> Expect.equal (Err (RuntimeError (WithPosition { row = 2, col = 1 } (AlreadyDefined "x"))))
            ]
        , describe "position tracking: a RuntimeError comes back wrapped in WithPosition, tagged with the statement that raised it (unstripped — the only block in this suite that looks at raw I.run/I.runIncremental output instead of going through this file's own dropRuntimePosition-wrapping run helper)" <|
            [ test "a single top-level statement's error is tagged with its own real (row, col)" <|
                \_ ->
                    I.run noNatives "return undefined_name"
                        |> Expect.equal (Err (RuntimeError (WithPosition { row = 1, col = 1 } (UndefinedName "undefined_name"))))
            , test "a later statement's error is tagged with its own line, not the first statement's" <|
                \_ ->
                    I.run noNatives "let x = 1\nreturn undefined_name"
                        |> Expect.equal (Err (RuntimeError (WithPosition { row = 2, col = 1 } (UndefinedName "undefined_name"))))
            , test "an error inside a nested if body is tagged with its own position, not the enclosing if's -- innermost statement wins" <|
                \_ ->
                    I.run noNatives "if true:\n    return undefined_name\nend"
                        |> Expect.equal (Err (RuntimeError (WithPosition { row = 2, col = 5 } (UndefinedName "undefined_name"))))
            , test "runExpr never wraps its error in WithPosition -- there's no statement/Block structure to tag a bare expression with" <|
                \_ ->
                    I.runExpr noNatives "undefined_name"
                        |> Expect.equal (Err (RuntimeError (UndefinedName "undefined_name")))
            , test "each runIncremental call's positions start fresh at row 1, relative to that call's own source -- not a running total across the whole accumulated world" <|
                \_ ->
                    let
                        ( env, state1 ) =
                            I.initialWorld noNatives
                    in
                    case I.runIncremental env state1 "let x = 1" of
                        Err _ ->
                            Expect.fail "first script failed to run"

                        Ok ( _, state2 ) ->
                            I.runIncremental env state2 "return undefined_name"
                                |> Expect.equal (Err (RuntimeError (WithPosition { row = 1, col = 1 } (UndefinedName "undefined_name"))))
            ]
        ]
