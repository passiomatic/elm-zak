module Test.Zak.Array exposing (suite)

import Dict
import Expect
import Test exposing (Test, describe, test)
import Zak.Interpreter as I exposing (Error(..))
import Zak.Runtime exposing (RuntimeError(..), Value(..))


{-| `Array` is seeded by `Zak.Interpreter` itself now (see that module's
own doc), so no natives need passing in here at all — kept as a named
helper anyway, matching every other suite's convention.
-}
run : String -> Result Error Value
run =
    I.run Dict.empty


runExpr : String -> Result Error Value
runExpr =
    I.runExpr Dict.empty


suite : Test
suite =
    describe "Zak.Array (length, is_empty, get, get_default, set, push, append, contains, clone, each, map, indexed_map, filter, foldl, foldr)"
        [ describe "length" <|
            [ test "of an empty array" <|
                \_ -> runExpr "Array.length([])" |> Expect.equal (Ok (VNumber 0))
            , test "of a non-empty array" <|
                \_ -> runExpr "Array.length([1, 2, 3])" |> Expect.equal (Ok (VNumber 3))
            , test "wrong argument type" <|
                \_ ->
                    runExpr "Array.length(1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.length([], [])"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            ]
        , describe "is_empty" <|
            [ test "true for an empty array" <|
                \_ -> runExpr "Array.is_empty([])" |> Expect.equal (Ok (VBool True))
            , test "false for a non-empty array" <|
                \_ -> runExpr "Array.is_empty([1])" |> Expect.equal (Ok (VBool False))
            , test "wrong argument type" <|
                \_ ->
                    runExpr "Array.is_empty(1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            ]
        , describe "get (array first, matching every other Array function — index/predicate/fn operands after)" <|
            [ test "first, middle, and last element" <|
                \_ ->
                    Expect.all
                        [ \_ -> runExpr "Array.get([10, 20, 30], 0)" |> Expect.equal (Ok (VNumber 10))
                        , \_ -> runExpr "Array.get([10, 20, 30], 1)" |> Expect.equal (Ok (VNumber 20))
                        , \_ -> runExpr "Array.get([10, 20, 30], 2)" |> Expect.equal (Ok (VNumber 30))
                        ]
                        ()
            , test "negative index is out of bounds — no Python-style \"from the end\"" <|
                \_ ->
                    runExpr "Array.get([10, 20, 30], -1)"
                        |> Expect.equal (Err (RuntimeError (IndexOutOfBounds { index = -1, length = 3 })))
            , test "index == length is still out of bounds" <|
                \_ ->
                    runExpr "Array.get([10, 20, 30], 3)"
                        |> Expect.equal (Err (RuntimeError (IndexOutOfBounds { index = 3, length = 3 })))
            , test "wrong first argument type" <|
                \_ ->
                    runExpr "Array.get(1, 0)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "wrong second argument type" <|
                \_ ->
                    runExpr "Array.get([1], \"x\")"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.get([1])"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            , test "a whole-number float is fine, indistinguishable from an integer literal" <|
                \_ -> runExpr "Array.get([10, 20, 30], 2.0)" |> Expect.equal (Ok (VNumber 30))
            , test "a fractional index is a hard error, not silently rounded" <|
                \_ ->
                    runExpr "Array.get([10, 20, 30], 2.5)"
                        |> Expect.equal (Err (RuntimeError (NotAnInteger { index = 2.5 })))
            ]
        , describe "get_default (like get, but an out-of-range index returns the default instead of erroring)" <|
            [ test "in-range index, ignoring the default" <|
                \_ -> runExpr "Array.get_default([10, 20, 30], 1, 0)" |> Expect.equal (Ok (VNumber 20))
            , test "negative index returns the default instead of erroring" <|
                \_ -> runExpr "Array.get_default([10, 20, 30], -1, 0)" |> Expect.equal (Ok (VNumber 0))
            , test "index == length returns the default instead of erroring" <|
                \_ -> runExpr "Array.get_default([10, 20, 30], 3, 0)" |> Expect.equal (Ok (VNumber 0))
            , test "default can be any type, independent of the array's own element type" <|
                \_ -> runExpr "Array.get_default([10, 20, 30], 9, \"none\")" |> Expect.equal (Ok (VString "none"))
            , test "wrong first argument type" <|
                \_ ->
                    runExpr "Array.get_default(1, 0, 99)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "wrong second argument type" <|
                \_ ->
                    runExpr "Array.get_default([1], \"x\", 0)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "x" })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.get_default([1], 0)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 3, got = 2 })))
            , test "a fractional index is still a hard error — only an out-of-range index is softened" <|
                \_ ->
                    runExpr "Array.get_default([10, 20, 30], 2.5, 0)"
                        |> Expect.equal (Err (RuntimeError (NotAnInteger { index = 2.5 })))
            ]
        , describe "set (mutating, in place — no pure sibling, no ! suffix)" <|
            [ test "mutates in place, visible through an alias — the whole point of Array having heap identity" <|
                \_ ->
                    run
                        """
                        let a = [1, 2, 3]
                        let b = a
                        Array.set(a, 0, 99)
                        return Array.get(b, 0)
                        """
                        |> Expect.equal (Ok (VNumber 99))
            , test "returns the array itself" <|
                \_ ->
                    run
                        """
                        let a = [1, 2, 3]
                        let b = Array.set(a, 0, 99)
                        return Array.get(b, 0)
                        """
                        |> Expect.equal (Ok (VNumber 99))
            , test "out of bounds is an error, same as get" <|
                \_ ->
                    runExpr "Array.set([1, 2, 3], -1, 99)"
                        |> Expect.equal (Err (RuntimeError (IndexOutOfBounds { index = -1, length = 3 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.set([1, 2, 3], 0)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 3, got = 2 })))
            , test "a fractional index is a hard error, not silently rounded" <|
                \_ ->
                    runExpr "Array.set([1, 2, 3], 2.5, 99)"
                        |> Expect.equal (Err (RuntimeError (NotAnInteger { index = 2.5 })))
            ]
        , describe "push (mutating, in place — grows the array by one)" <|
            [ test "mutates in place, visible through an alias" <|
                \_ ->
                    run
                        """
                        let a = [1, 2, 3]
                        let b = a
                        Array.push(a, 4)
                        return Array.length(b)
                        """
                        |> Expect.equal (Ok (VNumber 4))
            , test "appends at the end" <|
                \_ ->
                    run
                        """
                        let a = [1, 2, 3]
                        Array.push(a, 4)
                        return Array.get(a, 3)
                        """
                        |> Expect.equal (Ok (VNumber 4))
            , test "returns the array itself" <|
                \_ ->
                    run
                        """
                        let a = [1, 2, 3]
                        let b = Array.push(a, 4)
                        return Array.get(b, 3)
                        """
                        |> Expect.equal (Ok (VNumber 4))
            , test "wrong argument type" <|
                \_ ->
                    runExpr "Array.push(2, 1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 2 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.push(1)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            ]
        , describe "append (mutating, in place — push generalized to a whole array's worth of elements)" <|
            [ test "mutates the target array in place, visible through an alias" <|
                \_ ->
                    run
                        """
                        let a = [1, 2]
                        let alias = a
                        Array.append(a, [3, 4])
                        return Array.length(alias)
                        """
                        |> Expect.equal (Ok (VNumber 4))
            , test "appends the other array's elements, in order, at the end" <|
                \_ ->
                    Expect.all
                        [ \_ ->
                            run "let a = [1, 2]\nArray.append(a, [3, 4])\nreturn Array.get(a, 2)"
                                |> Expect.equal (Ok (VNumber 3))
                        , \_ ->
                            run "let a = [1, 2]\nArray.append(a, [3, 4])\nreturn Array.get(a, 3)"
                                |> Expect.equal (Ok (VNumber 4))
                        ]
                        ()
            , test "the other array is left untouched" <|
                \_ ->
                    run
                        """
                        let a = [1, 2]
                        let other = [3, 4]
                        Array.append(a, other)
                        return Array.length(other)
                        """
                        |> Expect.equal (Ok (VNumber 2))
            , test "returns the mutated target array itself, not the other one" <|
                \_ ->
                    run
                        """
                        let a = [1, 2]
                        let b = Array.append(a, [3, 4])
                        return Array.length(b)
                        """
                        |> Expect.equal (Ok (VNumber 4))
            , test "appending an empty array is a no-op, still returns the target" <|
                \_ ->
                    run
                        """
                        let a = [1, 2]
                        Array.append(a, [])
                        return Array.length(a)
                        """
                        |> Expect.equal (Ok (VNumber 2))
            , test "wrong argument type — the target array" <|
                \_ ->
                    runExpr "Array.append(1, [1, 2])"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "wrong argument type — the array being appended" <|
                \_ ->
                    runExpr "Array.append([1, 2], 1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.append([1])"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            ]
        , describe "pop (mutating, in place — shrinks the array by one; returns the removed value, not the array)" <|
            [ test "removes and returns the last element" <|
                \_ ->
                    run
                        """
                        let a = [1, 2, 3]
                        let popped = Array.pop(a)
                        return popped
                        """
                        |> Expect.equal (Ok (VNumber 3))
            , test "shrinks the array, mutating in place, visible through an alias" <|
                \_ ->
                    run
                        """
                        let a = [1, 2, 3]
                        let b = a
                        Array.pop(a)
                        return Array.length(b)
                        """
                        |> Expect.equal (Ok (VNumber 2))
            , test "empty array is a hard error, not nil, matching Squirrel's own pop" <|
                \_ -> runExpr "Array.pop([])" |> Expect.equal (Err (RuntimeError EmptyArray))
            , test "wrong argument type" <|
                \_ ->
                    runExpr "Array.pop(1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.pop(1, 2)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            ]
        , describe "contains" <|
            [ test "true when the value is present" <|
                \_ -> runExpr "Array.contains([1, 2, 3], 2)" |> Expect.equal (Ok (VBool True))
            , test "false when the value is absent" <|
                \_ -> runExpr "Array.contains([1, 2, 3], 9)" |> Expect.equal (Ok (VBool False))
            , test "wrong argument type" <|
                \_ ->
                    runExpr "Array.contains(2, 1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 2 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.contains(1)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            ]
        , describe "clone (pure — a shallow copy: independent at the top level, but a nested array/table is still shared)" <|
            [ test "contents match right after cloning" <|
                \_ ->
                    runExpr "Array.get(Array.clone([1, 2, 3]), 1)"
                        |> Expect.equal (Ok (VNumber 2))
            , test "a targeted edit on the clone doesn't touch the original" <|
                \_ ->
                    run
                        """
                        let a = [1, 2, 3]
                        let b = Array.clone(a)
                        Array.set(b, 0, 99)
                        return Array.get(a, 0)
                        """
                        |> Expect.equal (Ok (VNumber 1))
            , test "a targeted edit on the original doesn't touch the clone" <|
                \_ ->
                    run
                        """
                        let a = [1, 2, 3]
                        let b = Array.clone(a)
                        Array.set(a, 0, 99)
                        return Array.get(b, 0)
                        """
                        |> Expect.equal (Ok (VNumber 1))
            , test "a nested array is shared, not copied — the one behavior most likely to surprise" <|
                \_ ->
                    run
                        """
                        let inner = [1]
                        let a = [inner]
                        let b = Array.clone(a)
                        Array.set(Array.get(b, 0), 0, 99)
                        return Array.get(Array.get(a, 0), 0)
                        """
                        |> Expect.equal (Ok (VNumber 99))
            , test "wrong argument type" <|
                \_ ->
                    runExpr "Array.clone(1)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.clone([], [])"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 1, got = 2 })))
            ]
        , describe "each (side effect per element, in order — discards fn's return value)" <|
            [ test "visits every element exactly once, in order" <|
                \_ ->
                    run
                        """
                        let visited = []
                        Array.each([1, 2, 3], function(value):
                            Array.push(visited, value)
                        end)
                        return Array.get(visited, 0) * 100 + Array.get(visited, 1) * 10 + Array.get(visited, 2)
                        """
                        |> Expect.equal (Ok (VNumber 123))
            , test "an empty array is a no-op — fn is never called" <|
                \_ ->
                    run
                        """
                        let visited = []
                        Array.each([], function(value):
                            Array.push(visited, value)
                        end)
                        return Array.length(visited)
                        """
                        |> Expect.equal (Ok (VNumber 0))
            , test "the array itself is unchanged afterward" <|
                \_ ->
                    run
                        """
                        let a = [1, 2, 3]
                        Array.each(a, function(value):
                            value
                        end)
                        return Array.get(a, 0)
                        """
                        |> Expect.equal (Ok (VNumber 1))
            , test "returns nil" <|
                \_ ->
                    runExpr "Array.each([1, 2, 3], function(value): value end)"
                        |> Expect.equal (Ok VNil)
            , test "wrong argument type" <|
                \_ ->
                    runExpr "Array.each(1, function(value): value end)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.each([1, 2, 3])"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            ]
        , describe "map (pure, whole-collection derivation)" <|
            [ test "applies fn to every element, returning a new array" <|
                \_ ->
                    run
                        """
                        let a = [1, 2, 3]
                        let b = Array.map(a, function(x): return x * 2 end)
                        return Array.get(b, 1)
                        """
                        |> Expect.equal (Ok (VNumber 4))
            , test "does not mutate the original array" <|
                \_ ->
                    run
                        """
                        let a = [1, 2, 3]
                        Array.map(a, function(x): return x * 2 end)
                        return Array.get(a, 0)
                        """
                        |> Expect.equal (Ok (VNumber 1))
            , test "preserves length" <|
                \_ ->
                    runExpr "Array.length(Array.map([1, 2, 3], function(x): return x end))"
                        |> Expect.equal (Ok (VNumber 3))
            , test "wrong argument type" <|
                \_ ->
                    runExpr "Array.map(1, function(x): return x end)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.map(function(x): return x end)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            ]
        , describe "indexed_map (pure, whole-collection derivation)" <|
            [ test "fn receives (index, element)" <|
                \_ ->
                    runExpr "Array.get(Array.indexed_map([10, 20, 30], function(i, x): return i + x end), 2)"
                        |> Expect.equal (Ok (VNumber 32))
            , test "wrong argument type" <|
                \_ ->
                    runExpr "Array.indexed_map(1, function(i, x): return x end)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.indexed_map(function(i, x): return x end)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            ]
        , describe "filter (pure, whole-collection derivation)" <|
            [ test "keeps only elements where the predicate is true" <|
                \_ ->
                    runExpr "Array.length(Array.filter([1, 2, 3, 4], function(x): return x > 2 end))"
                        |> Expect.equal (Ok (VNumber 2))
            , test "does not mutate the original array" <|
                \_ ->
                    run
                        """
                        let a = [1, 2, 3, 4]
                        Array.filter(a, function(x): return x > 2 end)
                        return Array.length(a)
                        """
                        |> Expect.equal (Ok (VNumber 4))
            , test "predicate must return a Bool" <|
                \_ ->
                    runExpr "Array.filter([1], function(x): return x end)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Bool", got = VNumber 1 })))
            , test "wrong argument type" <|
                \_ ->
                    runExpr "Array.filter(1, function(x): return true end)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.filter(function(x): return true end)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            ]
        , describe "foldl (pure, reduces left to right)" <|
            [ test "fn takes (element, accumulator), matching Elm's order" <|
                \_ ->
                    runExpr "Array.foldl([\"a\", \"b\", \"c\"], function(x, acc): return acc ++ x end, \"\")"
                        |> Expect.equal (Ok (VString "abc"))
            , test "wrong argument type" <|
                \_ ->
                    runExpr "Array.foldl(1, function(x, acc): return acc end, 0)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.foldl([1], function(x, acc): return acc end)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 3, got = 2 })))
            ]
        , describe "foldr (pure, reduces right to left)" <|
            [ test "folds in the opposite order from foldl" <|
                \_ ->
                    runExpr "Array.foldr([\"a\", \"b\", \"c\"], function(x, acc): return acc ++ x end, \"\")"
                        |> Expect.equal (Ok (VString "cba"))
            , test "wrong argument type" <|
                \_ ->
                    runExpr "Array.foldr(1, function(x, acc): return acc end, 0)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Array", got = VNumber 1 })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.foldr([1], function(x, acc): return acc end)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 3, got = 2 })))
            ]
        , describe "range (pure, a constructor — inclusive both ends, matching Elm's real List.range)" <|
            [ test "range(3, 6) == [3, 4, 5, 6]" <|
                \_ ->
                    run
                        """
                        let r = Array.range(3, 6)
                        return Array.length(r) == 4 and Array.get(r, 0) == 3 and Array.get(r, 3) == 6
                        """
                        |> Expect.equal (Ok (VBool True))
            , test "range(3, 3) == [3]" <|
                \_ ->
                    run
                        """
                        let r = Array.range(3, 3)
                        return Array.length(r) == 1 and Array.get(r, 0) == 3
                        """
                        |> Expect.equal (Ok (VBool True))
            , test "range(6, 3) == [] — empty, not an error, when lo > hi" <|
                \_ -> runExpr "Array.length(Array.range(6, 3))" |> Expect.equal (Ok (VNumber 0))
            , test "wrong first argument type" <|
                \_ ->
                    runExpr "Array.range(\"a\", 3)"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "a" })))
            , test "wrong second argument type" <|
                \_ ->
                    runExpr "Array.range(3, \"a\")"
                        |> Expect.equal (Err (RuntimeError (TypeError { expected = "Number", got = VString "a" })))
            , test "wrong argument count" <|
                \_ ->
                    runExpr "Array.range(3)"
                        |> Expect.equal (Err (RuntimeError (WrongArgCount { expected = 2, got = 1 })))
            ]
        , test "a script can still shadow Array itself with its own let, same as any other global" <|
            \_ ->
                run "let Array = { length = function(a): return 999 end }\nreturn Array.length([1, 2, 3])"
                    |> Expect.equal (Ok (VNumber 999))
        ]
