# Zak language reference

Zak is a small, dynamically-typed scripting language meant to be embedded in a host application, which exposes its own functions to scripts and drives them over time.

This is the built-in function reference: everything a Zak script can call without the host wiring anything up itself, grouped by namespace. Language basics — literals, operators, `if`/`while`/`for`, functions — will get their own pages here later; for now, this covers the standard library only.

## Standard library functions

- [Array](Array.md) — fixed-size, ordered, mutable collections
- [Debug](Debug.md) — logging and assertions
- [Global functions](Global.md) — `type`, not grouped under any namespace
- [Math](Math.md) — trigonometry, rounding, `pi`
- [Random](Random.md) — random numbers, picks, and weighted coin flips
- [String](String.md) — string inspection and formatting
- [Table](Table.md) — named-field collections, callable spellings of `.field` access
- [Thread](Thread.md) — cooperative background threads
