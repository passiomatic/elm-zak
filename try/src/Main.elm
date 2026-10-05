port module Main exposing (main)

{-| Try Zak: a small in-browser playground for writing and running Zak
programs. A row of example buttons, a textarea for source, a "Run"
button, and the evaluated result (or error) at the bottom.

Build/run it via `npm run try` (`elm-watch hot`, per `try/elm-watch.json`)
and open `try/index.html` — **not** a plain `elm make ... --output=index.html`:
this module has a port (`logToConsole`, below), and Elm's own single-file
HTML output mode has no slot for a JS-side `app.ports.*.subscribe(...)`
call, so it needs a hand-authored HTML page plus an `elm-watch` target —
see `index.html` itself for the JS side of this port.
-}

import Browser
import Browser.Events
import Dict
import Html exposing (Html, button, div, pre, text, textarea)
import Html.Attributes exposing (placeholder, style, value)
import Html.Events exposing (onClick, onInput)
import Zak exposing (Effect(..), Error, LogLevel(..), Value(..), World)


{-| The one JS-facing effect this tool has: hand every `Log` taken
this call (`Zak.takeEffects`) to the real browser console, in the order
the script actually logged them.

**One port call carrying the whole ordered list, deliberately, not one
call per entry.** The first version of this used `Cmd.batch (List.map
logCmd entries)` — one `logToConsole` call per entry — and it looked
right until it was actually run in a real browser: the five messages
came back in *reverse* order every time, confirmed with Playwright's own
`page.on('console', ...)`, not assumed. `Cmd.batch` doesn't promise
same-order dispatch for independently-mapped port calls, and for a
logging feature specifically, message order *is* the point — so this
sends one list in one call instead, and the JS side (`index.html`)
iterates it in order itself, which is the only place an ordering
guarantee can actually be made to hold.

`level` is already the exact `console.*` method name to call
(`"log"`/`"debug"`/`"info"`/`"warn"`/`"error"` — see `consoleMethod`),
not a Zak-level name, so the JS side can stay a one-liner per entry:
`console[entry.level](entry.message)`. This is genuinely the *only* way a
`Log` ever becomes a real console call: a native can't produce a `Cmd`,
so it can only queue the line in the world, for the host to take.
-}
port logToConsole : List { level : String, message : String } -> Cmd msg


main : Program () Model Msg
main =
    Browser.element { init = init, update = update, view = view, subscriptions = subscriptions }


{-| `lastRunSource` is a separate field from `source`, not the same one
reused, because an error's source-line snippet (see `viewResult` below)
has to be rendered against whatever text actually produced it — editing
the textarea after a failed run must not silently reattribute the old
error to a since-changed line.
-}
type alias Model =
    { source : String
    , lastRunSource : String
    , result : Maybe (Result Error ( Value, World ))
    }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { source = helloWorldExample, lastRunSource = "", result = Nothing }, Cmd.none )


type Msg
    = ChangedSource String
    | ClickedRun
    | ClickedExample String
    | Tick Float


