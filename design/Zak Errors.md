# Zak errors

A second pass on the Errors section of the public `Zak` module, before the package is published. It follows "Zak Public API.md", which left errors almost as they were inside the interpreter.

**Status:** implemented, 2026-10-05, on the `api-refactor` (elm-zak) and `zak-api-refactor` (the game) branches. Two things changed while implementing, both in "Changes made while implementing". Everything stays in the `Zak` module: a separate `Zak.Error` module would not be able to mention `Value`, because `Zak` and `Zak.Error` would then import each other.

## The problem

Today's Errors section exposes `Error(..)`, `RuntimeError(..)`, `Position`, `ParseError` and `errorToString`: 24 constructors in all.

1. **There are two error types, and one constructor has the same name as the other type.** `Error = SyntaxError ParseError | RuntimeError RuntimeError`, so the game writes `Zak.errorToString "" (Zak.RuntimeError error)`. Which type a function gives back varies: `run` and `call` give `Error`, while `include`, natives and `tick` give `RuntimeError`.
2. **The position is a wrapper constructor.** `WithPosition` wraps another error, so to ask what went wrong you have to unwrap it first. Both test suites have a helper just for that (`leaf`, `dropPosition`). A native can build one, too.
3. **Syntax errors come in two shapes.** There is `SyntaxError ParseError` and `IncludeParseError String ParseError`. And `ParseError = List Parser.DeadEnd` makes elm/parser part of the public API.
4. **About half the constructors are the library's own checks.** These are `DivisionByZero`, `DomainError`, `AssertionFailed`, `IndexOutOfBounds`, `NotAnInteger`, `NegativeIndex`, `EmptyArray`, `SuspendedNotAllowed`, `FormatArgMismatch`, `UnknownFormatDirective` and `InternalError`. No host branches on them. Their only use is the message. And every new check would be a breaking change.

**Evidence, from the game and the playground (2026-10-05):**

- **Natives raise a few kinds.** `TypeError` 49 times, `WrongArgCount` 23, `UndefinedName` 7, `IncludeNotFound` 3, and `DomainError` and `UndefinedField` once each.
- **Hosts read errors only through `errorToString`.** The one exception is `Scene.callHook`, which uses `Debug.toString`, and that's a bug.

## Decisions

| # | Topic | Decision |
|---|---|---|
| 1 | Where | Everything stays in `Zak`. No `Zak.Error` module. |
| 2 | Two types | `Problem(..)` says what went wrong. Its constructors are public, and natives return it. `Error` is opaque: a `Problem` plus where it happened. `run`, `call` and `tick` return it. |
| 3 | Name | `Problem`, the same name elm/parser uses. |
| 4 | Library checks | They all become one constructor, `Problem String`. It's the generic problem the library functions raise, and natives can raise it too. |
| 5 | Including | `Zak.include` is replaced by `nativeInclude`, a kind of native that does the whole job. So no native ever has to pass an `Error` on. |

## Proposal

### The Errors section

```elm
type Error                                    -- opaque

type Problem
    = SyntaxError String
    | UndefinedName String
    | AlreadyDefined String
    | ConstReassigned String
    | UndefinedField String
    | NotATable Value String
    | NotAFunction Value
    | WrongArgCount { expected : Int, got : Int }
    | TypeError { expected : String, got : Value }
    | IncludeNotFound String
    | Problem String

type alias Position = { row : Int, col : Int }

errorProblem  : Error -> Problem
errorPosition : Error -> Maybe Position
errorToString : String -> Error -> String
```

That's 3 types, 11 constructors and 3 functions. Today it's 4 types, 24 constructors and 1 function. `ParseError` leaves the API.

- **`SyntaxError String`** holds the parser's message without its position, e.g. ``expected `end` ``. Its position is read with `errorPosition`, like any other.
- **A file that fails to parse while it's being included** gives a `SyntaxError` whose message names the file and the line inside it. That's today's `IncludeParseError` message. Its position is the `include(...)` line, in the script that included it.
- **`Problem String`** is the message itself. Each of the library's checks becomes `Problem` with its message, e.g. `Problem "the array is empty"`.
- **`errorPosition`** is the position of the statement that failed, or where parsing stopped. It is `Nothing` for an error that happened outside any statement.
- **`errorToString`** keeps its signature and its output. The game's thread errors call `Zak.errorToString "" error`.

### Changed signatures

```elm
tick           : Float -> World -> ( List Error, World )
nativeFunction : (List Value -> World -> Result Problem ( Value, World )) -> Native
nativeInclude  : (String -> Maybe String) -> Native
```

