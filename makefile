.PHONY: clean reactor guide

clean:
	rm -rf build/

reactor:
	elm reactor

guide:
	.venv/bin/mkdocs build -f guide/mkdocs.yml
