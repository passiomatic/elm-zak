.PHONY: guide

clean:
	rm -rf build/

guide:
	.venv/bin/mkdocs build -f guide/mkdocs.yml
