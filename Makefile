COMPOSE ?= docker compose
APP_IMAGE ?=
APP_IMAGE_TAG ?= local-dev

.PHONY: help build services migrate start logs stop lint dev \
	container-local health rollback-app prune-images

help:
	@printf "Targets:\n"
	@printf "  make dev      Start app in debug mode with hot-reloading (fastest)\n"
	@printf "  make start    Build images, start db/redis, run migrations, then start app (release)\n"
	@printf "  make migrate  Start db, then run database migrations\n"
	@printf "  make logs     Follow app logs\n"
	@printf "  make stop     Stop the compose stack\n"
	@printf "  make lint     Run SwiftLint with auto-fix\n"
	@printf "  make container-local APP_IMAGE=ghcr.io/<owner>/<repo> [APP_IMAGE_TAG=local-dev]\n"
	@printf "  make health DOMAIN=<domain> [ATTEMPTS=30] [SLEEP_SECONDS=2]\n"
	@printf "  make rollback-app APP_IMAGE=ghcr.io/<owner>/<repo>:<sha>\n"
	@printf "  make prune-images [UNTIL=168h]\n"

dev: build-dev services
	docker compose -f docker-compose.dev.yml up app

build-dev:
	docker compose -f docker-compose.dev.yml build app

build:
	$(COMPOSE) build

services:
	$(COMPOSE) up -d db redis

migrate: build services
	$(COMPOSE) run --rm migrate

start: migrate
	$(COMPOSE) up -d app

logs:
	$(COMPOSE) logs -f app

stop:
	$(COMPOSE) down --remove-orphans

update-all:
	swift package update

update-shared:
	swift package update financeshared

lint:
	swiftlint --fix

container-local:
	@test -n "$(APP_IMAGE)" || (echo "APP_IMAGE is required. Example: make container-local APP_IMAGE=ghcr.io/owner/StockPlanBackend" && exit 1)
	./scripts/build_container_image_local.sh "$(APP_IMAGE)" "$(APP_IMAGE_TAG)"

health:
	@test -n "$(DOMAIN)" || (echo "DOMAIN is required. Example: make health DOMAIN=api.stockplan.app" && exit 1)
	./scripts/ops/check_health.sh "$(DOMAIN)" "$(or $(ATTEMPTS),30)" "$(or $(SLEEP_SECONDS),2)"

rollback-app:
	@test -n "$(APP_IMAGE)" || (echo "APP_IMAGE is required. Example: make rollback-app APP_IMAGE=ghcr.io/owner/StockPlanBackend:<sha>" && exit 1)
	./scripts/ops/rollback_app_image.sh "$(APP_IMAGE)"

prune-images:
	./scripts/ops/prune_images.sh "$(or $(UNTIL),168h)"
