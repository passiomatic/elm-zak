# Zak

Zak (after [Zak McKracken][z]) is a small, dynamically-typed scripting language meant to be embedded in an Elm host application, which exposes its own functions to scripts and drives them over time.

```
let main = function():
    let log = { value = "" }

    Thread.start(function():
        log.value = log.value ++ "A"
        Thread.wait_for(1.0)
        log.value = log.value ++ "B"
        Thread.wait_for(1.0)
        log.value = log.value ++ "C"
    end)

    # this runs immediately -- start never blocks its caller
    return log
end
```

## Try Zak

```
make reactor
```

## Documentation

The Zak guide — the language reference and the standard library — is published at <https://passiomatic.github.io/elm-zak/>. It's rebuilt automatically on every push to `main` that changes it.

## Build the documentation

The project uses [mkdocs][m] to convert the Markdown files into browsable HTML pages.

To rebuild the docs, first create a Python virtual env and install all the required mkdocs dependencies with:

    python -m venv .venv
    source .venv/bin/activate
    pip install -r requirements.txt

Then run:

    make guide

The guide will be available in `./build/guide/index.html`.

[m]: https://www.mkdocs.org
[z]: https://en.wikipedia.org/wiki/Zak_McKracken_and_the_Alien_Mindbenders