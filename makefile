.PHONY: clean reactor guide

all: reactor

clean:
	rm -rf build/

reactor:
	npx elm reactor

guide:
	.venv/bin/mkdocs build -f guide/mkdocs.yml
