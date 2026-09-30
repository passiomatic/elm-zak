# Table

Named-field collections. A table is a reference, not a plain value, the same as an array. Dot syntax (`table.field`, `table.field = value`) already covers reading and writing a field for most cases — the functions below are a callable spelling of the same two operations, needed when the field name itself is a runtime value rather than a literal identifier.

`table` is always the first argument of every function below, the same as with [Array](Array.md).

## Table.get(table, name)

Value of the field named `name` (a `String`) on `table`. Errors if the field doesn't exist, same as reading `table.name` would.

```
let r = { x = 1 }
Table.get(r, "x")   # 1
```

## Table.get_default(table, name, default)

Like `Table.get`, but returns `default` instead of erroring if `name` isn't present.

```
let r = { x = 1 }
Table.get_default(r, "x", 0)   # 1
Table.get_default(r, "z", 0)   # 0 (no "z" field, so the default)
```

## Table.set(table, name, value)

Sets the field named `name` to `value`, creating it if it doesn't already exist. Returns `table` itself — the same table, not a copy.

```
let r = { x = 1 }
Table.set(r, "x", 99)   # r is now { x = 99 }
Table.set(r, "y", 2)    # r is now { x = 99, y = 2 }
```

## Table.contains(table, name)

True if `table` has a field named `name`. The only way to test for a field's presence without risking the error `get`/dot access would raise for a missing one.

```
let r = { x = 1 }
Table.contains(r, "x")   # true
Table.contains(r, "z")   # false
```

## Table.clone(table)

A new table with the same fields as `table` — a shallow copy, same semantics as `Array.clone`. Top-level fields are independent afterward, but a nested array/table inside is still the *same* one, shared by reference.

```
let r = { x = 1 }
let s = Table.clone(r)
Table.set(s, "x", 99)
r   # { x = 1 }, unaffected

let inner = { y = 1 }
let t = { nested = inner }
let u = Table.clone(t)
Table.set(Table.get(u, "nested"), "y", 99)
t   # { nested = { y = 99 } } — the nested table was shared, not copied
```

## Table.each(table, fn)

Calls `fn(name, value)` once per field, sorted by field name (not in the order the fields were added), for the side effect alone — discards whatever `fn` returns and never mutates `table`. An empty `table` is a no-op.