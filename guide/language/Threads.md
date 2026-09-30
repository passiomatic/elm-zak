# Threads

Everything a script does normally runs to completion straight away: a function call returns before the next statement starts. A thread is how a script does something that takes time — play out a scene step by step, blink a light every half second, wait for a door to open — without holding everything else up.

A thread runs a function that can pause partway through, and resume later exactly where it left off, with all its variables intact.

```
Thread.start(function():
    Debug.log("Knock knock.")
    Thread.wait_for(2.0)
    Debug.log("Who's there?")
end)

Debug.log("This runs right away.")
```

## How threads run

Zak threads are cooperative: only one piece of code runs at any moment, and a thread keeps running until it reaches a wait of its own accord. Nothing ever interrupts a thread partway through a statement, so two threads never step on each other's changes mid-way.

Time moves forward in ticks. The host advances time regularly — typically once per frame — telling Zak how many seconds have passed since the last tick. On every tick, each waiting thread whose wait is over resumes, and runs until its next wait, or until it finishes. Threads resume in the order they were started.

A thread resumes at most once per tick. Each wait counts its time from the moment it begins, so two `Thread.wait_for(1.0)` in a row always take at least two ticks, however long a tick is.

## Starting a thread

`Thread.start` takes a function with no parameters, and runs it as a new thread:

```
let blinker = Thread.start(function():
    while true:
        Debug.log("blink")
        Thread.wait_for(0.5)
    end
end)
```

The function starts running immediately, as part of the `Thread.start` call, and carries on until its first wait. Only then does `Thread.start` return, and the caller continue with its next statement. A thread that never waits runs all the way through before `Thread.start` returns.

`Thread.start` returns the new thread's id, a number, used to refer to the thread later with `Thread.join` and `Thread.stop`. Whatever the thread's function returns is discarded.

A thread can start other threads, and a thread can share state with the rest of the script through closures, like any other function — see [Closures](Functions.md#closures).

`Thread.start_global` works the same as `Thread.start`, and is reserved for a future distinction between kinds of threads.

## Waiting

A thread pauses by calling one of the waiting functions:

| Function                         | Resumes the thread when…                          |
| -------------------------------- | ------------------------------------------------- |
| `Thread.wait_for(seconds)`       | at least `seconds` have passed                    |
| `Thread.join(thread_id)`         | the thread `thread_id` has finished or stopped    |
| `Thread.wait_while(predicate)`   | calling `predicate()` returns `false`             |

`Thread.wait_while` calls its function once per tick, so the condition is checked afresh each time. Pass a function, not the condition itself: `Thread.wait_while(function(): return not door.open end)`, not `Thread.wait_while(not door.open)`.

```
let door = { open = false }

Thread.start(function():
    Thread.wait_while(function(): return not door.open end)
    Debug.log("Finally!")
end)
```

## Where a thread can wait

A waiting function can only be called inside a thread, and only as a statement on its own — not as part of an expression:

```
Thread.start(function():
    Thread.wait_for(1.0)                  # fine

    if ready?:
        Thread.wait_for(1.0)              # fine: inside if, while, and for too
    end

    let x = Thread.wait_for(1.0)          # error
    return Thread.wait_for(1.0)           # error
end)
```

A function called from a thread can wait too, as long as the call to it is itself a statement on its own:

```
let pause = function(seconds):
    Thread.wait_for(seconds)
end

Thread.start(function():
    pause(1.0)            # fine
    let x = pause(1.0)    # error
end)
```

A function passed to another function to call back — to `Array.each`, `Array.map`, `Table.each`, and so on — can never wait, since those calls can't be paused halfway.

Waiting anywhere else, including outside every thread, is a runtime error:

```
a waiting call must be a statement on its own, inside a thread
```

## Stopping a thread

A thread ends when its function returns, or reaches its `end`.

`Thread.stop(thread_id)` ends another thread while it's waiting: it never resumes, and any thread joining it carries on. Stopping a thread that has already finished does nothing.

```
Thread.start(function():
    Thread.wait_for(3.0)
    Thread.stop(blinker)   # no more blinks
end)
```

A thread can't stop itself with `Thread.stop`. To end itself, it returns.

## Errors in threads

A runtime error inside a thread ends that thread. When it happens depends on where the error is:

- before the thread's first wait, the error happens during the `Thread.start` call, so it stops the code that called `Thread.start` too, like any other error
- after the thread has waited at least once, only that thread ends; the error is reported to the host, and every other thread keeps running

See the [Thread](../stdlib/Thread.md) page for the full details of every thread function.
