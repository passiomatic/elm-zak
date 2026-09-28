# Debug

Logging and assertions — things a script does purely to help whoever's writing or debugging it, never anything the script's own logic depends on.

## Debug.log(value)

Logs `value` (a `String`) at the ordinary severity, equivalent to the browser's own `console.log`.

```
Debug.log("Hi there!")
```

## Debug.log_debug(value)

Same as `log`, at debug severity (`console.debug`). Most browsers hide this behind DevTools' "Verbose" filter by default.

```
Debug.log_debug("only visible with the console's Verbose filter enabled")
```

## Debug.log_info(value)

Same as `log`, at informational severity (`console.info`).

```
Debug.log_info("an informational message")
```

## Debug.log_warning(value)

Same as `log`, at warning severity (`console.warn`).

```
Debug.log_warning("something worth a second look")
```

## Debug.log_error(value)

Same as `log`, at error severity (`console.error`).

```
Debug.log_error("something actually wrong")
```

## Debug.assert(expr, message)

Checks that `expr` is `true`. If it's `false`, halts the script with a runtime error carrying `message`. `expr` must be a real `Bool`; `message`, when given, must be a `String`.

`message` is optional — omitting it halts with the default message `"assertion failed"`.

```
Debug.assert(1 + 1 == 2, "arithmetic is broken")   # passes silently
Debug.assert(false, "this halts the script")       # error: "this halts the script"
Debug.assert(false)                                # error: "assertion failed"
```
