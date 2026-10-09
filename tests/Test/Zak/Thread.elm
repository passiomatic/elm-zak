module Test.Zak.Thread exposing (suite)

{-| Exercises the suspend/resume scheduler:
`Thread.start` and the host's `startThread` (spawn, run
synchronously to the first suspend point, never block the caller),
`Thread.wait_for`/`Thread.join`
(the two primitives that actually suspend — there's no frame-counted
yield), and `Zak.Internal.Interpreter.tick` (the once-per-frame scheduler step
that resumes them). Uses
`initialWorld`/`runIncremental` directly (not the simpler `run`)
specifically to get at the returned `State` afterward — inspecting
`state.threads` and, for the "did the resumed code really run" checks,
reading a Zak table's own field back out of `state.heap` directly, since
a script's own return value only captures a snapshot at the moment it
returns, before any later `tick` has run.
-}

import Dict
import Expect
import Test exposing (Test, describe, test)
import Zak.Internal.Interpreter as I exposing (tick)
import Zak.Internal.Runtime as Runtime exposing (NativeValue(..), RuntimeError(..), Value(..))


{-| Runs `source` against a fresh world (no caller-supplied natives — the
threading primitives are already unconditional in `initialWorld`, same
tier as `Math`/`String`/`print`/`type`), returning both the top-level
script's own return value and the resulting `State`, so tests can inspect
`state.threads`/`state.heap` afterward.

Strips any `WithPosition` a `RuntimeError` comes back wrapped in — this
suite pins down *which* `RuntimeError` a case produces, the same as
before position-tracking existed; *where* it happened is exercised by
`Test.Zak.Interpreter`'s own dedicated position-tracking tests instead,
not re-asserted here.
-}
runWithState : String -> Result I.Error ( Value, Runtime.State )
runWithState source =
    let
        ( env, state ) =
            I.initialWorld Dict.empty
    in
    I.runIncremental env state source |> Result.mapError dropRuntimePosition


{-| Runs each source in turn, the host setting the owner before each one
(`setThreadOwner`), as a host running scripts for different owners would.
-}
runAs : List ( String, String ) -> Result I.Error ( Value, Runtime.State )
runAs steps =
    let
        ( env, state0 ) =
            I.initialWorld Dict.empty
    in
    List.foldl
        (\( owner, source ) result ->
            Result.andThen (\( _, state ) -> I.runIncremental env (I.setThreadOwner owner state) source) result
        )
        (Ok ( VNil, state0 ))
        steps


{-| The owner of each waiting thread, by id.
-}
owners : Runtime.State -> List String
owners state =
    state.threads |> Dict.values |> List.map (\(Runtime.Thread thread) -> thread.owner)


dropRuntimePosition : I.Error -> I.Error
dropRuntimePosition error =
    case error of
        I.RuntimeError e ->
            I.RuntimeError (Runtime.dropPosition e)

        I.SyntaxError _ ->
            error


{-| Reads a `VTable`'s own `field` back out of `state.heap` directly —
used to check what a `start`-spawned body actually did *after*
being resumed by `tick`, since the top-level script's own return value
only reflects a snapshot taken before any tick ever ran.
-}
readTableField : Runtime.State -> Value -> String -> Maybe Value
readTableField state table field =
    case table of
        VTable id ->
            Dict.get id state.heap |> Maybe.andThen (Dict.get field)

        _ ->
            Nothing


