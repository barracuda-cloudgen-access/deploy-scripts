### Make config

.ONESHELL:
SHELL = bash
.SHELLFLAGS = -eu -c
.PHONY: lint

### Actions

lint:
	act -j linter --env-file <(echo "RUN_LOCAL=true")
