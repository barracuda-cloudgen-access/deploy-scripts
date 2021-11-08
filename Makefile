### Make config

.ONESHELL:
SHELL = bash
.SHELLFLAGS = -eu -c

### Actions

lint:
	act -j linter --env-file <(echo "RUN_LOCAL=true")
