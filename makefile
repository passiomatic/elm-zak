.PHONY: guide

clean:
	rm -rf build/

rector:
	elm reactor

guide:
	.venv/bin/mkdocs build -f guide/mkdocs.yml
