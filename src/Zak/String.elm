module Zak.String exposing (displayString, natives)

{-| String-related functions under one `String` namespace table
(`String.from(value)`, `String.length(string)`, ...), following the exact
same shape as `Zak.Math`. `from` was this namespace's seed; `length`,
`is_empty`, `reverse`, `replace`, and `append` were its first real
*manipulation* functions — Zak's counterparts to Elm's own
`String.length`/`isEmpty`/`reverse`/`replace`/`append` — added the moment
a script actually needed them, per "a small, evidence-backed core,
extended later" (the same philosophy `Zak.Array`'s own build-out already
followed). More will likely land here the same way as further needs
surface.

`slice` landed the same way: deriving a name like `"logo"` from
`"img_logo"` needs a real substring primitive, not just the whole-string
`++`/`replace`/`reverse` already here. See `slice`'s own doc for the
specific, deliberate divergences from typical slice APIs that came out of
designing it.

Every function in this namespace is pure, with no exception and no
mutating twin for any of them — not a per-function naming choice, but because a
`VString` wraps a plain Elm `String` directly, with no heap id and so no
identity to mutate in the first place (unlike `VArray`/`VTable`, which
are heap cells precisely so they *can* be mutated in place and shared —
see `Zak.Runtime`'s own `Value` doc). "A targeted edit mutates, a
whole-collection derivation doesn't" (see "Arrays" in the language
reference) is a real choice for `Array`/`Table`; for `String` there's no
mutating option to choose between, so the question never arises.

`String.from(value)` exists because `++` (string concatenation) is
deliberately strict — both sides must already be a `String`, no
coercion, matching every other operator/native in the language (`Math`
functions, `Array.get`'s bounds check, `print` itself) — so building a
message out of literal text and a computed value needs an explicit
conversion step: `"I have " ++ String.from(shots) ++ " shots left"`.

Unlike `print`, this needs no `Debug.*` stand-in and no side-effect
channel at all — converting a `Value` to a `String` is pure, so it's
implemented as a plain, permanent, hand-written formatter, safe under
`elm make --optimize`.

Deliberately *not* recursive for `Array`/`Table`: a Zak array or table
can hold a reference to itself (`Array.push(a, a)`), so field-by-field
printing risks looping forever on a cycle. Solving that safely is a real,
separate problem — for now these get a fixed placeholder rather than
attempting to print their contents.

Exposes `natives`, merged in automatically by `Zak.Interpreter` (along
with `Zak.Math`/`Zak.Debug`/`Zak.Globals`) for `run`/`initialWorld`/
`runIncremental` — nothing needs to import or merge this by hand.
`runExpr` is the one entry point that deliberately does *not* include it.
-}

import Array
import Dict exposing (Dict)
import Hex
import Zak.Runtime exposing (NativeValue(..), RuntimeError(..), State, Value(..))


natives : Dict String NativeValue
natives =
    Dict.singleton "String"
        (NativeNamespace
            (Dict.fromList
                [ ( "from", NativeFunction stringFrom )
                , ( "length", NativeFunction stringLength )
                , ( "is_empty", NativeFunction stringIsEmpty )
                , ( "reverse", NativeFunction stringReverse )
                , ( "upper", NativeFunction stringUpper )
                , ( "lower", NativeFunction stringLower )
                , ( "replace", NativeFunction stringReplace )
                , ( "slice", NativeFunction stringSlice )
                , ( "append", NativeFunction stringAppend )
                , ( "format", NativeFunction stringFormat )
                ]
            )
        )


