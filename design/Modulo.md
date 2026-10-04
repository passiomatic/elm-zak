# Modulo

A modulo operation for Zak: which semantics, operator or function, and how it relates to the existing `//`. Nothing is implemented yet. This page records the options and a recommendation so it can be revised before deciding.

**Sources:**
- Elm's `modBy` / `remainderBy`: https://package.elm-lang.org/packages/elm/core/latest/Basics#modBy
- Daan Leijen, *Division and Modulus for Computer Scientists* (linked from Elm's docs): https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/divmodnote-letter.pdf
- Python's `%` (floored).
- Squirrel 3.2 (Homebrew `squirrel-lang`), run locally, plus its VM source `squirrel/sqvm.cpp` at tag `v3.2` (github.com/albertodemichelis/squirrel), fetched with `gh`.
- Zak source: `src/Zak/Interpreter.elm` (`evalBinary`, `checkedDivide`), `src/Zak/Parser.elm` (`multiplicativeOp`).

## What Zak has today

- Every number is an Elm `Float`. There's no separate integer type.
- `//` is already **floor division**. `evalBinary` computes it as `toFloat (floor (a / b))`, through `checkedDivide`.
- `checkedDivide` raises `DivisionByZero` for both `/` and `//`, so NaN and Infinity never reach script code.
- `*`, `/` and `//` share one precedence level, parsed by `multiplicativeOp`. `//` is tried before `/` so the longer token matches first.
- `%` means nothing in Zak code. It only appears inside `String.format` strings, which is a separate thing.

## The three semantics (Leijen)

A division and its modulo are defined as a pair, and must satisfy

```
a == b * (a // b) + a % b
```

| | `-7 % 3` | `7 % -3` | `-7 % -3` | Sign of the result | Used by |
|---|---|---|---|---|---|
| **T**: truncated (rounds toward 0) | -1 | 1 | -1 | same as the left number | C, JS, Squirrel, Elm `remainderBy` |
| **F**: floored | 2 | -2 | -1 | same as the right number | Python `%`, Lua `%`, Elm `modBy` |
| **E**: Euclidean | 2 | 1 | 2 | never negative | Leijen's recommendation |

- **F and E give the same answer whenever the divisor is positive**, which covers nearly all game uses: wrapping an index or animation frame, `angle % 360`, "every Nth tick". They differ only when you divide by a negative number, which is rare.
- **T is the one that causes bugs.** Stepping back through a list with `(i - 1) % n` gives `-1` when `i` is 0. This is the pitfall Leijen's paper warns about.

## What Squirrel does

Squirrel's `%` is **truncated**, like C's: the result takes the sign of the left number. Checked by running Squirrel 3.2:

| Expression | Squirrel | Truncated `/` |
|---|---|---|
| `-7 % 3` | -1 | `-7 / 3 == -2` |
| `7 % -3` | 1 | `7 / -3 == -2` |
| `-7 % -3` | -1 | `-7 / -3 == 2` |
| `-1 % 4` | -1 | |
| `5.5 % 2` | 1.5 | |

- **Integers** use C's `%` directly (`res = i1 % i2`). Squirrel's integer `/` also truncates, so its `/` and `%` are a consistent T pair.
- **Floats** use C's `fmod`, which is truncated too.
- **Modulo by zero is broken for integers.** The VM raises `"modulo by zero"`, but the `_OP_MOD` case calls `ARITH_OP` without the `_GUARD` wrapper that `/` has (`sqvm.cpp:875` at v3.2; unchanged on master). The error is never thrown:
  - `local a = 7; local b = 0; a % b` evaluates to `null` without an error;
  - the constant expression `7 % 0` evaluates to `7`;
  - integer `7 / 0` correctly raises `"division by zero"`.
- **Float modulo by zero** returns `nan`, with no error either. Float `/` by zero likewise doesn't raise; only integer `/` does.

**Dinky.** DeloresDev's docs (`HelpDocsHtml`) don't define `%`. The one use in its scripts is `open_count++ % 4 == 0` (`Scripts/Rooms/Nickel.dinky:334` in the DeloresDev source), with a non-negative left number and a positive divisor. There T, F and E all agree, so matching Dinky doesn't force a choice.

## Why choosing E means changing `//`

The quotient and the remainder aren't independent. Once `a // b` is fixed, the remainder is whatever is left over: `a % b = a - b * (a // b)`. So each division comes with exactly one matching remainder:
- a floored `//` implies a floored `%`;
- a Euclidean `%` requires a Euclidean `//`.

**Worked example: `a = 7`, `b = -3`.** The true quotient is -2.33…

- Today's `//` floors it: `7 // -3 == -3`, so the matching remainder is `7 - (-3)(-3) = -2`. That's F.
- E requires a non-negative remainder, `7 % -3 == 1`, which needs the quotient `-2` (`-3 * -2 + 1 == 7`). That rounds *up* here, so it's no longer what `//` does.
- Mixing today's `//` with a Euclidean `%` breaks the identity: `-3 * (7 // -3) + 7 % -3 == 10`, not `7`.

This only matters for negative divisors. With `b > 0`, floored and Euclidean division agree on both quotient and remainder.

It's a consistency requirement, not a technical one. Nothing in the interpreter enforces the identity. A Euclidean `%` could ship next to the floored `//`, but the two would then disagree for negative divisors, which is the mismatch Leijen argues against.

## Other decisions

1. **Operator or function.**
   - A `%` operator goes in `multiplicativeOp` next to `//`, with the same precedence. It would also give `%=` for free in the planned compound-assignment phase.
   - A `Math.mod(a, b)` function avoids precedence questions and states its semantics in its name.
   - Elm's `modBy` puts the modulus first so it composes with `|>`. Zak has no pipes, so that reason doesn't carry over.
2. **Fractional numbers.** Because every number is a `Float`, `%` works on fractions (`5.5 % 2 == 1.5`), which is useful for angles and timers.
   - The catch: with floored modulo, rounding can make `(-1e-20) % 360` return exactly `360` (Python does the same), so "the result is always less than the modulus" fails at the very edge.
   - The alternative is to accept only whole numbers, reusing the existing `NotAnInteger` error. That rules out angles.
3. **Division by zero.** Reuse `checkedDivide` as it is, so `%` raises `DivisionByZero` like `/` and `//`.
4. **Modulo and remainder both** (Haskell's `mod`/`rem`, Elm's `modBy`/`remainderBy`). No game need for a truncated remainder has come up, so leave it out until one does.

## Recommendation (not decided)

A **floored `%` operator**, paired with the existing `//`:
- It works like Python's and Lua's, so it won't surprise anyone.
- `//` doesn't change.
- It works on fractional numbers.
- It reuses `checkedDivide`, so the change is small: the parser (`multiplicativeOp`), the syntax tree (`BinaryOp` in `AST.elm`) and `evalBinary`.

Euclidean is the choice in principle, but it only wins for negative divisors and would mean redefining `//`.

## Open

- Floored `%` (recommended) or Euclidean with `//` redefined?
- `%` operator or `Math.mod` function?
- Fractional numbers allowed (recommended), or whole numbers only?
