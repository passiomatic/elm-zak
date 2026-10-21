module Zak exposing
    ( World, init, game, updateGame, run, call, tick, reseed
    , Value(..), TableRef, ArrayRef, FunctionRef
    , getGlobal, setGlobal, globals, newTable, getField, setField, removeField, fields, items
    , ThreadOwner, startThread, stopThreads, hasThreads, setThreadOwner, threadCount
    , Effect(..), LogLevel(..), emitEffect, log, takeEffects
    , Error, Problem(..), Position, errorProblem, errorPosition, errorToString
    , Native, nativeFunction, nativeWaitingFunction, nativeTable, nativeExpression, nativeConstant, nativeInclude
    )

{-| Embed Zak, a small scripting language, in an Elm program.

A native is a name the host's Elm code gives its scripts, such as a
`say` function that makes a character speak. Most natives are Elm
functions, but a native can also be a table of natives, a Zak
expression or a constant (see [`Native`](#Native)). Scripts use natives
the way they use their own globals.

A host creates a [`World`](#World) with its own natives and its own
game, runs Zak source into it, calls the functions the scripts define,
and advances their threads once per frame. The world carries the game:
the host's natives read and change it as scripts call them (see
[`game`](#game)). Natives and scripts never perform effects themselves:
they queue them in the world, and the host takes them out with
[`takeEffects`](#takeEffects) and turns them into commands.

    world =
        Zak.init initialGame [ ( "say", say ) ]

    case Zak.run "say(\"Hello!\")" world of
        Ok ( _, world1 ) ->
            Zak.takeEffects world1

        Err error ->
            ...

Every function that changes a world takes it last and gives it back
second, so updates chain with `|>`.


# Running

@docs World, init, game, updateGame, run, call, tick, reseed


# Values

@docs Value, TableRef, ArrayRef, FunctionRef


# Data

@docs getGlobal, setGlobal, globals, newTable, getField, setField, removeField, fields, items


# Threads

@docs ThreadOwner, startThread, stopThreads, hasThreads, setThreadOwner, threadCount


# Effects

@docs Effect, LogLevel, emitEffect, log, takeEffects


# Errors

@docs Error, Problem, Position, errorProblem, errorPosition, errorToString


# Writing natives

@docs Native, nativeFunction, nativeWaitingFunction, nativeTable, nativeExpression, nativeConstant, nativeInclude

-}

import Array
import Dict exposing (Dict)
import Parser
import Random
import Zak.Internal.ErrorMessage as ErrorMessage
import Zak.Internal.Interpreter as Interpreter
import Zak.Internal.Runtime as Runtime



-- RUNNING


{-| Everything a running program has: its globals, tables and arrays,
waiting threads, queued effects and random seed, and the host's `game`.

`game` is the host's own data, whatever type it picks: its characters,
its rooms, its score. Zak only carries it, and never looks inside; the
host's own natives read and change it while scripts run (see
[`game`](#game)). A host with nothing to share uses `()`.

-}
type World game
    = World (Runtime.State game)


{-| A new world, with the standard library and `natives`. When two
natives share a name, the last one wins.

`natives` can add to the standard library, but never replace any of it. A
[`nativeTable`](#nativeTable) named like a standard one, such as
`Thread`, adds its fields to it, so scripts call `Thread.with_input_off`
next to `Thread.start`. A native the standard library already has, such
as `Thread.start` or `Math`, is ignored, and a `Log LogError` naming it is
queued.

A [`nativeExpression`](#nativeExpression) that fails to parse or evaluate
is left undefined, and a `Log LogError` naming it is queued, so the host
sees it on its first [`takeEffects`](#takeEffects).

-}
init : game -> List ( String, Native game ) -> World game
init initialGame natives =
    natives
        |> List.map (\( name, Native native ) -> ( name, native ))
        |> Dict.fromList
        |> Interpreter.initialWorld initialGame
        |> Tuple.second
        |> World


{-| The game `world` carries: what the host gave [`init`](#init), as its
natives and its own code have changed it since.

    position : List Value -> World Game -> Result Problem ( Value, World Game )
    position args world =
        case args of
            [ actor ] ->
                Ok ( Number (actorX actor (Zak.game world)), world )

            _ ->
                Err (WrongArgCount { expected = 1, got = List.length args })

-}
game : World game -> game
game (World state) =
    state.game


{-| Changes the game `world` carries. A native calls it to act on the game
right away, and the host to update its game from its own code, between
calls into Zak.

A change a native makes is part of the world like any other: if the call
that made it fails, the host gets an error and no world, and the change
is lost with it. The same goes for a thread that fails while
[`tick`](#tick) resumes it.

    walkTo : List Value -> World Game -> Result Problem ( Value, World Game )
    walkTo args world =
        case args of
            [ actor, Number x, Number y ] ->
                Ok ( Nil, Zak.updateGame (startWalk actor x y) world )

            _ ->
                Err (WrongArgCount { expected = 3, got = List.length args })

-}
updateGame : (game -> game) -> World game -> World game
updateGame f (World state) =
    World { state | game = f state.game }


{-| Runs Zak source into `world`, and gives back the value of its final
`return` (or `Nil`). Each run sees the globals earlier runs defined, so a
host can load several files one after another.
-}
run : String -> World game -> Result Error ( Value, World game )
run source (World state) =
    Interpreter.runIncremental (Interpreter.worldEnv state) state source
        |> Result.map (\( value, state1 ) -> ( fromInternal value, World state1 ))
        |> Result.mapError Error


{-| Calls a Zak function with `args`. Get the function first, with
[`getGlobal`](#getGlobal) or [`getField`](#getField):

    case Zak.getGlobal "on_click" world of
        Just fn ->
            Zak.call fn [ target ] world

        Nothing ->
            ...

A function called this way can't wait: one that wants to has to start a
thread (`Thread.start`) and wait there.

-}
call : Value -> List Value -> World game -> Result Error ( Value, World game )
call fn args (World state) =
    Interpreter.call state (toInternal fn) (List.map toInternal args)
        |> Result.map (\( value, state1 ) -> ( fromInternal value, World state1 ))
        |> Result.mapError Error


{-| Advances every waiting thread by `seconds`, resuming those whose wait
is over. A thread that fails is dropped, and its error is returned; the
errors come in the order the threads failed.

A thread waiting in one of the host's natives (see
[`nativeWaitingFunction`](#nativeWaitingFunction)) resumes once the
condition that native gave back is `False`. `tick` checks it with the
world as it is when that thread's turn comes, threads resumed before it
in the same `tick` included.

    Zak.tick dt world

See [`ThreadOwner`](#ThreadOwner) for the other ways a host manages
threads.

-}
tick : Float -> World game -> ( List Error, World game )
tick seconds (World state) =
    let
        ( state1, errors ) =
            Interpreter.tick seconds state
    in
    ( List.map (Interpreter.RuntimeError >> Error) (List.reverse errors), World state1 )


{-| Starts the `Random` functions over from `seed`. A new world always
starts from the same seed, so reseed it (from the time, say) for
different numbers on each run.
-}
reseed : Int -> World game -> World game
reseed seed (World state) =
    World { state | randomSeed = Random.initialSeed seed }



-- VALUES


{-| A Zak value. Tables, arrays and functions are references into a
world: the same table read twice is the same table, and a change made
through one reference shows through every other.
-}
type Value
    = Nil
    | Bool Bool
    | Number Float
    | String String
    | Array ArrayRef
    | Table TableRef
    | Function FunctionRef


{-| A reference to a table in a world. Read it with
[`getField`](#getField) or [`fields`](#fields). Two references are `==`
when they point at the same table, so a host can tell tables apart (to
stop at a table that contains itself, say).
-}
type TableRef
    = TableRef Int


{-| A reference to an array in a world. Read it with [`items`](#items).
Two references are `==` when they point at the same array.
-}
type ArrayRef
    = ArrayRef Int


{-| A Zak function, written in Zak or a native, in a world. Call it with
[`call`](#call). Two references are `==` when they point at the same
function.
-}
type FunctionRef
    = FunctionRef Int


fromInternal : Runtime.Value -> Value
fromInternal value =
    case value of
        Runtime.VNil ->
            Nil

        Runtime.VBool bool ->
            Bool bool

        Runtime.VNumber number ->
            Number number

        Runtime.VString string ->
            String string

        Runtime.VArray id ->
            Array (ArrayRef id)

        Runtime.VTable id ->
            Table (TableRef id)

        Runtime.VFunction id ->
            Function (FunctionRef id)


toInternal : Value -> Runtime.Value
toInternal value =
    case value of
        Nil ->
            Runtime.VNil

        Bool bool ->
            Runtime.VBool bool

        Number number ->
            Runtime.VNumber number

        String string ->
            Runtime.VString string

        Array (ArrayRef id) ->
            Runtime.VArray id

        Table (TableRef id) ->
            Runtime.VTable id

        Function (FunctionRef id) ->
            Runtime.VFunction id



-- DATA


{-| The global `name`, as a script at the top level would see it: one of
its own top-level definitions, or a native.
-}
getGlobal : String -> World game -> Maybe Value
getGlobal name (World state) =
    case globalFrame name state of
        Just frameId ->
            Dict.get frameId state.heap
                |> Maybe.andThen (Dict.get name)
                |> Maybe.map fromInternal

        Nothing ->
            Nothing


{-| Sets the global `name`, the way a top-level `name = value` would: the
existing global changes, wherever it's defined (a native included). A
name that isn't defined yet becomes a new top-level global, as with
`let`.

To give a [`nativeExpression`](#nativeExpression) a global it can read,
declare it as a native (`nativeConstant Nil`) and set it with this:
a native expression only sees natives, not the scripts' own globals.

-}
setGlobal : String -> Value -> World game -> World game
setGlobal name value (World state) =
    case globalFrame name state of
        Just frameId ->
            World { state | heap = Dict.update frameId (Maybe.map (Dict.insert name (toInternal value))) state.heap }

        Nothing ->
            World (Runtime.bindGlobal name (toInternal value) state)


{-| Every global the scripts defined at the top level, and every one
[`setGlobal`](#setGlobal) added. Natives and the standard library aren't
included.
-}
globals : World game -> Dict String Value
globals (World state) =
    Dict.get state.globalFrameId state.heap
        |> Maybe.withDefault Dict.empty
        |> Dict.map (\_ value -> fromInternal value)


{-| The frame `name` resolves to at the top level: the world's own
frame, then the natives' frame `0` under it.
-}
globalFrame : String -> Runtime.State game -> Maybe Int
globalFrame name state =
    let
        defines frameId =
            Dict.get frameId state.heap
                |> Maybe.map (Dict.member name)
                |> Maybe.withDefault False
    in
    if defines state.globalFrameId then
        Just state.globalFrameId

    else if defines 0 then
        Just 0

    else
        Nothing


{-| A new table with `entries` as its fields.

    ( point, world1 ) =
        Zak.newTable [ ( "x", Number 10 ), ( "y", Number 20 ) ] world

-}
newTable : List ( String, Value ) -> World game -> ( Value, World game )
newTable entries (World state) =
    let
        ( id, state1 ) =
            Runtime.allocCell state

        cell =
            entries
                |> List.map (Tuple.mapSecond toInternal)
                |> Dict.fromList
    in
    ( Table (TableRef id), World { state1 | heap = Dict.insert id cell state1.heap } )


{-| The field `key` of `table`. `Nothing` if the field isn't there, or
`table` isn't a table.
-}
getField : String -> Value -> World game -> Maybe Value
getField key table (World state) =
    case table of
        Table (TableRef id) ->
            Dict.get id state.heap
                |> Maybe.andThen (Dict.get key)
                |> Maybe.map fromInternal

        _ ->
            Nothing


{-| Sets the field `key` of `table`, adding it if it isn't there. Does
nothing if `table` isn't a table.

    world
        |> Zak.setField "x" (Number 10) point
        |> Zak.setField "y" (Number 20) point

-}
setField : String -> Value -> Value -> World game -> World game
setField key value table (World state) =
    case table of
        Table (TableRef id) ->
            World { state | heap = Dict.update id (Maybe.map (Dict.insert key (toInternal value))) state.heap }

        _ ->
            World state


{-| Removes the field `key` from `table`, as a script's `Table.remove`
does. Does nothing if `table` isn't a table, or has no such field.
Setting a field to `Nil` keeps it, so this is the only way to take one
out.

    world
        |> Zak.removeField "x" point

-}
removeField : String -> Value -> World game -> World game
removeField key table (World state) =
    case table of
        Table (TableRef id) ->
            World { state | heap = Dict.update id (Maybe.map (Dict.remove key)) state.heap }

        _ ->
            World state


{-| Every field of `table`. `Nothing` if `table` isn't a table.
-}
fields : Value -> World game -> Maybe (Dict String Value)
fields table (World state) =
    case table of
        Table (TableRef id) ->
            Dict.get id state.heap
                |> Maybe.map (Dict.map (\_ value -> fromInternal value))

        _ ->
            Nothing


{-| The items of `array`, in order. `Nothing` if `array` isn't an array.
-}
items : Value -> World game -> Maybe (List Value)
items array (World state) =
    case array of
        Array (ArrayRef id) ->
            Dict.get id state.arrayHeap
                |> Maybe.map (\cells -> List.map fromInternal (Array.toList cells))

        _ ->
            Nothing



-- THREADS


{-| Who a thread belongs to: a name the host picks. Zak defines none.

Every thread has an owner. A thread a script starts with `Thread.start`
gets the owner of the code that starts it, so the threads a thread
starts are its owner's too, at any depth. The host stops them all at once
with [`stopThreads`](#stopThreads).

The code the host runs or calls directly ([`run`](#run), [`call`](#call))
runs outside any thread, under the owner set with
[`setThreadOwner`](#setThreadOwner): `""` until the host sets one.

For example, a game can give each level its own owner, so leaving the
level stops the threads its scripts started, and run what outlives a
level (the music, say) under another one.

-}
type alias ThreadOwner =
    String


{-| Calls a function as a new thread owned by `owner`, and gives back
its id, as `Thread.start` does. Like `Thread.start`, its body runs at
once, up to its first wait, and [`tick`](#tick) resumes it from there. The
thread is `owner`'s from its first instruction, so a native its body
calls before that first wait already finds it with
[`hasThreads`](#hasThreads). A body that never waits leaves no thread
behind.

The id is what `Thread.join` and `Thread.stop` take, so a native can start
a thread under another owner and hand its id to a script to wait on:

    Thread.join (start_as_cutscene body)

An error before the first wait comes back as an `Err`, and the world is
left as it was.

-}
startThread : ThreadOwner -> Value -> List Value -> World game -> Result Error ( Value, World game )
startThread owner fn args (World state) =
    Interpreter.startThread owner (toInternal fn) (List.map toInternal args) state
        |> Result.map (\( id, state1 ) -> ( fromInternal id, World state1 ))
        |> Result.mapError Error


{-| Stops every thread `owner` owns, including those its threads started.

It takes effect at once: called from a native, it stops the threads that
exist at that moment, and threads the script starts after the call keep
running. A waiting thread never resumes. A running one, such as the
thread whose native called this, carries on to its next wait and ends
there, as with `Thread.stop`.

-}
stopThreads : ThreadOwner -> World game -> World game
stopThreads owner (World state) =
    World (Interpreter.stopThreads owner state)


{-| Whether `owner` owns any thread: waiting for [`tick`](#tick), or
running now, from its first instruction.
-}
hasThreads : ThreadOwner -> World game -> Bool
hasThreads owner (World state) =
    Interpreter.hasThreads owner state


{-| Sets the owner of the code the host runs or calls directly, so the
threads that code starts belong to `owner`. Inside a thread, the thread's
own owner applies instead.
-}
setThreadOwner : ThreadOwner -> World game -> World game
setThreadOwner owner (World state) =
    World (Interpreter.setThreadOwner owner state)


{-| How many threads are waiting for [`tick`](#tick). `0` means there's
nothing to advance, so a host can stop calling `tick` on every frame.
-}
threadCount : World game -> Int
threadCount (World state) =
    Interpreter.threadCount state



-- EFFECTS


{-| Something a script asked the host to do. The host takes these with
[`takeEffects`](#takeEffects), in the order they were queued, and turns
each one into whatever it wants, usually a `Cmd`.

  - `Log` comes from the language: `Debug.log` and its siblings, and the
    interpreter's own warnings. The host's natives queue one with
    [`log`](#log).
  - `Effect` comes from the host's own natives, through
    [`emitEffect`](#emitEffect): a name it chooses, and arguments elm-zak
    never looks inside.

-}
type Effect
    = Log LogLevel String
    | Effect String (List Value)


{-| How serious a `Log` is: `Debug.log` is `LogPrint`, `Debug.log_debug`
is `LogDebug`, and so on.
-}
type LogLevel
    = LogPrint
    | LogDebug
    | LogInfo
    | LogWarning
    | LogError


{-| Queues `Effect name args` for the host:

    Zak.emitEffect "play_sound" [ String "door_open" ] world

A `Table` or `Array` argument is queued as a reference, not a copy: the
host sees its contents as they are when it handles the effect, not as
they were when it was emitted.

-}
emitEffect : String -> List Value -> World game -> World game
emitEffect name args (World state) =
    World { state | pendingEffects = state.pendingEffects ++ [ Runtime.Effect name (List.map toInternal args) ] }


{-| Queues a `Log` for the host, as `Debug.log` and its siblings do, so a
native's message comes back in order with the script's own:

    Zak.log LogWarning "Unknown sound: door_open" world

-}
log : LogLevel -> String -> World game -> World game
log level message (World state) =
    World { state | pendingEffects = state.pendingEffects ++ [ Runtime.Log (logLevelToInternal level) message ] }


{-| Every effect queued since the last call, oldest first, and the world
with its queue emptied. Call it after each [`run`](#run), [`call`](#call)
or [`tick`](#tick).
-}
takeEffects : World game -> ( List Effect, World game )
takeEffects (World state) =
    let
        ( effects, state1 ) =
            Interpreter.drainEffects state
    in
    ( List.map effectFromInternal effects, World state1 )


effectFromInternal : Runtime.Effect -> Effect
effectFromInternal effect =
    case effect of
        Runtime.Log level message ->
            Log (logLevelFromInternal level) message

        Runtime.Effect name args ->
            Effect name (List.map fromInternal args)


logLevelToInternal : LogLevel -> Runtime.LogLevel
logLevelToInternal level =
    case level of
        LogPrint ->
            Runtime.LogPrint

        LogDebug ->
            Runtime.LogDebug

        LogInfo ->
            Runtime.LogInfo

        LogWarning ->
            Runtime.LogWarning

        LogError ->
            Runtime.LogError


logLevelFromInternal : Runtime.LogLevel -> LogLevel
logLevelFromInternal level =
    case level of
        Runtime.LogPrint ->
            LogPrint

        Runtime.LogDebug ->
            LogDebug

        Runtime.LogInfo ->
            LogInfo

        Runtime.LogWarning ->
            LogWarning

        Runtime.LogError ->
            LogError



-- ERRORS


{-| Why [`run`](#run), [`call`](#call) or a thread failed: a
[`Problem`](#Problem), and where it happened when that's known.
-}
type Error
    = Error Interpreter.Error


{-| What went wrong. Natives return these too, usually `TypeError` or
`WrongArgCount`:

    [ other ] ->
        Err (TypeError { expected = "String", got = other })

  - `SyntaxError` is the parser's message, such as `expected “end”`.
    A file that fails to parse while it's included gives one too, naming
    the file.
  - `Problem` is any other problem, described by its message. The
    standard library raises it, as in `Problem "the array is empty"`,
    and so can a native.

-}
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


{-| A place in the source: `row` and `col` both start at 1.
-}
type alias Position =
    { row : Int
    , col : Int
    }


{-| What went wrong.
-}
errorProblem : Error -> Problem
errorProblem (Error error) =
    case error of
        Interpreter.SyntaxError deadEnds ->
            SyntaxError (ErrorMessage.describeSyntaxError deadEnds)

        Interpreter.RuntimeError runtimeError ->
            problemFromInternal runtimeError


{-| Where it went wrong: the statement that failed, or where parsing
stopped. `Nothing` for an error outside any statement.
-}
errorPosition : Error -> Maybe Position
errorPosition (Error error) =
    case error of
        Interpreter.SyntaxError deadEnds ->
            ErrorMessage.syntaxErrorPosition deadEnds

        Interpreter.RuntimeError (Runtime.WithPosition position _) ->
            Just position

        Interpreter.RuntimeError _ ->
            Nothing


{-| A message a person can read. Pass the source that failed, and the
message shows its line with a `^` under the column:

    Runtime error at line 2, column 5:

        let y = x + 1
            ^

    “x” is not defined

Pass `""` when there's no source to show, as for an error from
[`tick`](#tick): the message is then one line.

-}
errorToString : String -> Error -> String
errorToString source (Error error) =
    case error of
        Interpreter.SyntaxError deadEnds ->
            ErrorMessage.formatSyntaxError source deadEnds

        Interpreter.RuntimeError runtimeError ->
            ErrorMessage.formatRuntimeError source runtimeError


problemFromInternal : Runtime.RuntimeError -> Problem
problemFromInternal error =
    case error of
        Runtime.UndefinedName name ->
            UndefinedName name

        Runtime.AlreadyDefined name ->
            AlreadyDefined name

        Runtime.ConstReassigned name ->
            ConstReassigned name

        Runtime.UndefinedField name ->
            UndefinedField name

        Runtime.NotATable value name ->
            NotATable (fromInternal value) name

        Runtime.NotAFunction value ->
            NotAFunction (fromInternal value)

        Runtime.WrongArgCount counts ->
            WrongArgCount counts

        Runtime.TypeError { expected, got } ->
            TypeError { expected = expected, got = fromInternal got }

        Runtime.IncludeNotFound path ->
            IncludeNotFound path

        Runtime.IncludeParseError _ _ ->
            SyntaxError (ErrorMessage.describeRuntimeError error)

        Runtime.Problem message ->
            Problem message

        Runtime.WithPosition _ inner ->
            problemFromInternal inner

        Runtime.DivisionByZero _ ->
            libraryProblem error

        Runtime.DomainError _ ->
            libraryProblem error

        Runtime.AssertionFailed _ ->
            libraryProblem error

        Runtime.IndexOutOfBounds _ ->
            libraryProblem error

        Runtime.NotAnInteger _ ->
            libraryProblem error

        Runtime.NegativeIndex _ ->
            libraryProblem error

        Runtime.EmptyArray ->
            libraryProblem error

        Runtime.SuspendedNotAllowed ->
            libraryProblem error

        Runtime.FormatArgMismatch _ ->
            libraryProblem error

        Runtime.UnknownFormatDirective _ ->
            libraryProblem error

        Runtime.InternalError _ ->
            libraryProblem error


{-| One of the standard library's own checks, which hosts only ever show:
its message.
-}
libraryProblem : Runtime.RuntimeError -> Problem
libraryProblem error =
    Problem (ErrorMessage.describeRuntimeError error)


problemToInternal : Problem -> Runtime.RuntimeError
problemToInternal problem =
    case problem of
        SyntaxError message ->
            Runtime.Problem message

        UndefinedName name ->
            Runtime.UndefinedName name

        AlreadyDefined name ->
            Runtime.AlreadyDefined name

        ConstReassigned name ->
            Runtime.ConstReassigned name

        UndefinedField name ->
            Runtime.UndefinedField name

        NotATable value name ->
            Runtime.NotATable (toInternal value) name

        NotAFunction value ->
            Runtime.NotAFunction (toInternal value)

        WrongArgCount counts ->
            Runtime.WrongArgCount counts

        TypeError { expected, got } ->
            Runtime.TypeError { expected = expected, got = toInternal got }

        IncludeNotFound path ->
            Runtime.IncludeNotFound path

        Problem message ->
            Runtime.Problem message



-- WRITING NATIVES


{-| A name the host defines for its scripts, which they use like one of
their own globals. It's one of these:

  - a function written in Elm, made with [`nativeFunction`](#nativeFunction);
  - a table of natives, made with [`nativeTable`](#nativeTable);
  - a function or other value written in Zak, made with
    [`nativeExpression`](#nativeExpression);
  - a fixed value, made with [`nativeConstant`](#nativeConstant);
  - the function that includes another file, made with
    [`nativeInclude`](#nativeInclude).

Give natives to [`init`](#init) by name. Unlike a script's globals, they
exist before any script runs.

A native is for one type of game, the same as its world's. One that never
touches the game is written for any game (`Native game`), so it fits every
world.

-}
type Native game
    = Native (Runtime.NativeValue game)


{-| A function written in Elm. It gets the arguments the script passed,
and the world; it gives back its result and the world, or an error.

    say : Native game
    say =
        Zak.nativeFunction
            (\args world ->
                case args of
                    [ String line ] ->
                        Ok ( Nil, Zak.emitEffect "say" [ String line ] world )

                    _ ->
                        Err (WrongArgCount { expected = 1, got = List.length args })
            )

-}
nativeFunction : (List Value -> World game -> Result Problem ( Value, World game )) -> Native game
nativeFunction fn =
    Native
        (Runtime.NativeFunction
            (\state args ->
                fn (List.map fromInternal args) (World state)
                    |> Result.map (\( value, World state1 ) -> ( toInternal value, state1 ))
                    |> Result.mapError problemToInternal
            )
        )


{-| A function written in Elm that makes the script calling it wait, for
what only the host knows, such as a character walking. Instead of a
result, it gives back a condition on the world: the script waits while
it's `True`, and carries on once [`tick`](#tick) finds it `False`. The
first check is on the next `tick`, never at once, and the call then gives
back `nil`.

    waitWhileWalking : Native Game
    waitWhileWalking =
        Zak.nativeWaitingFunction
            (\args world ->
                case args of
                    [ hero ] ->
                        Ok ( \w -> isWalking hero (Zak.game w), world )

                    _ ->
                        Err (WrongArgCount { expected = 1, got = List.length args })
            )

The condition can read the whole world: the game, and the scripts'
globals and tables. It can't change it.

Like `Thread.wait_for`, only a thread can wait, and only in a call that
is a statement of its own: `wait_while_walking(hero)`, not `let x =
wait_while_walking(hero)`. Anywhere else, the call is an error.

-}
nativeWaitingFunction : (List Value -> World game -> Result Problem ( World game -> Bool, World game )) -> Native game
nativeWaitingFunction fn =
    Native
        (Runtime.NativeThreadFunction
            (\state args ->
                fn (List.map fromInternal args) (World state)
                    |> Result.map
                        (\( stillWaiting, World state1 ) ->
                            ( Runtime.Suspended (Runtime.Host (World >> stillWaiting)) (\resumed -> Ok ( Runtime.Done Runtime.VNil, resumed ))
                            , state1
                            )
                        )
                    |> Result.mapError problemToInternal
            )
        )


{-| A table of natives, which scripts reach with a dot: `Sound.play(...)`.

    Zak.nativeTable [ ( "play", play ), ( "stop", stop ) ]

-}
nativeTable : List ( String, Native game ) -> Native game
nativeTable natives =
    natives
        |> List.map (\( name, Native native ) -> ( name, native ))
        |> Dict.fromList
        |> Runtime.NativeNamespace
        |> Native


{-| A native written in Zak: one Zak expression, usually a function,
evaluated once when the world is created.

    Zak.nativeExpression "function(x): return x * 2 end"

It's an expression, not a program, so `let` and other statements don't
work at its top level. It sees the natives and the standard library, but
not the scripts' own globals. One that fails to parse or evaluate is
left undefined, and logged (see [`init`](#init)).

-}
nativeExpression : String -> Native game
nativeExpression source =
    Native (Runtime.NativeZakExpr source)


{-| A fixed value.

    Zak.nativeConstant (Number 3.14)

-}
nativeConstant : Value -> Native game
nativeConstant value =
    Native (Runtime.NativeConstant (toInternal value))


{-| The native that includes a file: `include("Scenes/Diner.zak")`. Its
argument is a path, and `find` gives back that file's source.

    Zak.init initialGame
        [ ( "include", Zak.nativeInclude (\path -> Dict.get path files) ) ]

The file runs as if it were part of the script that includes it: its
top-level definitions become globals, shared with every other script,
with no table of their own to reach them through. A path already
included is skipped, which also stops include cycles. A path `find`
doesn't know is an `IncludeNotFound`.

-}
nativeInclude : (String -> Maybe String) -> Native game
nativeInclude find =
    Native
        (Runtime.NativeFunction
            (\state args ->
                case args of
                    [ Runtime.VString path ] ->
                        case find path of
                            Just source ->
                                Interpreter.include path source state

                            Nothing ->
                                Err (Runtime.IncludeNotFound path)

                    [ other ] ->
                        Err (Runtime.TypeError { expected = "String", got = other })

                    _ ->
                        Err (Runtime.WrongArgCount { expected = 1, got = List.length args })
            )
        )