suite : Test
suite =
    describe "Zak.Internal.Library.Thread (Thread.start/wait_for/join/stop/tick)"
        [ test "start runs its closure synchronously up to its first suspend, without blocking the caller" <|
            \_ ->
                -- `log.value` tables execution order: the spawned thread's
                -- body appends "A" then suspends on `wait_for`; only then
                -- does the *caller* (the top-level script) get to run its
                -- own next statement, appending "B" -- confirming
                -- `start` itself never blocks, and that the spawned
                -- body really did run immediately, not lazily.
                case
                    runWithState """let log = { value = "" }
Thread.start(function():
    log.value = log.value ++ "A"
    Thread.wait_for(1.0)
    log.value = log.value ++ "C"
end)
log.value = log.value ++ "B"
return log"""
                of
                    Ok ( result, state ) ->
                        Expect.equal (Just (VString "AB")) (readTableField state result "value")

                    Err err ->
                        Expect.fail ("expected success, got: " ++ Debug.toString err)
        , test "start's own result is always the new thread id, never Suspended" <|
            \_ ->
                case runWithState "return Thread.start(function(): Thread.wait_for(1.0) end)" of
                    Ok ( VNumber _, _ ) ->
                        Expect.pass

                    other ->
                        Expect.fail ("expected a thread id (VNumber), got: " ++ Debug.toString other)
        , test "a suspended thread is registered in state.threads until it finishes" <|
            \_ ->
                case runWithState "Thread.start(function(): Thread.wait_for(1.0) end)\nreturn nil" of
                    Ok ( _, state ) ->
                        Expect.equal 1 (Dict.size state.threads)

                    Err err ->
                        Expect.fail ("expected success, got: " ++ Debug.toString err)
        , test "a thread with nothing left to suspend on isn't registered at all" <|
            \_ ->
                case runWithState "Thread.start(function(): 1 + 1 end)\nreturn nil" of
                    Ok ( _, state ) ->
                        Expect.equal 0 (Dict.size state.threads)

                    Err err ->
                        Expect.fail ("expected success, got: " ++ Debug.toString err)
        , test "tick resumes a wait_for thread once enough seconds have elapsed, and not before" <|
            \_ ->
                case
                    runWithState """let log = { value = "" }
Thread.start(function():
    Thread.wait_for(1.0)
    log.value = log.value ++ "resumed"
end)
return log"""
                of
                    Err err ->
                        Expect.fail ("expected success, got: " ++ Debug.toString err)

                    Ok ( result, state0 ) ->
                        let
                            ( state1, _ ) =
                                tick 0.5 state0

                            stillWaiting =
                                readTableField state1 result "value"

                            ( state2, _ ) =
                                tick 0.6 state1

                            afterEnoughTime =
                                readTableField state2 result "value"
                        in
                        Expect.all
                            [ \_ -> Expect.equal (Just (VString "")) stillWaiting
                            , \_ -> Expect.equal (Just (VString "resumed")) afterEnoughTime
                            , \_ -> Expect.equal 0 (Dict.size state2.threads)
                            ]
                            ()
        , test "join suspends one thread until a second, independent thread finishes" <|
            \_ ->
                case
                    runWithState """let log = { value = "" }
let slow_id = Thread.start(function(): Thread.wait_for(1.0) end)
Thread.start(function():
    Thread.join(slow_id)
    log.value = log.value ++ "done"
end)
return log"""
                of
                    Err err ->
                        Expect.fail ("expected success, got: " ++ Debug.toString err)

                    Ok ( result, state0 ) ->
                        let
                            beforeSlowFinishes =
                                readTableField state0 result "value"

                            ( state1, _ ) =
                                tick 2.0 state0

                            afterSlowFinishes =
                                readTableField state1 result "value"
                        in
                        Expect.all
                            [ \_ -> Expect.equal (Just (VString "")) beforeSlowFinishes
                            , \_ -> Expect.equal (Just (VString "done")) afterSlowFinishes
                            , \_ -> Expect.equal 0 (Dict.size state1.threads)
                            ]
                            ()
        , test "wait_for as a bare statement inside a while loop suspends and resumes mid-iteration on later ticks, not restarting the loop from the top" <|
            \_ ->
                -- Traces through `execWhile`/`andThenOutcome` the same way
                -- a plain top-level `wait_for` does (see `tick`'s own doc),
                -- but this is the shape `breakwhile*` would actually need
                -- to be built from -- a poll loop, not a bare wait. Each
                -- tick should advance exactly one iteration: if the loop
                -- were wrongly restarting from n=0 on every resume, the
                -- log would read "111" instead of "123".
                case
                    runWithState """let log = { value = "" }
let counter = { n = 0 }
Thread.start(function():
    while counter.n < 3:
        counter.n = counter.n + 1
        log.value = log.value ++ String.from(counter.n)
        Thread.wait_for(1.0)
    end
    log.value = log.value ++ "done"
end)
return log"""
                of
                    Err err ->
                        Expect.fail ("expected success, got: " ++ Debug.toString err)

                    Ok ( result, state0 ) ->
                        let
                            afterStart =
                                readTableField state0 result "value"

                            ( state1, _ ) =
                                tick 1.0 state0

                            afterFirstTick =
                                readTableField state1 result "value"

                            ( state2, _ ) =
                                tick 1.0 state1

                            afterSecondTick =
                                readTableField state2 result "value"

                            ( state3, _ ) =
                                tick 1.0 state2

                            afterThirdTick =
                                readTableField state3 result "value"
                        in
                        Expect.all
                            [ \_ -> Expect.equal (Just (VString "1")) afterStart
                            , \_ -> Expect.equal (Just (VString "12")) afterFirstTick
                            , \_ -> Expect.equal (Just (VString "123")) afterSecondTick
                            , \_ -> Expect.equal (Just (VString "123done")) afterThirdTick
                            , \_ -> Expect.equal 0 (Dict.size state3.threads)
                            ]
                            ()
        , test "wait_for as a bare statement inside a for loop suspends and resumes mid-iteration the same way (not while-specific)" <|
            \_ ->
                case
                    runWithState """let log = { value = "" }
Thread.start(function():
    for n in [1, 2, 3]:
        log.value = log.value ++ String.from(n)
        Thread.wait_for(1.0)
    end
    log.value = log.value ++ "done"
end)
return log"""
                of
                    Err err ->
                        Expect.fail ("expected success, got: " ++ Debug.toString err)

                    Ok ( result, state0 ) ->
                        let
                            afterStart =
                                readTableField state0 result "value"

                            ( state1, _ ) =
                                tick 1.0 state0

                            ( state2, _ ) =
                                tick 1.0 state1

                            ( state3, _ ) =
                                tick 1.0 state2

                            afterThirdTick =
                                readTableField state3 result "value"
                        in
                        Expect.all
                            [ \_ -> Expect.equal (Just (VString "1")) afterStart
                            , \_ -> Expect.equal (Just (VString "123done")) afterThirdTick
                            , \_ -> Expect.equal 0 (Dict.size state3.threads)
                            ]
                            ()
        , test "wait_while(predicate) suspends inside its own separately-defined body (not inline in the spawned closure), resuming mid-loop each tick and only running the caller's own later statements once predicate finally returns false" <|
            \_ ->
                -- `wait_while` is itself a Zak-defined function, called as
                -- a bare statement -- the suspend happens several
                -- call-frames deep (inside `wait_while`'s own `while`
                -- loop), not inline in this closure the way the `while`/
                -- `for` tests above are. This is the shape that needed
                -- tracing through `callFunction`/`mapOutcome` before
                -- trusting it: log.value should read "123done" after
                -- exactly 3 ticks, same as the inline `while` case, not
                -- get stuck or skip iterations just because the loop now
                -- lives one call deeper.
                case
                    runWithState """let log = { value = "" }
let counter = { n = 0 }
Thread.start(function():
    Thread.wait_while(function():
        counter.n = counter.n + 1
        log.value = log.value ++ String.from(counter.n)
        return counter.n < 3
    end)
    log.value = log.value ++ "done"
end)
return log"""
                of
                    Err err ->
                        Expect.fail ("expected success, got: " ++ Debug.toString err)

                    Ok ( result, state0 ) ->
                        let
                            afterStart =
                                readTableField state0 result "value"

                            ( state1, _ ) =
                                tick 1.0 state0

                            ( state2, _ ) =
                                tick 1.0 state1

                            ( state3, _ ) =
                                tick 1.0 state2

                            afterThirdTick =
                                readTableField state3 result "value"
                        in
                        Expect.all
                            [ \_ -> Expect.equal (Just (VString "1")) afterStart
                            , \_ -> Expect.equal (Just (VString "123done")) afterThirdTick
                            , \_ -> Expect.equal 0 (Dict.size state3.threads)
                            ]
                            ()
        , test "wait_while's own argument-count/non-function checks come from ordinary Zak function-call handling, not a hand-written native check" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        case runWithState "Thread.start(function(): Thread.wait_while(1) end)\nreturn nil" of
                            Err (I.RuntimeError (NotAFunction (VNumber n))) ->
                                Expect.within (Expect.Absolute 0.0001) 1 n

                            other ->
                                Expect.fail ("expected NotAFunction, got: " ++ Debug.toString other)
                    , \_ ->
                        case runWithState "Thread.start(function(): Thread.wait_while() end)\nreturn nil" of
                            Err (I.RuntimeError (WrongArgCount { expected, got })) ->
                                Expect.equal ( 1, 0 ) ( expected, got )

                            other ->
                                Expect.fail ("expected WrongArgCount, got: " ++ Debug.toString other)
                    , \_ ->
                        case runWithState "Thread.start(function(): Thread.wait_while(function(): return false end, 1) end)\nreturn nil" of
                            Err (I.RuntimeError (WrongArgCount { expected, got })) ->
                                Expect.equal ( 1, 2 ) ( expected, got )

                            other ->
                                Expect.fail ("expected WrongArgCount, got: " ++ Debug.toString other)
                    ]
                    ()
        , test "wait_for called directly at the top level (not inside start) is a runtime error, not a silent suspend" <|
            \_ ->
                case runWithState "Thread.wait_for(1.0)\nreturn nil" of
                    Err (I.RuntimeError SuspendedNotAllowed) ->
                        Expect.pass

                    other ->
                        Expect.fail ("expected SuspendedNotAllowed, got: " ++ Debug.toString other)
        , test "wait_for called from a plain expression position (not a bare statement) is also SuspendedNotAllowed" <|
            \_ ->
                case runWithState "Thread.start(function(): let x = Thread.wait_for(1.0) end)\nreturn nil" of
                    Err (I.RuntimeError SuspendedNotAllowed) ->
                        Expect.pass

                    other ->
                        Expect.fail ("expected SuspendedNotAllowed, got: " ++ Debug.toString other)
        , test "stop drops a suspended thread, which never resumes even once its wait is over" <|
            \_ ->
                case
                    runWithState """let log = { value = "" }
let id = Thread.start(function():
    Thread.wait_for(1.0)
    log.value = "resumed"
end)
Thread.stop(id)
return log"""
                of
                    Err err ->
                        Expect.fail ("expected success, got: " ++ Debug.toString err)

                    Ok ( result, state0 ) ->
                        let
                            ( state1, _ ) =
                                tick 2.0 state0
                        in
                        Expect.all
                            [ \_ -> Expect.equal 0 (Dict.size state0.threads)
                            , \_ -> Expect.equal (Just (VString "")) (readTableField state1 result "value")
                            ]
                            ()
        , test "stop on a finished, already-stopped, or never-valid id is a no-op returning nil" <|
            \_ ->
                case
                    runWithState """let finished = Thread.start(function(): return nil end)
let waiting = Thread.start(function(): Thread.wait_for(1.0) end)
Thread.stop(waiting)
return Thread.stop(finished) == nil and Thread.stop(waiting) == nil and Thread.stop(999) == nil"""
                of
                    Ok ( result, state ) ->
                        Expect.all
                            [ \_ -> Expect.equal (VBool True) result
                            , \_ -> Expect.equal 0 (Dict.size state.threads)
                            ]
                            ()

                    Err err ->
                        Expect.fail ("expected success, got: " ++ Debug.toString err)
        , test "stop releases a thread joining on the stopped one" <|
            \_ ->
                case
                    runWithState """let log = { value = "" }
let slow = Thread.start(function(): Thread.wait_for(100.0) end)
Thread.start(function():
    Thread.join(slow)
    log.value = "released"
end)
Thread.stop(slow)
return log"""
                of
                    Err err ->
                        Expect.fail ("expected success, got: " ++ Debug.toString err)

                    Ok ( result, state0 ) ->
                        let
                            ( state1, _ ) =
                                tick 0.1 state0
                        in
                        Expect.all
                            [ \_ -> Expect.equal (Just (VString "released")) (readTableField state1 result "value")
                            , \_ -> Expect.equal 0 (Dict.size state1.threads)
                            ]
                            ()
        , test "a thread stopped by a lower-id thread in the same tick is neither resumed nor written back" <|
            \_ ->
                -- `tick` folds over the threads it started with, so both
                -- victims (ids above the stopper's) are still visited
                -- after the stopper removes them: `ready`'s wait is over
                -- (it would be resumed), `waiting`'s isn't (it would be
                -- re-inserted with its elapsed time bumped).
                case
                    runWithState """let log = { value = "" }
let victims = { ready = nil, waiting = nil }
Thread.start(function():
    Thread.wait_for(1.0)
    Thread.stop(victims.ready)
    Thread.stop(victims.waiting)
end)
victims.ready = Thread.start(function():
    Thread.wait_for(1.0)
    log.value = log.value ++ "ready ran"
end)
victims.waiting = Thread.start(function():
    Thread.wait_for(5.0)
    log.value = log.value ++ "waiting ran"
end)
return log"""
                of
                    Err err ->
                        Expect.fail ("expected success, got: " ++ Debug.toString err)

                    Ok ( result, state0 ) ->
                        let
                            ( state1, _ ) =
                                tick 1.0 state0

                            ( state2, _ ) =
                                tick 10.0 state1
                        in
                        Expect.all
                            [ \_ -> Expect.equal 0 (Dict.size state1.threads)
                            , \_ -> Expect.equal (Just (VString "")) (readTableField state2 result "value")
                            ]
                            ()
        , test "stop on the running thread itself is a no-op: it carries on and is re-registered at its next wait" <|
            \_ ->
                case
                    runWithState """let log = { value = "" }
let me = { id = nil }
me.id = Thread.start(function():
    Thread.wait_for(1.0)
    Thread.stop(me.id)
    log.value = log.value ++ "a"
    Thread.wait_for(1.0)
    log.value = log.value ++ "b"
end)
return log"""
                of
                    Err err ->
                        Expect.fail ("expected success, got: " ++ Debug.toString err)

                    Ok ( result, state0 ) ->
                        let
                            ( state1, _ ) =
                                tick 1.0 state0

                            ( state2, _ ) =
                                tick 1.0 state1
                        in
                        Expect.all
                            [ \_ -> Expect.equal (Just (VString "a")) (readTableField state1 result "value")
                            , \_ -> Expect.equal 1 (Dict.size state1.threads)
                            , \_ -> Expect.equal (Just (VString "ab")) (readTableField state2 result "value")
                            , \_ -> Expect.equal 0 (Dict.size state2.threads)
                            ]
                            ()
        , test "a child stopping the running thread that just started it is a no-op too" <|
            \_ ->
                case
                    runWithState """let log = { value = "" }
let parent = { id = nil }
parent.id = Thread.start(function():
    Thread.wait_for(1.0)
    Thread.start(function(): Thread.stop(parent.id) end)
    log.value = log.value ++ "a"
    Thread.wait_for(1.0)
    log.value = log.value ++ "b"
end)
return log"""
                of
                    Err err ->
                        Expect.fail ("expected success, got: " ++ Debug.toString err)

                    Ok ( result, state0 ) ->
                        let
                            ( state1, _ ) =
                                tick 1.0 state0

                            ( state2, _ ) =
                                tick 1.0 state1
                        in
                        Expect.all
                            [ \_ -> Expect.equal (Just (VString "a")) (readTableField state1 result "value")
                            , \_ -> Expect.equal (Just (VString "ab")) (readTableField state2 result "value")
                            , \_ -> Expect.equal 0 (Dict.size state2.threads)
                            ]
                            ()
        , test "stop's thread_id checks match join's" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        case runWithState "Thread.stop(\"x\")\nreturn nil" of
                            Err (I.RuntimeError (TypeError { expected })) ->
                                Expect.equal "Number" expected

                            other ->
                                Expect.fail ("expected TypeError, got: " ++ Debug.toString other)
                    , \_ ->
                        case runWithState "Thread.stop(1.5)\nreturn nil" of
                            Err (I.RuntimeError (NotAnInteger _)) ->
                                Expect.pass

                            other ->
                                Expect.fail ("expected NotAnInteger, got: " ++ Debug.toString other)
                    , \_ ->
                        case runWithState "Thread.stop()\nreturn nil" of
                            Err (I.RuntimeError (WrongArgCount { expected, got })) ->
                                Expect.equal ( 1, 0 ) ( expected, got )

                            other ->
                                Expect.fail ("expected WrongArgCount, got: " ++ Debug.toString other)
                    ]
                    ()
        , describe "owners (host-side thread control)" <|
            [ test "threadCount counts the threads waiting for tick, and drops back as they finish" <|
                \_ ->
                    case runWithState "Thread.start(function(): Thread.wait_for(1.0) end)\nThread.start(function(): Thread.wait_for(2.0) end)\nreturn nil" of
                        Ok ( _, state0 ) ->
                            let
                                ( state1, _ ) =
                                    tick 1.0 state0

                                ( state2, _ ) =
                                    tick 1.0 state1
                            in
                            [ I.threadCount state0, I.threadCount state1, I.threadCount state2 ]
                                |> Expect.equal [ 2, 1, 0 ]

                        Err err ->
                            Expect.fail ("expected success, got: " ++ Debug.toString err)
            , test "code outside any thread starts threads under the owner the host set, \"\" before it sets one" <|
                \_ ->
                    runAs
                        [ ( "", "Thread.start(function(): Thread.wait_for(1.0) end)" )
                        , ( "level", "Thread.start(function(): Thread.wait_for(1.0) end)" )
                        ]
                        |> Result.map (Tuple.second >> owners)
                        |> Expect.equal (Ok [ "", "level" ])
            , test "a thread started by a thread gets its owner, before its first wait and after one, whatever the host's owner is by then" <|
                \_ ->
                    case
                        runAs
                            [ ( "level"
                              , """Thread.start(function():
    Thread.start(function(): Thread.wait_for(5.0) end)
    Thread.wait_for(1.0)
    Thread.start(function(): Thread.wait_for(5.0) end)
    Thread.wait_for(5.0)
end)"""
                              )
                            , ( "other", "return nil" )
                            ]
                    of
                        Ok ( _, state0 ) ->
                            let
                                ( state1, _ ) =
                                    tick 1.0 state0
                            in
                            ( owners state1, state1.currentOwner )
                                |> Expect.equal ( [ "level", "level", "level" ], "other" )

                        Err err ->
                            Expect.fail ("expected success, got: " ++ Debug.toString err)
            , test "stopThreads stops an owner's threads, their descendants included, and keeps the other owners'" <|
                \_ ->
                    runAs
                        [ ( "level", "Thread.start(function():\n    Thread.start(function(): Thread.wait_for(1.0) end)\n    Thread.wait_for(1.0)\nend)" )
                        , ( "music", "Thread.start(function(): Thread.wait_for(1.0) end)" )
                        ]
                        |> Result.map (Tuple.second >> I.stopThreads "level" >> owners)
                        |> Expect.equal (Ok [ "music" ])
            , test "hasThreads tells whether an owner still has threads waiting" <|
                \_ ->
                    case runAs [ ( "level", "Thread.start(function(): Thread.wait_for(1.0) end)" ) ] of
                        Ok ( _, state0 ) ->
                            let
                                ( state1, _ ) =
                                    tick 1.0 state0
                            in
                            [ I.hasThreads "level" state0, I.hasThreads "music" state0, I.hasThreads "level" state1 ]
                                |> Expect.equal [ True, False, False ]

                        Err err ->
                            Expect.fail ("expected success, got: " ++ Debug.toString err)
            , test "startThread runs the function as a thread of the given owner, up to its first wait, and restores the host's owner" <|
                \_ ->
                    case runAs [ ( "level", "let log = { value = \"\" }\nreturn function():\n    log.value = \"started\"\n    Thread.start(function(): Thread.wait_for(5.0) end)\n    Thread.wait_for(1.0)\nend" ) ] of
                        Ok ( fn, state0 ) ->
                            I.startThread "cutscene" fn [] state0
                                |> Result.map (\( _, state1 ) -> ( owners state1, state1.currentOwner ))
                                |> Expect.equal (Ok ( [ "cutscene", "cutscene" ], "level" ))

                        Err err ->
                            Expect.fail ("expected success, got: " ++ Debug.toString err)
            , test "startThread with a body that never waits leaves no thread behind" <|
                \_ ->
                    case runWithState "return function(): return 1 end" of
                        Ok ( fn, state0 ) ->
                            I.startThread "cutscene" fn [] state0
                                |> Result.map (Tuple.second >> I.threadCount)
                                |> Expect.equal (Ok 0)

                        Err err ->
                            Expect.fail ("expected success, got: " ++ Debug.toString err)
            , test "startThread reports an error raised before the first wait" <|
                \_ ->
                    case runWithState "return function(): return missing end" of
                        Ok ( fn, state0 ) ->
                            I.startThread "cutscene" fn [] state0
                                |> Result.mapError dropRuntimePosition
                                |> Expect.equal (Err (I.RuntimeError (UndefinedName "missing")))

                        Err err ->
                            Expect.fail ("expected success, got: " ++ Debug.toString err)
            , test "called from a native, it stops the threads started before the call and keeps those started after it" <|
                \_ ->
                    let
                        leave =
                            NativeFunction (\state _ -> Ok ( VNil, I.stopThreads "" state ))

                        ( env, state0 ) =
                            I.initialWorld (Dict.singleton "leave" leave)
                    in
                    case I.runIncremental env state0 "Thread.start(function(): Thread.wait_for(1.0) end)\nleave()\nThread.start(function(): Thread.wait_for(1.0) end)\nreturn nil" of
                        Ok ( _, state ) ->
                            state.threads |> Dict.keys |> Expect.equal [ 1 ]

                        Err err ->
                            Expect.fail ("expected success, got: " ++ Debug.toString err)
            , test "the running thread that asks for it isn't stopped: it carries on past its next wait, like Thread.stop on itself" <|
                \_ ->
                    let
                        leave =
                            NativeFunction (\state _ -> Ok ( VNil, I.stopThreads "" state ))

                        ( env, state0 ) =
                            I.initialWorld (Dict.singleton "leave" leave)
                    in
                    case
                        I.runIncremental env
                            state0
                            """let log = { value = "" }
Thread.start(function():
    Thread.wait_for(5.0)
    log.value = log.value ++ "old room"
end)
Thread.start(function():
    Thread.wait_for(1.0)
    leave()
    log.value = log.value ++ "a"
    Thread.wait_for(1.0)
    log.value = log.value ++ "b"
end)
return log"""
                    of
                        Ok ( result, s0 ) ->
                            let
                                ( s1, _ ) =
                                    tick 1.0 s0

                                ( s2, _ ) =
                                    tick 10.0 s1
                            in
                            Expect.all
                                [ \_ -> Expect.equal (Just (VString "a")) (readTableField s1 result "value")
                                , \_ -> Expect.equal 1 (I.threadCount s1)
                                , \_ -> Expect.equal (Just (VString "ab")) (readTableField s2 result "value")
                                , \_ -> Expect.equal 0 (I.threadCount s2)
                                ]
                                ()

                        Err err ->
                            Expect.fail ("expected success, got: " ++ Debug.toString err)
            ]
        ]
