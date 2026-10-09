# Thread

Cooperative background threads. Everything else in the language runs to completion the moment it's called — `Thread` is how a script spawns an independent thread that can pause itself (for a fixed amount of time, or until another thread finishes) and resume later, exactly where it left off.

The waiting functions — `wait_for`, `join`, and `wait_while` — only work inside a thread, called as a statement on its own. See [Where a thread can wait](../language/Threads.md#where-a-thread-can-wait).

## Thread.start(closure)

Spawns `closure` (called with no arguments) as an independent thread. Returns the new thread's id (a `Number`) immediately — never blocks the caller, no matter what `closure` goes on to do. `closure`'s own body runs immediately, synchronously, up to its own first suspend point (or all the way to completion, if it never suspends).

```
let log = { value = "" }

let worker_id = Thread.start(function():
    log.value = log.value ++ "A"   # runs immediately, as part of start's own call
    Thread.wait_for(1.0)           # suspends this thread for 1 second
    log.value = log.value ++ "B"   # runs once a later tick resumes it
end)

log.value = log.value ++ "C"       # runs right away — start never blocks its caller
```

The new thread belongs to whatever the code calling `start` belongs to, so the threads a thread starts share its fate: the program that runs your scripts can stop a thread and every thread it started in one go. See [Threads](../language/Threads.md).

## Thread.wait_for(seconds)

Suspends the calling thread until at least `seconds` of elapsed tick time have passed. `seconds` may be fractional.

```
Thread.start(function():
    Thread.wait_for(0.5)
end)
```

## Thread.join(thread_id)

Suspends the calling thread until the thread named by `thread_id` (an id previously returned by `start`) is no longer running. An unknown or already-finished `thread_id` isn't an error — the call resolves immediately.

```
let worker_id = Thread.start(function():
    Thread.wait_for(1.0)
end)

Thread.start(function():
    Thread.join(worker_id)
    # runs only once worker_id has finished
end)
```

## Thread.stop(thread_id)

Ends the thread named by `thread_id` while it's waiting. It never resumes, even once its wait would have been over, and it can't be restarted; any thread `join`ing on it carries on. Returns `nil`. An unknown, already-finished, or already-stopped `thread_id` isn't an error — the call does nothing.

Only a waiting thread can be stopped: calling `stop` on the thread that's currently running (the caller itself, or the thread that started it) has no effect. To end itself, a thread returns from its function.

```
let blink_id = Thread.start(function():
    while true:
        Debug.log("blink")
        Thread.wait_for(0.5)
    end
end)

Thread.start(function():
    Thread.wait_for(3.0)
    Thread.stop(blink_id)   # no more blinks after this
end)
```

## Thread.wait_while(predicate)

Suspends the calling thread, calling `predicate()` (no arguments) once per tick, until it returns `false`. Use it to wait on any condition, not just elapsed time or another thread — pass a function, not the condition's current value, so it's re-checked fresh each tick rather than frozen at whatever it was when `wait_while` was called.

```
let door = { open = false }

Thread.start(function():
    Thread.wait_while(function(): return not door.open end)
    Debug.log("Finally!")   # only once door.open becomes true
end)

Thread.start(function():
    Thread.wait_for(3.0)
    door.open = true
end)
```
