# Zak language reference

Zak is a small, imperative, dynamically-typed scripting language meant to be embedded in a host application, which exposes its own functions to scripts and drives them over time. Its main inspirations are Squirrel and Lua.

This reference has two parts: the language itself — its syntax, values, statements, and expressions — and the standard library, everything a Zak script can call without the host wiring anything up itself.

To run the examples as you read, paste them into [Try Zak](https://passiomatic.github.io/elm-zak/try/), a playground that runs Zak scripts right in the browser.

## The language

- [Lexical structure](language/Lexical.md) — identifiers, keywords, operators, literals, comments, and how lines and blocks are laid out
- [Values and data types](language/Values.md) — the seven types, equality, and values vs. references
- [Execution context](language/Execution.md) — variables, constants, scope, and runtime errors
- [Statements](language/Statements.md) — blocks, `if`, `while`, `for`, `break`, `continue`, `return`, and assignment
- [Expressions](language/Expressions.md) — operators, precedence, and array and table constructors
- [Tables](language/Tables.md) — named fields: reading, writing, going through them, and copying
- [Arrays](language/Arrays.md) — indexed elements: reading, writing, growing, looping, and transforming
- [Functions](language/Functions.md) — defining and calling functions, default parameters, closures, and recursion
- [Threads](language/Threads.md) — code that waits: starting, waiting, stopping, and how time moves forward

## Standard library functions

- [Array](stdlib/Array.md) — ordered, mutable collections that can grow and shrink
- [Debug](stdlib/Debug.md) — logging and assertions
- [Global functions](stdlib/Global.md) — `type`, called directly rather than through a table like `Math`
- [Math](stdlib/Math.md) — trigonometry, rounding, `pi`
- [Random](stdlib/Random.md) — random numbers, picks, and weighted coin flips
- [String](stdlib/String.md) — string inspection and formatting
- [Table](stdlib/Table.md) — named-field collections, callable spellings of `.field` access
- [Thread](stdlib/Thread.md) — cooperative background threads