{-| Accepts any `Value` at all — there's a display string for every case,
so the only possible error is calling it with the wrong number of
arguments.
-}
stringFrom : State -> List Value -> Result RuntimeError ( Value, State )
stringFrom state args =
    case args of
        [ value ] ->
            Ok ( VString (displayString value), state )

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| `String.length(string)` — Elm's own `String.length` directly, which
counts UTF-16 code units, not user-perceived characters: an astral-plane
character (most emoji) is stored as a surrogate pair and counts as 2,
not 1 — inherited rather than adjusted for, the same way `Math.round`
inherits Elm's own round-half-up tie-breaking rather than reimplementing
rounding some other way.
-}
stringLength : State -> List Value -> Result RuntimeError ( Value, State )
stringLength state args =
    case args of
        [ VString string ] ->
            Ok ( VNumber (toFloat (String.length string)), state )

        [ other ] ->
            Err (TypeError { expected = "String", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| `String.is_empty(string)` — the `String` counterpart to
`Array.is_empty`, same naming and same shape: a plain predicate, no way
for this to fail beyond a wrong type or wrong arg count.
-}
stringIsEmpty : State -> List Value -> Result RuntimeError ( Value, State )
stringIsEmpty state args =
    case args of
        [ VString string ] ->
            Ok ( VBool (String.isEmpty string), state )

        [ other ] ->
            Err (TypeError { expected = "String", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| `String.reverse(string)` — Elm's own `String.reverse` directly:
always pure, since `String` has no identity to mutate in the first
place, so there was never a mutating form to choose between here (see
"Arrays" in the language reference for the rule this sidesteps).
Inherited straight from `Elm.Kernel.String`'s own implementation:
surrogate-pair aware (an astral-plane character, most emoji included,
reverses as one whole unit, not two swapped halves), but not
grapheme-cluster aware — a base character followed by a separate
combining-diacritic code point would still come back scrambled. Worth
knowing, not worth blocking on: no grapheme-cluster support exists
anywhere else in Zak either.
-}
stringReverse : State -> List Value -> Result RuntimeError ( Value, State )
stringReverse state args =
    case args of
        [ VString string ] ->
            Ok ( VString (String.reverse string), state )

        [ other ] ->
            Err (TypeError { expected = "String", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| `String.upper(string)` — Elm's own `String.toUpper` directly, which
is JavaScript's `toUpperCase` underneath: full Unicode case mapping, not
ASCII-only, so a single character can map to several and change the
string's length (`"ß"` becomes `"SS"`). Inherited rather than adjusted
for, the same way `String.length` inherits Elm's UTF-16 counting.
-}
stringUpper : State -> List Value -> Result RuntimeError ( Value, State )
stringUpper state args =
    case args of
        [ VString string ] ->
            Ok ( VString (String.toUpper string), state )

        [ other ] ->
            Err (TypeError { expected = "String", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| `String.lower(string)` — Elm's own `String.toLower` directly, the
mirror of `String.upper`: full Unicode case mapping via JavaScript's
`toLowerCase`, not ASCII-only.
-}
stringLower : State -> List Value -> Result RuntimeError ( Value, State )
stringLower state args =
    case args of
        [ VString string ] ->
            Ok ( VString (String.toLower string), state )

        [ other ] ->
            Err (TypeError { expected = "String", got = other })

        _ ->
            Err (WrongArgCount { expected = 1, got = List.length args })


{-| `String.replace(string, needle, replacement)` — the subject first,
matching `String.append`/`String.format`'s own argument order. Not the
target-last order this used to have —
that was borrowed from `Array.get_default`/`Table.get_default`, back
when `Array`/`Table` themselves put their own target last; now that
they've moved to target-first (see "Arrays"/"Tables" in the language
reference for the fuller history), keeping `replace` target-last would
have made it the one `String` function that disagreed with its own
siblings, for no reason tied to `String` itself. Wraps Elm's
`String.replace` directly — literal substring replacement, no regex,
replacing every occurrence, not just the first.

Deliberately reuses Elm's behavior verbatim on an empty `needle`, rather
than special-casing it into an error: `String.replace("abc", "", "-")`
returns `"a-b-c"`, inserting `replacement` between every character
(Elm's own `join after (split before string)` is where this comes
from). Surprising
on first read, but not corrupted or undefined the way a zero divisor or
an empty-array `pop` are — `""` is a perfectly ordinary `String` value
with a real, if unusual, meaning here. Stays in the same bucket as
`Math.round`'s tie-breaking or `Array.range`'s `lo > hi` case: a real,
deterministic Elm behavior, inherited and documented rather than
guarded against.
-}
stringReplace : State -> List Value -> Result RuntimeError ( Value, State )
stringReplace state args =
    case args of
        [ VString string, VString needle, VString replacement ] ->
            Ok ( VString (String.replace needle replacement string), state )

        [ other, VString _, VString _ ] ->
            Err (TypeError { expected = "String", got = other })

        [ _, VString _, other ] ->
            Err (TypeError { expected = "String", got = other })

        [ _, other, _ ] ->
            Err (TypeError { expected = "String", got = other })

        _ ->
            Err (WrongArgCount { expected = 3, got = List.length args })


{-| `String.slice(string, start, end)` — `string`, from `start` up to but
not including `end` (a plain half-open range, 0-based). `end` is
optional, defaulting to `string`'s own length — precedented in this
codebase by `Debug.assert` (`Zak.Debug`), the first Zak native to accept
a variable argument count. This is what makes deriving a name like
`"logo"` from `"img_logo"` read well: `String.slice(name, 4)`, no
separate `String.length(name)` call needed just to mean "to the end."

Two deliberate divergences from most slice APIs:

  - **No negative-index "count from the end" behavior.** Many slice APIs
    (Elm's own `String.slice`, which this wraps, included) treat a
    negative index as counting backward from the string's end. Zak
    doesn't — `start`/`end` are plain non-negative positions, matching
    `Array.get`'s own index philosophy (`0 <= index`, no wraparound) over
    importing a second meaning for the same argument slot that the
    motivating use case never actually needs.
  - **A negative or non-whole-number `start`/`end` is a hard
    `RuntimeError`** (`NegativeIndex`/`NotAnInteger` respectively) —
    again matching `Array.get`'s "this input is wrong, don't silently do
    something else" stance, not a fully permissive clamp-everything
    behavior.

Everything else about a bad range is ordinary, unremarkable clamping, the
usual out-of-range slice convention — not a `Math.sqrt`-style silently-wrong value worth
guarding against: an `end` past `string`'s own length just clamps to the
length, and `start >= end` (after clamping) yields `""`. Elm's own
`String.slice` already behaves this way: `String.slice 2 1 "abc" == ""`, `String.slice 0 999 "abc" == "abc"` — by
the time this function clamps both bounds into `[0, String.length
string]`, Elm's own behavior for whatever's left to resolve is exactly
what's wanted, not something to guard against.
-}
stringSlice : State -> List Value -> Result RuntimeError ( Value, State )
stringSlice state args =
    case args of
        [ VString string, VNumber startFloat, VNumber endFloat ] ->
            sliceChecked state string startFloat (Just endFloat)

        [ VString string, VNumber startFloat ] ->
            sliceChecked state string startFloat Nothing

        [ VString _, VNumber _, other ] ->
            Err (TypeError { expected = "Number", got = other })

        [ VString _, other ] ->
            Err (TypeError { expected = "Number", got = other })

        [ VString _, other, _ ] ->
            Err (TypeError { expected = "Number", got = other })

        [ other, VNumber _, VNumber _ ] ->
            Err (TypeError { expected = "String", got = other })

        [ other, VNumber _ ] ->
            Err (TypeError { expected = "String", got = other })

        [ other, _, _ ] ->
            Err (TypeError { expected = "String", got = other })

        [ other, _ ] ->
            Err (TypeError { expected = "String", got = other })

        [ _ ] ->
            Err (WrongArgCount { expected = 2, got = 1 })

        [] ->
            Err (WrongArgCount { expected = 2, got = 0 })

        _ ->
            Err (WrongArgCount { expected = 3, got = List.length args })


{-| Validates `start`/`end` (each non-negative, whole numbers —
`nonNegativeIndex`, below) before ever calling Elm's own `String.slice`,
then resolves an omitted `end` to `string`'s own length and clamps both
bounds into `[0, String.length string]`. Can't reuse
`Zak.Interpreter`'s own private `wholeNumberIndex` (the equivalent check
`Array.get`'s bounds-checking already does) — `Zak.Interpreter` is what
imports `Zak.String`'s `natives` in the first place, so importing it back
here would be circular; a small local duplicate is cheaper than a
shared-module refactor for one function.
-}
sliceChecked : State -> String -> Float -> Maybe Float -> Result RuntimeError ( Value, State )
sliceChecked state string startFloat maybeEndFloat =
    nonNegativeIndex startFloat
        |> Result.andThen
            (\start ->
                case maybeEndFloat of
                    Nothing ->
                        Ok ( start, String.length string )

                    Just endFloat ->
                        nonNegativeIndex endFloat |> Result.map (\end -> ( start, end ))
            )
        |> Result.map
            (\( start, end ) ->
                let
                    length =
                        String.length string
                in
                ( VString (String.slice (min start length) (min end length) string), state )
            )


{-| A `Float` that's both non-negative and a whole number, as the `Int`
`String.slice`'s own clamping needs — `NegativeIndex`/`NotAnInteger` on
whichever check fails first, matching `Array.get`'s own bounds-checking
order (type, then whole-number-ness, then range) except negativity is
checked ahead of whole-number-ness here, since a fractional *and*
negative index (`-2.5`) is unambiguously "negative" first, not two
independent problems to report at once.
-}
nonNegativeIndex : Float -> Result RuntimeError Int
nonNegativeIndex indexFloat =
    if indexFloat < 0 then
        Err (NegativeIndex { index = indexFloat })

    else
        let
            rounded =
                round indexFloat
        in
        if toFloat rounded == indexFloat then
            Ok rounded

        else
            Err (NotAnInteger { index = indexFloat })


{-| `String.append(a, b)` — literally `a ++ b`: Zak's own `++` is already
String-only (unlike Elm's polymorphic `(++)`), so this needs no
type-widening, just a callable spelling of the same operation. The one
thing `++` genuinely can't do that this can: Zak operators are
grammar-level, never reified as a callable `Value` — there's no way to
write `Array.foldr(strings, ++, "")`, since `++` isn't an expression on
its own — so `String.append` is the only way to hand
string-concatenation to something like `Array.foldr` as a first-class
function argument, the same reason `Table.get`/`Array.get` exist
alongside `.field`/`[index]` syntax rather than only duplicating it.
Note it composes with `Array.foldr`, not `Array.foldl`: `foldl`'s
callback convention is `fn(element, accumulator)`, so
`Array.foldl(["a","b","c"], String.append, "")` gives `"cba"`, not
`"abc"` — only `Array.foldr(["a","b","c"], String.append, "")` gives the
expected `"abc"`.
-}
stringAppend : State -> List Value -> Result RuntimeError ( Value, State )
stringAppend state args =
    case args of
        [ VString a, VString b ] ->
            Ok ( VString (a ++ b), state )

        [ VString _, other ] ->
            Err (TypeError { expected = "String", got = other })

        [ other, _ ] ->
            Err (TypeError { expected = "String", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


{-| `String.format(format, args)` — substitutes each `%s`/`%d`/`%f`/`%x`/
`%X`/`%%` in `format`, in order, with values from `args` (an `Array`).
A deliberately small printf-style subset: no flags/width/precision,
nothing beyond these five directives.

`%x`/`%X` (lowercase/uppercase hex) truncate toward zero like `%d`, then
format via `Hex.toString` (`rtfeldman/elm-hex`). Negative values are not
printed as a two's-complement bit pattern, as a fixed-width `%x` would:
Zak's `Number` has no fixed integer width anywhere else in the language,
so there's no principled width to wrap a negative value around — `%x`/`%X`
sign-prefix instead (`String.format("%x", [-255]) == "-ff"`), exactly
matching `Hex.toString`'s own behavior, not inventing a new rule.

`args` is never optional — always exactly two arguments, even when
`format` has no placeholders at all (`String.format("100%%", [])`, not
`String.format("100%%")`) — this native's own arity is exact, matching
every other `NativeFunction` in the language (Zak's real default-argument
mechanism, `function(a, b=1): ... end`, only applies to `function(...)`
closures, not natives — though an embedder's own native may still opt
into the same *calling convention*, via Elm-side arity handling rather
than Zak-level defaults).

Its own length must equal the number of `%s`/`%d`/`%f` placeholders in
`format` **exactly** — checked once, up front, against `countPlaceholders`
below, before any actual substitution happens, so a mismatch always
reports the true placeholder count and the true argument count, not
wherever the walk over `format` happened to run out first. Both too few
and too many are `FormatArgMismatch`, never silently tolerated, like
every other arity/bounds mismatch in the language.

`%s` accepts any value at all (the same `displayString` `String.from`
itself uses); `%d`/`%f` are hard `TypeError`s on anything but a `Number`.
`%d` truncates a fractional value toward zero (Elm's own `truncate`
already does exactly this); `%f` keeps the
full value via the same `String.fromFloat`-based path `displayString`'s
own `Number` case already uses (no fixed decimal-place count yet — that's
what precision support would add, once it's ever needed).
-}
stringFormat : State -> List Value -> Result RuntimeError ( Value, State )
stringFormat state args =
    case args of
        [ VString format, VArray arrayId ] ->
            let
                argValues =
                    Array.toList (Dict.get arrayId state.arrayHeap |> Maybe.withDefault Array.empty)

                expectedCount =
                    countPlaceholders (String.toList format)

                actualCount =
                    List.length argValues
            in
            if expectedCount /= actualCount then
                Err (FormatArgMismatch { expected = expectedCount, got = actualCount })

            else
                substituteFormat (String.toList format) argValues
                    |> Result.map (\formatted -> ( VString formatted, state ))

        [ VString _, other ] ->
            Err (TypeError { expected = "Array", got = other })

        [ other, _ ] ->
            Err (TypeError { expected = "String", got = other })

        _ ->
            Err (WrongArgCount { expected = 2, got = List.length args })


{-| How many of `%s`/`%d`/`%f`/`%x`/`%X` appear in `format` — `%%` and an
unknown directive both consume no argument, so neither counts here; an
unknown directive is left for `substituteFormat` to actually report as
`UnknownFormatDirective`, once the (unrelated) argument-count check this
feeds has already passed.
-}
countPlaceholders : List Char -> Int
countPlaceholders chars =
    case chars of
        [] ->
            0

        '%' :: '%' :: rest ->
            countPlaceholders rest

        '%' :: 's' :: rest ->
            1 + countPlaceholders rest

        '%' :: 'd' :: rest ->
            1 + countPlaceholders rest

        '%' :: 'f' :: rest ->
            1 + countPlaceholders rest

        '%' :: 'x' :: rest ->
            1 + countPlaceholders rest

        '%' :: 'X' :: rest ->
            1 + countPlaceholders rest

        '%' :: _ :: rest ->
            countPlaceholders rest

        _ :: rest ->
            countPlaceholders rest


{-| Walks `format` once, consuming one of `args` per `%s`/`%d`/`%f` in the
order each appears. Only ever called after `stringFormat` has already
confirmed `args`' length matches `countPlaceholders format` exactly, so
every `[]` branch below (a placeholder found with no argument left to
consume) is structurally unreachable — an `InternalError`, not a made-up
value, the same convention `Zak.Interpreter`'s own `signalValue` uses for
its equally impossible cases.
-}
substituteFormat : List Char -> List Value -> Result RuntimeError String
substituteFormat chars args =
    case chars of
        [] ->
            Ok ""

        '%' :: '%' :: rest ->
            substituteFormat rest args |> Result.map (\s -> "%" ++ s)

        '%' :: 's' :: rest ->
            case args of
                value :: restArgs ->
                    substituteFormat rest restArgs |> Result.map (\s -> displayString value ++ s)

                [] ->
                    Err (InternalError "String.format ran out of arguments at %s")

        '%' :: 'd' :: rest ->
            case args of
                (VNumber n) :: restArgs ->
                    substituteFormat rest restArgs |> Result.map (\s -> String.fromInt (truncate n) ++ s)

                other :: _ ->
                    Err (TypeError { expected = "Number", got = other })

                [] ->
                    Err (InternalError "String.format ran out of arguments at %d")

        '%' :: 'f' :: rest ->
            case args of
                (VNumber n) :: restArgs ->
                    substituteFormat rest restArgs |> Result.map (\s -> String.fromFloat n ++ s)

                other :: _ ->
                    Err (TypeError { expected = "Number", got = other })

                [] ->
                    Err (InternalError "String.format ran out of arguments at %f")

        '%' :: 'x' :: rest ->
            case args of
                (VNumber n) :: restArgs ->
                    substituteFormat rest restArgs |> Result.map (\s -> Hex.toString (truncate n) ++ s)

                other :: _ ->
                    Err (TypeError { expected = "Number", got = other })

                [] ->
                    Err (InternalError "String.format ran out of arguments at %x")

        '%' :: 'X' :: rest ->
            case args of
                (VNumber n) :: restArgs ->
                    substituteFormat rest restArgs |> Result.map (\s -> String.toUpper (Hex.toString (truncate n)) ++ s)

                other :: _ ->
                    Err (TypeError { expected = "Number", got = other })

                [] ->
                    Err (InternalError "String.format ran out of arguments at %X")

        '%' :: directive :: _ ->
            Err (UnknownFormatDirective ("%" ++ String.fromChar directive))

        [ '%' ] ->
            Err (UnknownFormatDirective "%")

        c :: rest ->
            substituteFormat rest args |> Result.map (\s -> String.fromChar c ++ s)


displayString : Value -> String
displayString value =
    case value of
        VString s ->
            s

        VNumber n ->
            String.fromFloat n

        VBool True ->
            "true"

        VBool False ->
            "false"

        VNil ->
            "nil"

        VArray _ ->
            "<array>"

        VTable _ ->
            "<table>"

        VFunction _ _ _ ->
            "<function>"

        VNative _ ->
            "<function>"

        VNativeThread _ ->
            "<function>"
