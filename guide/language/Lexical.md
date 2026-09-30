# Lexical structure

How Zak source text is split into the pieces the language is built from: names, keywords, operators, literals, and comments — and how those pieces are arranged into lines.

## Identifiers

An identifier names a variable, a function parameter, or a table field. It starts with a letter or `_`, continues with letters, digits, or `_`, and may end with a single `?`. Identifiers are case-sensitive, and letters are ASCII only.

```
health
player_2
_sound_id
ready?
```

Two naming conventions are common, but nothing in the language checks or enforces them:

- a trailing `?` marks a name that holds, or a function that returns, a `Bool` — `ready?`, `is_open?`
- a leading `_` marks a "semi-private" name, meant for internal use only — `_sound_id`

`?` is only allowed as the very last character, so `a?b` is not one identifier. `!` is never part of an identifier: `done!=x` reads as `done != x`.

## Keywords

These words are reserved by the language and can't be used as identifiers:

```
and       const     else      end       for
function  if        in        let       not
or        return    while     break     continue
```

A keyword followed by `?` is an ordinary identifier, so `end?` is a valid name.

`true`, `false`, and `nil` are not keywords: they're predefined constants, always available in every script. Like any other constant, they can't be reassigned.

## Operators

| Operator                        | Meaning                              |
| ------------------------------- | ------------------------------------ |
| `+` `-` `*` `/`                 | arithmetic                           |
| `//`                            | floor division                       |
| `-` (prefix)                    | negation                             |
| `++`                            | string concatenation                 |
| `==` `!=`                       | equality                             |
| `<` `<=` `>` `>=`               | ordering                             |
| `in`                            | membership in an array or table      |
| `and` `or` `not`                | logical operators                    |
| `=`                             | assignment                           |

When one operator is a prefix of another, the longer one always wins: `++` is concatenation, never two `+`; `//` is floor division, never two `/`.

## Other tokens

| Token   | Used for                                                          |
| ------- | ----------------------------------------------------------------- |
| `( )`   | grouping an expression, calling a function, a function's parameter list |
| `[ ]`   | an array literal, indexing an array                               |
| `{ }`   | a table literal                                                   |
| `.`     | reading or writing a table field                                  |
| `,`     | separating array elements, table fields, arguments, and parameters |
| `:`     | opening a block, after `if`, `else`, `while`, `for`, and `function(...)` |

A trailing comma after the last item is a syntax error, in every position: `[1, 2,]`, `{ x = 1, }`, `f(a,)`.

## Literals

### Numbers

A number literal is one or more digits, optionally followed by `.` and one or more digits:

```
0
42
3.14
```

Both sides of the `.` are required, so `.5` and `5.` are syntax errors. A literal never carries a sign: `-1` is the negation operator applied to `1`.

### Strings

A string literal is enclosed in double quotes:

```
"Hello, world"
""
```

Inside a string, `\` starts an escape, and only two escapes exist:

| Escape | Produces |
| ------ | -------- |
| `\"`   | `"`      |
| `\\`   | `\`      |

Any other character after `\` is a syntax error — there is no `\n` or `\t`. A string may span several lines instead, and the line breaks become part of its value:

```
let message = "first line
second line"
```

`'` has no special meaning: it's an ordinary character, inside or outside a string (`"it's"`).

## Comments

A comment starts with `#` and runs to the end of the line. It can take a whole line, or follow code on the same line:

```
# restore full health
player.health = 100   # the maximum
```

There are no block comments.

## Lines and blocks

A newline ends a statement. There are no semicolons, and two statements can't share a line:

```
let x = 1
let y = 2        # fine

let x = 1 let y = 2   # syntax error
```

Blank lines, indentation, and comment-only lines between statements are ignored. Indentation is a matter of style only: blocks are delimited by `:` and `end`, never by how far lines are indented.

```
if player.health <= 0:
    Debug.log("game over")
end
```

A statement can continue on the next line only right after an opening `(`, `[`, or `{`, right before the matching closing one, and around the commas between items. That's enough to spread an argument list, an array, or a table across several lines:

```
let actor = {
    name = "Taylor",
    health = 100
}

Array.push(
    inventory,
    "key"
)
```

Anywhere else — in particular, before or after an operator — a newline ends the statement, so an expression like `a + b` can't be split across lines, not even inside parentheses. Break a long expression up with intermediate variables instead:

```
let bonus = bonus_damage - armor
let total = base_damage + bonus
```