`run` and `call` keep `Result Error ( Value, World )`. `include` and `RuntimeError(..)` leave the API.

### `nativeInclude`

```elm
Zak.init
    [ ( "include", Zak.nativeInclude (\path -> Dict.get path sourceTexts) ) ]
```

When a script calls `include(path)`:

- **Arguments:** anything other than one `String` is a `TypeError` or a `WrongArgCount`.
- **An unknown path** is an `IncludeNotFound path`.
- **A known path** has its source run into the world, as `Zak.include` did. A path that was already included is skipped, which also stops include cycles.

The host picks the name scripts call it by, as it does for any other native. The game's own `includeNative`, and its `IncludeNotFound` cases, go away.

### Inside

- **`Error` wraps the interpreter's error:** `type Error = Error Interpreter.Error`. `errorToString` keeps using `ErrorMessage` on it as today, so messages don't change. `errorProblem` and `errorPosition` read it.
- **The internal `RuntimeError` keeps all its kinds**, and gains one: `Problem String`, for problems raised by natives. Only the boundary simplifies them:
  - the 9 kinds the two types share map one to one;
  - `IncludeParseError` becomes `SyntaxError`, with its current message;
  - the 11 library checks become `Problem (describeRuntimeError error)`;
  - `WithPosition` is dropped from the `Problem` and read back by `errorPosition`. The interpreter only ever wraps once (`tagPosition`).
- **`ErrorMessage` exposes the syntax error's message and position on their own.** It already computes both (`deepestDeadEnds`, `describeProblems`) to build the full message.
- **A native that raises `SyntaxError msg`** comes back as `Problem msg`, since the interpreter has no syntax error without a position. That's harmless.

## Consequences

- **The game's natives barely change.** Their 72 `Err (TypeError …)` and `Err (WrongArgCount …)` lines stay exactly as they are. Only the annotations change, from `Result RuntimeError` to `Result Problem`. `Scene.transition`'s one `DomainError` becomes `Problem`.
- **Tests read the kind with `Result.mapError Zak.errorProblem`.** The `leaf` and `dropPosition` helpers go away. Tests that checked a library kind, like `DomainError` or `AssertionFailed`, check its message instead.
- **A native that calls back into Zak loses the callback's position.** Such a native calls `Zak.call`, gets an `Error`, and has to hand back `errorProblem error`. The game has no such native. The position of the native's own call is still added.

## Changes made while implementing

- **The game's tests load the helper files with `Zak.run`.** Five test files repeated the same chain of four `Zak.include` calls to load the helper files. That chain is now one function, `DefineHelpersFixture.loadHelpers`, which runs them with `Zak.run`.
- **`Actor.callVerb` used `Debug.toString` too**, not just `Scene.callHook`. Both now use `errorToString`, and three tests check the readable message instead of a constructor name. A side effect: the game now builds with `--optimize`.

## Deferred

- **`errorToString` can show the wrong line.** The host passes the source in, but a position doesn't know which file it belongs to. An error inside an included file, or inside a function that an earlier `run` defined, shows a line from the source that was passed. Thread errors pass `""` and show none. Fixing this means positions that know their file: the parser tags each position, the world remembers each file's source, and `run` takes a name the way `include` did. Once that's done, `errorToString` no longer needs a source argument.

## Order of work

Each step leaves both repos building, and all tests passing.

1. **Internals.** Add the internal `Problem String` and its message. `ErrorMessage` exposes the syntax error's message and position.
2. **`Problem` and the opaque `Error` in `Zak`.** This covers:
   - `errorProblem`, `errorPosition`, and `tick` returning `List Error`;
   - natives returning `Problem`;
   - removing `RuntimeError(..)` and `ParseError`;
   - rewriting the Errors section of the docs;
   - the public tests: `leaf` goes away, and new tests cover `errorPosition`, a library check giving `Problem`, and a native's `Problem` round trip.
3. **`nativeInclude` replaces `include`.** Tests cover a found path, an unknown path, wrong arguments, a path included twice, and a cycle. The include parse error test moves here.
4. **Playground.** Check that it still builds. It only uses `errorToString`.
5. **Game.**
   - annotations from `RuntimeError` to `Problem`;
   - `DomainError` to `Problem`;
   - `Boot` uses `nativeInclude`;
   - `Main`'s thread errors;
   - `Scene.callHook` uses `errorToString`;
   - tests use `errorProblem`.
6. **Check.** Run both test suites and `elm make --docs`, then the game and the playground in a browser. Update this doc's status, and decision 4 in "Zak Public API.md".
