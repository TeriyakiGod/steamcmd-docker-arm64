IMAGE ?= steamcmd-arm64:test

.PHONY: build test test-full unit lint

build:
	docker buildx build --platform linux/arm64 --load -t $(IMAGE) .

unit:
	tests/test-fex-variant.sh

test: unit
	tests/smoke.sh $(IMAGE)

test-full: unit
	FULL=1 tests/smoke.sh $(IMAGE)

lint:
	docker run --rm -v "$(CURDIR):/src:ro" -w /src koalaman/shellcheck:stable \
		docker/entrypoint.sh docker/fetch-fex.sh docker/fex-variant tests/*.sh
	docker run --rm -i -v "$(CURDIR)/.hadolint.yaml:/.config/hadolint.yaml:ro" hadolint/hadolint < Dockerfile
