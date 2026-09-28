## Build the documentation

The project uses [mkdocs][m] to convert the Markdown files into browsable HTML pages.

To rebuild the docs, first create a Python virtual env and install all the required mkdocs dependencies with:

    python -m venv .venv
    source .venv/bin/activate
    pip install -r requirements.txt

Then run:

    make guide

The guide will be available in `./build/guide/Index.html`.

[m]: https://www.mkdocs.org
