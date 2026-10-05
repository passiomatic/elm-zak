# Zak errors

The open questions about errors in the public `Zak` module, left over from the errors pass (2026-10-05). The package docs in `src/Zak.elm` describe what's implemented. The full proposal and the reasons behind it are in this file's git history.

## `errorToString` can show the wrong line

The host passes the source in, but a position doesn't know which file it belongs to. This gives the wrong line in two cases:

- an error inside an included file;
- an error inside a function that an earlier `run` defined.

Either way, the error shows a line from whatever source was passed. Thread errors pass `""`, so they show no line at all.

Fixing this means giving positions their file:

- the parser tags each position with its file;
- the world remembers each file's source;
- `run` takes a file name.

`errorToString` would then no longer need a source argument. Both `run` and `errorToString` change signature, so this has to be decided before the package is published, or wait for a major release.

## A native that calls back into Zak loses the callback's position

Natives return a `Problem`, which has no position. A native that calls a script function with `Zak.call` gets an `Error` back, and can only pass on `errorProblem error`. The position inside the callback is lost, and only the position of the native's own call is added. The game has no such native, but a host with callbacks would, for example an `each(table, fn)`.
