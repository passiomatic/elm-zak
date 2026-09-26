# Zak Language (VS Code extension)

Syntax highlighting for `.zak` files, based on `design/Zak Language Implementation.md`.

## Try it locally

1. Open this folder (`tools/vscode-zak-language`) in VS Code as its own window, or run:
   ```
   code --extensionDevelopmentPath="$(pwd)" --new-window "../../design/Bank.zak"
   ```
2. This launches an Extension Development Host window with the grammar active — open any `.zak` file there to see highlighting.

## Install into your regular VS Code

Symlink (or copy) this folder into your extensions directory, then reload VS Code:

```
ln -s "$(pwd)" ~/.vscode/extensions/zak-language-0.2.0
```

## What's covered

- `#` line comments
- double-quoted strings with `\` escapes (single-quoted strings were dropped from the language)
- numbers
- `true` / `false` / `nil`
- keywords: `let`, `const`, `function`, `if`, `else`, `end`, `while`, `for`, `in`, `break`, `continue`, `return`, `and`, `or`, `not`
- operators: `== != > < >= <= in + - * / // ++ =` (`in` doubles as both a `for`-loop keyword and a comparison-tier membership operator — highlighted the same either way, since a regex grammar can't tell the two roles apart by position)
- capitalized namespace access (`Array.push`, `Reach.high`, ...)
- function calls vs. plain identifiers vs. `.property` access

This is a TextMate grammar (regex-based), not a real parser — it doesn't track nesting depth semantically, so it can't fully distinguish a `function`'s closing `end` from an `if`'s. Both just highlight as the same `keyword.control.zak` token, which is enough for coloring but not for things like bracket-matching folding.
