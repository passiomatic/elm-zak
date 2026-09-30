# Zak reference manual — sources

This is the public-facing Zak language reference: the "how do I use it" manual.

One markdown file per language chapter, in `language/` (`Lexical.md`, ...), and per standard library table, in `stdlib/` (`Array.md`, `Debug.md`, ...), built into static HTML by [mkdocs](https://www.mkdocs.org/):

```
make guide
```

reads everything in this folder and writes the site to `../build/guide` (gitignored, alongside every other Elm build output). Requires the project's Python virtualenv (`.venv`) to have `mkdocs` installed — `pip install -r requirements.txt` from the repository root sets that up.

Both the language and the standard library are fully covered.
