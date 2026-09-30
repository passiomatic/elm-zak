# Tables

A table is a collection of named fields. Each field has a name, which is a string, and a value, which can be of any type — including another table, an array, or a function.

Tables are the way to group related values together: an actor's state, a room's description, a set of settings.

```
let player = {
    name = "Taylor",
    health = 100,
    position = { x = 0, y = 0 },
    inventory = ["lamp"]
}
```

## Construction

A table is built with braces, listing its fields as `name = value`, separated by commas. `{}` builds an empty table. See [Table constructor](Expressions.md#table-constructor) for the full rules.

Every constructor builds a new table, separate from every other.

## Reading fields

A field is read with `.` followed by its name:

```
player.name         # "Taylor"
player.position.x   # 0
```

Reading a field the table doesn't have is a runtime error, as is using `.` on anything that isn't a table:

```
player.mana          # error: there is no field named “mana”
player.name.length   # error: player.name is a String, not a table
```

To read a field that might be missing, check for it first with `in`, or read it with a fallback value using `Table.get_default`:

```
if "mana" in player:
    player.mana = player.mana - 5
end

let mana = Table.get_default(player, "mana", 0)
```

## Writing fields

A field is written with an assignment. If the table doesn't have that field yet, the assignment creates it:

```
player.health = 90     # changes an existing field
player.mana = 50       # adds a new field
```

Field steps can be chained, but only the last one can create a field — every table along the way must already exist:

```
player.position.x = 5   # fine: player.position is a table
player.stats.level = 2  # error: there is no field named “stats”
```

There's no way to remove a field. Setting a field to `nil` keeps it in the table, with `nil` as its value, so `in` still finds it.

## Field names known at runtime

`.` only takes a name written directly in the code. When the name is itself a value — read from a variable, or built at runtime — use the `Table` functions instead:

```
let stat = "health"
Table.get(player, stat)          # same as player.health
Table.set(player, stat, 100)     # same as player.health = 100
Table.contains(player, stat)     # same as "health" in player
```

`[ ]` never works on tables: it only indexes arrays.

`Table.set` accepts any string as a field name, including ones that aren't valid identifiers, like `"my key"`. Such a field can only ever be read back with `Table.get`, not with `.`.

## Going through all fields

`Table.each` calls a function once for every field, passing it the field's name and value:

```
Table.each(player, function(name, value):
    Debug.log(name)
end)
```

Fields are visited sorted by name, not in the order they were added. The sort is character by character, so uppercase names come before lowercase ones.

`for` only works on arrays, not tables.

## Functions in tables

A field can hold a function, and calling it looks like calling any other function:

```
let greeter = {
    greet = function(name):
        return "Hi, " ++ name
    end
}

greeter.greet("Taylor")   # "Hi, Taylor"
```

A function stored in a table doesn't automatically know which table it came from: `greeter.greet(x)` calls `greet` with `x` and nothing else. When the function needs the table, pass it in explicitly, conventionally as a first parameter named `self`:

```
let door = {
    locked? = true,
    unlock = function(self):
        self.locked? = false
    end
}

door.unlock(door)
```

This is the same pattern the standard library follows: `Math`, `Array`, `String`, and the rest are plain tables whose fields are functions, and each function takes the value it works on as its first argument — `Array.push(items, "key")`.

## Tables are references

Assigning a table to a variable, storing it in another table, or passing it to a function never copies it: every name refers to the same table, and a change through one is visible through all of them. See [Values and references](Values.md#values-and-references).

For the same reason, two tables are only `==` when they're the same table — two tables with the same fields are still different tables.

`Table.clone` makes a new table with the same fields. The copy is shallow: a table or array stored inside the original is shared with the copy, not duplicated.

```
let original = { stats = { level = 1 } }
let copy = Table.clone(original)

copy.stats.level = 2
original.stats.level   # 2 — both share the same stats table
```

See the [Table](../stdlib/Table.md) page for every function that works on tables.
