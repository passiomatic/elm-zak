module Test.Zak.Table exposing (suite)

import Dict
import Expect
import Test exposing (Test, describe, test)
import Zak.Internal.Interpreter as I exposing (Error(..))
import Zak.Internal.Runtime exposing (RuntimeError(..), Value(..))


{-| `Table` is seeded by `Zak.Internal.Interpreter` itself (see that module's own
doc), same as `Array` — no natives need passing in here at all.
-}
run : String -> Result Error Value
run =
    I.run Dict.empty


runExpr : String -> Result Error Value
runExpr =
    I.runExpr Dict.empty


suite : Test
suite =
    describe "Zak.Table (get, get_default, set, contains, clone, each)"
        [ describe "get (table first, matching Array's own argument order)" <|
            [ test "reads an existing field" <|
                \_ -> runExpr "Table.get({ x = 1 }, \"x\")" |> Expect.equal (Ok (VNumber 1))
            , test "missing field is a hard error, same as dot access" <|
                \_ ->
                    runExpr "Table.get({ x = 1 }, \"y\")"
                        |> Expect.equal (Err (RuntimeError (UndefinedField "y")))
            , test "wrong first argument type" <|
                \_ ->
                    runExpr "Table.get(1, \"x\")"
                        |> Expect.equal (Err (RuntimeError (NotATable (VNumber 1) "x")))
            , test "wrong second argument type" <|
                \_ ->
                    runExpr "Table.get({ x = 1 }, 1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Table.get({ x = 1 })"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            ]
        , describe "set (mutating, in place — creates the field if it doesn't already exist)" <|
            [ test "mutates in place, visible through an alias — the whole point of Table having heap identity" <|
                \_ ->
                    run
                        """
                        let r = { x = 1 }
                        let s = r
                        Table.set(r, "x", 99)
                        return Table.get(s, "x")
                        """
                        |> Expect.equal (Ok (VNumber 99))
            , test "returns the table itself" <|
                \_ ->
                    run
                        """
                        let r = { x = 1 }
                        let s = Table.set(r, "x", 99)
                        return Table.get(s, "x")
                        """
                        |> Expect.equal (Ok (VNumber 99))
            , test "creates the field if it doesn't already exist, same as table.field = value" <|
                \_ ->
                    run
                        """
                        let r = {}
                        Table.set(r, "x", 99)
                        return Table.get(r, "x")
                        """
                        |> Expect.equal (Ok (VNumber 99))
            , test "wrong first argument type" <|
                \_ ->
                    runExpr "Table.set(1, \"x\", 99)"
                        |> Expect.equal (Err (RuntimeError (NotATable (VNumber 1) "x")))
            , test "wrong second argument type" <|
                \_ ->
                    runExpr "Table.set({ x = 1 }, 1, 99)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Table.set({ x = 1 }, \"x\")"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 3, got = 2 })))
            ]
        , describe "get_default (like get, but a missing field returns the default instead of erroring)" <|
            [ test "reads an existing field, ignoring the default" <|
                \_ -> runExpr "Table.get_default({ x = 1 }, \"x\", 0)" |> Expect.equal (Ok (VNumber 1))
            , test "missing field returns the default instead of erroring" <|
                \_ -> runExpr "Table.get_default({ x = 1 }, \"y\", 0)" |> Expect.equal (Ok (VNumber 0))
            , test "default can be any type, independent of the field's own type" <|
                \_ -> runExpr "Table.get_default({ x = 1 }, \"y\", \"none\")" |> Expect.equal (Ok (VString "none"))
            , test "wrong first argument type" <|
                \_ ->
                    runExpr "Table.get_default(1, \"x\", 0)"
                        |> Expect.equal (Err (RuntimeError (NotATable (VNumber 1) "x")))
            , test "wrong second argument type is still a hard error — only a missing field is softened" <|
                \_ ->
                    runExpr "Table.get_default({ x = 1 }, 1, 0)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Table.get_default({ x = 1 }, \"x\")"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 3, got = 2 })))
            ]
        , describe "contains (the only way to test for a field's presence without risking the hard error get/dot access raise)" <|
            [ test "true when the field exists" <|
                \_ -> runExpr "Table.contains({ x = 1 }, \"x\")" |> Expect.equal (Ok (VBool True))
            , test "false when the field is absent" <|
                \_ -> runExpr "Table.contains({ x = 1 }, \"y\")" |> Expect.equal (Ok (VBool False))
            , test "wrong first argument type" <|
                \_ ->
                    runExpr "Table.contains(1, \"x\")"
                        |> Expect.equal (Err (RuntimeError (NotATable (VNumber 1) "x")))
            , test "wrong second argument type" <|
                \_ ->
                    runExpr "Table.contains({ x = 1 }, 1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "String", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Table.contains({ x = 1 })"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            ]
        , describe "clone (pure — a shallow copy, same semantics as Array.clone)" <|
            [ test "fields match right after cloning" <|
                \_ ->
                    runExpr "Table.get(Table.clone({ x = 1 }), \"x\")"
                        |> Expect.equal (Ok (VNumber 1))
            , test "a field write on the clone doesn't touch the original" <|
                \_ ->
                    run
                        """
                        let r = { x = 1 }
                        let s = Table.clone(r)
                        Table.set(s, "x", 99)
                        return Table.get(r, "x")
                        """
                        |> Expect.equal (Ok (VNumber 1))
            , test "a field write on the original doesn't touch the clone" <|
                \_ ->
                    run
                        """
                        let r = { x = 1 }
                        let s = Table.clone(r)
                        Table.set(r, "x", 99)
                        return Table.get(s, "x")
                        """
                        |> Expect.equal (Ok (VNumber 1))
            , test "a nested table field is shared, not copied — the one behavior most likely to surprise" <|
                \_ ->
                    run
                        """
                        let inner = { y = 1 }
                        let r = { nested = inner }
                        let s = Table.clone(r)
                        Table.set(Table.get(s, "nested"), "y", 99)
                        return Table.get(Table.get(r, "nested"), "y")
                        """
                        |> Expect.equal (Ok (VNumber 99))
            , test "the clone is a genuinely different table, not == to the original" <|
                \_ ->
                    run
                        """
                        let r = { x = 1 }
                        let s = Table.clone(r)
                        return r == s
                        """
                        |> Expect.equal (Ok (VBool False))
            , test "wrong argument type — TypeError, not NotATable (there's no field involved)" <|
                \_ ->
                    runExpr "Table.clone(1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Table", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Table.clone({}, {})"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            ]
        , describe "each (side effect per field — discards fn's return value; field order is Dict's natural order, not insertion order)" <|
            [ test "visits every field exactly once" <|
                \_ ->
                    run
                        """
                        let copy = {}
                        Table.each({ x = 1, y = 2 }, function(name, value):
                            Table.set(copy, name, value)
                        end)
                        return Table.get(copy, "x") * 10 + Table.get(copy, "y")
                        """
                        |> Expect.equal (Ok (VNumber 12))
            , test "an empty table is a no-op — fn is never called" <|
                \_ ->
                    run
                        """
                        let visited = []
                        Table.each({}, function(name, value):
                            Array.push(visited, name)
                        end)
                        return Array.length(visited)
                        """
                        |> Expect.equal (Ok (VNumber 0))
            , test "the table itself is unchanged afterward" <|
                \_ ->
                    run
                        """
                        let r = { x = 1 }
                        Table.each(r, function(name, value):
                            value
                        end)
                        return Table.get(r, "x")
                        """
                        |> Expect.equal (Ok (VNumber 1))
            , test "returns nil" <|
                \_ ->
                    runExpr "Table.each({ x = 1 }, function(name, value): value end)"
                        |> Expect.equal (Ok VNil)
            , test "wrong argument type" <|
                \_ ->
                    runExpr "Table.each(1, function(name, value): value end)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Table", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Table.each({ x = 1 })"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            ]
        , test "a script can still shadow Table itself with its own let, same as any other global" <|
            \_ ->
                run "let Table = { get = function(r, name): return 999 end }\nreturn Table.get({ x = 1 }, \"x\")"
                    |> Expect.equal (Ok (VNumber 999))
        ]
