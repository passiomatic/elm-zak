# Debug

Logging and assertions — things a script does purely to help whoever's writing or debugging it, never anything the script's own logic depends on.

## Debug.log(value, ...)

Logs `value` at the ordinary level. Where the log appears is up to the host.

`value` can be of any type, and is shown the same way [`String.from`](String.md) would show it: a string as-is, a number or bool as its usual text, and an array, table, or function as a fixed placeholder (`<array>`, `<table>`, `<function>`), not its contents.

```
Debug.log("Hi there!")   # Hi there!
Debug.log(42)            # 42
Debug.log(nil)           # nil
Debug.log([1, 2])        # <array>
```

With more arguments, `value` must be a `String`: a format whose placeholders are filled from the arguments after it, in order. The placeholders and their rules are the same as [`String.format`](String.md)'s, which takes its values as one array instead. The number of values must match the placeholders exactly. An array is one value here, not a list of them: it fills a single placeholder.

```
Debug.log("Got %s instead of %s", "foo", "bar")   # Got foo instead of bar
Debug.log("%d%% done", 50)                        # 50% done
Debug.log("%s", "a", "b")                         # error: too many values
```

A `value` on its own is never a format, so its `%` signs are logged as written.

```
Debug.log("100% done")   # 100% done
```

## Debug.log_debug(value, ...)

Same as `log`, at the debug level. Hosts often hide debug messages unless asked to show them.

```
Debug.log_debug("only visible when the host shows debug messages")
```

## Debug.log_info(value, ...)

Same as `log`, at the informational level.

```
Debug.log_info("an informational message")
```

## Debug.log_warning(value, ...)

Same as `log`, at the warning level.

```
Debug.log_warning("something worth a second look")
Debug.log_warning("%s has no default verb", "door")
```

## Debug.log_error(value, ...)

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