{-| Takes every `Log` queued in `world` since the last call and
hands them all to *one* `logToConsole` call, in order — `Cmd.none` if
none were queued (an empty list would be a harmless no-op port call
either way, but there's no reason to make one). Called from both
`ClickedRun` and `Tick` below, since either one could have run a
`Debug.log`/`Debug.log_debug`/`Debug.log_info`/`Debug.log_warning`/
`Debug.log_error` call (`ClickedRun` from the script's own top level,
`Tick` from a resumed thread's body).
-}
drainAndLog : World -> ( World, Cmd Msg )
drainAndLog world =
    let
        ( effects, world1 ) =
            Zak.takeEffects world

        entries =
            List.filterMap consoleEntry effects
    in
    ( world1
    , if List.isEmpty entries then
        Cmd.none

      else
        logToConsole entries
    )


{-| A `Log` as the record `logToConsole` sends. This tool has no host
natives of its own, so there's never an `Effect` to handle.
-}
consoleEntry : Effect -> Maybe { level : String, message : String }
consoleEntry effect =
    case effect of
        Log level message ->
            Just { level = consoleMethod level, message = message }

        Effect _ _ ->
            Nothing


{-| The browser `console` method for each `LogLevel`. Only `LogWarning`
differs from its Zak name: `console.warn`, not `console.warning`.
-}
consoleMethod : LogLevel -> String
consoleMethod level =
    case level of
        LogPrint ->
            "log"

        LogDebug ->
            "debug"

        LogInfo ->
            "info"

        LogWarning ->
            "warn"

        LogError ->
            "error"


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ChangedSource source ->
            ( { model | source = source }, Cmd.none )

        ClickedRun ->
            case Zak.run model.source (Zak.init []) of
                Ok ( _, world1 ) ->
                    -- A required main(): a missing one surfaces as an
                    -- ordinary UndefinedName "main" failure, not a
                    -- bespoke case of its own. "return main()", not a
                    -- bare "main()": this tool's whole job is showing
                    -- main()'s return value, so the synthesized program
                    -- needs its own explicit return to carry it out.
                    case Zak.run "return main()" world1 of
                        Ok ( value, world2 ) ->
                            let
                                ( world3, cmd ) =
                                    drainAndLog world2
                            in
                            ( { model | lastRunSource = model.source, result = Just (Ok ( value, world3 )) }, cmd )

                        (Err _) as result ->
                            ( { model | lastRunSource = model.source, result = Just result }, Cmd.none )

                (Err _) as result ->
                    -- A syntax/runtime error means nothing ran far enough
                    -- to have queued anything worth draining.
                    ( { model | lastRunSource = model.source, result = Just result }, Cmd.none )

        ClickedExample source ->
            -- Loads the example into the textarea without running it —
            -- "paste", not "run" — and clears any previous result, since
            -- it no longer corresponds to the source now showing.
            ( { model | source = source, result = Nothing }, Cmd.none )

        Tick deltaMs ->
            -- Advances every currently-suspended thread by one scheduler
            -- step (see `Zak.tick`'s own doc) -- `result`'s own `Value`
            -- (the top-level script's return value, captured the moment
            -- it returned) never changes here, only the `World`, so a
            -- resumed thread's effects only ever become visible through
            -- the world's threads and tables, rendered below by
            -- `viewThreads` -- or, for a `Debug.log`/`Debug.log_debug`/`Debug.log_info`/
            -- `Debug.log_warning`/`Debug.log_error` call
            -- made from inside a resumed thread body, drained here into a
            -- real console call the same way `ClickedRun` already does.
            -- Per-thread runtime errors from a bad resume are silently
            -- dropped for now, rather than surfacing a second, parallel
            -- error channel alongside `result`'s own.
            case model.result of
                Just (Ok ( value, world )) ->
                    let
                        ( _, world1 ) =
                            Zak.tick (deltaMs / 1000) world

                        ( world2, cmd ) =
                            drainAndLog world1
                    in
                    ( { model | result = Just (Ok ( value, world2 )) }, cmd )

                _ ->
                    ( model, Cmd.none )


{-| Only subscribes to animation frames while there's actually a thread to
advance — an empty/errored/not-yet-run result has nothing for `Tick` to
do, so there's no reason to keep the browser ticking this tool for
nothing.
-}
subscriptions : Model -> Sub Msg
subscriptions model =
    case model.result of
        Just (Ok ( _, world )) ->
            if Zak.threadCount world == 0 then
                Sub.none

            else
                Browser.Events.onAnimationFrameDelta Tick

        _ ->
            Sub.none


view : Model -> Html Msg
view model =
    div
        [ style "display" "flex"
        , style "flex-direction" "column"
        , style "height" "100vh"
        , style "font-family" "-apple-system, sans-serif"
        ]
        [ div
            [ style "flex" "4"
            , style "display" "flex"
            , style "flex-direction" "column"
            , style "padding" "12px"
            , style "min-height" "0"
            ]
            [ div
                [ style "display" "flex"
                , style "gap" "8px"
                , style "margin-bottom" "8px"
                ]
                (List.map exampleButton examples)
            , textarea
                [ value model.source
                , onInput ChangedSource
                , placeholder "let main = function():\n    let x = 1\n    return Math.abs(-x)\nend"
                , style "flex" "1"
                , style "font-family" "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
                , style "font-size" "14px"
                , style "resize" "none"
                , style "padding" "8px"
                ]
                []
            , button
                [ onClick ClickedRun
                , style "margin-top" "8px"
                , style "align-self" "flex-start"
                , style "padding" "8px 20px"
                , style "font-size" "14px"
                ]
                [ text "Run" ]
            ]
        , div
            [ style "flex" "1"
            , style "border-top" "2px solid #ccc"
            , style "padding" "12px"
            , style "overflow" "auto"
            , style "background" "#f6f8fa"
            , style "min-height" "0"
            ]
            [ pre
                [ style "margin" "0"
                , style "white-space" "pre-wrap"
                , style "font-family" "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
                , style "color"
                    (if isError model.result then
                        "#c00"

                     else
                        "inherit"
                    )
                ]
                [ text (viewResult model.lastRunSource model.result) ]
            , viewThreads model.result
            ]
        ]


{-| "N threads still running" while any thread is waiting — the one
place this tool makes the scheduler itself observable. Nothing to show once every thread
has finished (or none were ever spawned), matching `subscriptions`'s own
"nothing to advance" check.
-}
viewThreads : Maybe (Result Error ( Value, World )) -> Html Msg
viewThreads result =
    case result of
        Just (Ok ( _, world )) ->
            let
                count =
                    Zak.threadCount world
            in
            if count == 0 then
                text ""

            else
                div
                    [ style "margin-top" "8px"
                    , style "font-size" "13px"
                    , style "color" "#666"
                    ]
                    [ text
                        (String.fromInt count
                            ++ (if count == 1 then
                                    " thread still running…"

                                else
                                    " threads still running…"
                               )
                        )
                    ]

        _ ->
            text ""


exampleButton : ( String, String ) -> Html Msg
exampleButton ( label, source ) =
    button
        [ onClick (ClickedExample source)
        , style "padding" "6px 12px"
        , style "font-size" "13px"
        , style "background" "#eee"
        , style "border" "1px solid #ccc"
        , style "border-radius" "4px"
        , style "cursor" "pointer"
        ]
        [ text label ]



-- EXAMPLES


examples : List ( String, String )
examples =
    [ ( "Hello, world!", helloWorldExample )
    , ( "Fibonacci", fibonacciExample )
    , ( "Double an array", doubleArrayExample )
    , ( "Actor table", actorTableExample )
    , ( "Background thread", threadingExample )
    , ( "String.format", stringFormatExample )
    , ( "Logging", loggingExample )
    ]


helloWorldExample : String
helloWorldExample =
    """# The classic hello world — every script needs a main(), and its
# returned value is shown below
let main = function():
    return "Hello, world!"
end
"""


fibonacciExample : String
fibonacciExample =
    """# Recursive fibonacci — fib calls itself; main() returns the final call's value
let fib = function(n):
    if n < 2:
        return n
    end
    return fib(n - 1) + fib(n - 2)
end

let main = function():
    return fib(10)
end"""


doubleArrayExample : String
doubleArrayExample =
    """# Doubles every element of an array via Array.map
let double = function(x):
    return x * 2
end

let main = function():
    let numbers = [1, 2, 3, 4, 5]
    return Array.map(numbers, double)
end"""


actorTableExample : String
actorTableExample =
    """# A game actor table, created then updated
let main = function():
    let actor = {
        name = "Taylor",
        health = 100,
        position = { x = 0, y = 0 }
    }

    actor.health = actor.health - 25
    actor.position.x = 10

    return actor
end"""


threadingExample : String
threadingExample =
    """# Thread.start spawns a background thread -- its body runs
# immediately up to its own first wait_for, then the *caller*
# keeps going right away, without waiting. Click Run, then watch "threads
# still running…" below count down as the scheduler resumes it, once per
# second.
let main = function():
    let log = { value = "" }

    Thread.start(function():
        log.value = log.value ++ "A"
        Thread.wait_for(1.0)
        log.value = log.value ++ "B"
        Thread.wait_for(1.0)
        log.value = log.value ++ "C"
    end)

    # this runs immediately -- start never blocks its caller
    return log
end"""


stringFormatExample : String
stringFormatExample =
    """# String.format substitutes %s/%d/%f/%% in order from an Array of args
let main = function():
    let shots = 3.9
    return String.format("%d apples, %s left, that's %f%%!", [shots, "some", 100])
end"""


loggingExample : String
loggingExample =
    """# Debug.log/log_debug/log_info/log_warning/log_error all reach the real
# browser console (open DevTools to see these) -- each maps to
# console.log/debug/info/warn/error respectively, so the console's own
# filtering and coloring apply automatically, no UI of our own needed for
# that. Note: most browsers hide console.debug behind a "Verbose" filter
# by default.
let main = function():
    Debug.log("a plain message")
    Debug.log_debug("only visible with the console's Verbose filter enabled")
    Debug.log_info("an informational message")
    Debug.log_warning("something worth a second look")
    Debug.log_error("something actually wrong")

    return "check the browser console"
end
"""



-- RENDERING THE RESULT


{-| Recursively renders `value`'s actual contents, read from `world`.
A `Table`/`Array` is only a reference on its own, so `Debug.toString`
would never show `[2, 4, 6, 8, 10]`. Rendering it needs the `World` it
was produced in, which is why `ClickedRun` keeps the world `Zak.run`
gives back.

Cycle-guarded via `seen` — the tables and arrays currently being rendered
on the path from the root, not "ever seen anywhere" (so `[a, a]`, the
same table twice but not circular, still renders both) — because a
genuinely self-referential array (`Array.push(a, a)`) is completely legal
Zak, and this tool lets you type anything. Two references are `==`
exactly when they're the same table or array. Zak's own `String.from`
sidesteps this by not recursing into `Array`/`Table` at all; this tool can
afford to recurse, since it's for interactive exploration.
-}
renderValue : World -> List Value -> Value -> String
renderValue world seen value =
    case value of
        String s ->
            "\"" ++ s ++ "\""

        Number n ->
            String.fromFloat n

        Bool True ->
            "true"

        Bool False ->
            "false"

        Nil ->
            "nil"

        Array _ ->
            if List.member value seen then
                "<cycle>"

            else
                Zak.items value world
                    |> Maybe.withDefault []
                    |> List.map (renderValue world (value :: seen))
                    |> String.join ", "
                    |> (\inner -> "[" ++ inner ++ "]")

        Table _ ->
            if List.member value seen then
                "<cycle>"

            else
                Zak.fields value world
                    |> Maybe.withDefault Dict.empty
                    |> Dict.toList
                    |> List.map (\( name, fieldValue ) -> name ++ " = " ++ renderValue world (value :: seen) fieldValue)
                    |> String.join ", "
                    |> (\inner -> "{ " ++ inner ++ " }")

        Function _ ->
            "<function>"


{-| `source` is the script that actually produced `maybeResult` (see
`Model`'s own doc for why that's a separate field from whatever's
currently in the textarea) — needed here only to print the offending
line an error points at.
-}
viewResult : String -> Maybe (Result Error ( Value, World )) -> String
viewResult source maybeResult =
    case maybeResult of
        Nothing ->
            "(not run yet)"

        Just (Ok ( value, world )) ->
            renderValue world [] value

        Just (Err error) ->
            Zak.errorToString source error


isError : Maybe (Result Error ( Value, World )) -> Bool
isError maybeResult =
    case maybeResult of
        Just (Err _) ->
            True

        _ ->
            False
