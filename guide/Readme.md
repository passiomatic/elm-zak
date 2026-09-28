# Zak reference manual — sources

This is the public-facing Zak language reference: the "how do I use it" manual.

One markdown file per namespace (`Array.md`, `Debug.md`, ...), built into static HTML by [mkdocs](https://www.mkdocs.org/):

```
make guide
```

reads everything in this folder and writes the site to `../build/guide` (gitignored, alongside every other Elm build output). Requires the project's Python virtualenv (`.venv`) to have `mkdocs` installed — `pip install -r requirements.txt` from the repository root sets that up.

Only `literals`/`syntax`/control-flow pages are still missing — everything the interpreter currently exposes as a built-in function is covered.
