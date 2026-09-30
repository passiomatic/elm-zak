# Debug

Logging and assertions — things a script does purely to help whoever's writing or debugging it, never anything the script's own logic depends on.

## Debug.log(value)

Logs `value` (a `String`) at the ordinary level. Where the log appears is up to the host.

```
Debug.log("Hi there!")
```

## Debug.log_debug(value)

Same as `log`, at the debug level. Hosts often hide debug messages unless asked to show them.

```
Debug.log_debug("only visible when the host shows debug messages")
```

## Debug.log_info(value)

Same as `log`, at the informational level.

```
Debug.log_info("an informational message")
```

## Debug.log_warning(value)

Same as `log`, at the warning level.

```
Debug.log_warning("something worth a second look")
```

## Debug.log_error(value)

Same as `log`, at the error level.

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
