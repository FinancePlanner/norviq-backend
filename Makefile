COMPOSE ?= docker compose
APP_IMAGE ?=
APP_IMAGE_TAG ?= local-dev
BACKEND_TEST_ENV ?= testing

.PHONY: help build services migrate start logs stop lint dev build-dev \
	container-local health production-preflight rollback-app prune-images \
	backup-db restore-drill export-user-data backend-test backend-openapi-check

help:
	@printf "Targets:\n"
	@printf "  make dev      Start app in debug mode with hot-reloading (fastest)\n"
	@printf "  make start    Build images, start db/redis, run migrations, then start app (release)\n"
	@printf "  make migrate  Start db, then run database migrations\n"
	@printf "  make logs     Follow app logs\n"
	@printf "  make stop     Stop the compose stack\n"
	@printf "  make lint     Run SwiftLint with auto-fix\n"
	@printf "  make backend-test          Run the backend Swift test suite\n"
	@printf "  make backend-openapi-check Run OpenAPI documentation drift checks\n"
	@printf "  make container-local APP_IMAGE=ghcr.io/<owner>/<repo> [APP_IMAGE_TAG=local-dev]\n"
	@printf "  make health DOMAIN=<domain> [ATTEMPTS=30] [SLEEP_SECONDS=2]\n"
	@printf "  make production-preflight DOMAIN=<domain> ORIGIN=<allowed-origin>\n"
	@printf "  make rollback-app APP_IMAGE=ghcr.io/<owner>/<repo>:<sha>\n"
	@printf "  make prune-images [UNTIL=168h]\n"
	@printf "  make backup-db [BACKUP_DIR=./backups]\n"
	@printf "  make restore-drill BACKUP_FILE=<backup.sql.gpg> RESTORE_DATABASE_URL=<postgres-url>\n"
	@printf "  make export-user-data EXPORT_USER=<email-or-uuid> DATABASE_URL=<postgres-url>\n"

dev: build-dev
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

install-hooks:
	cp scripts/pre-commit .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit

lint:
	swiftlint --fix

format:
	swiftformat .

backend-test:
	LOG_LEVEL=$(or $(LOG_LEVEL),warning) swift test

backend-openapi-check:
	LOG_LEVEL=$(or $(LOG_LEVEL),warning) swift test --filter OpenAPIDocsTests

container-local:
	@test -n "$(APP_IMAGE)" || (echo "APP_IMAGE is required. Example: make container-local APP_IMAGE=ghcr.io/owner/StockPlanBackend" && exit 1)
	./scripts/build_container_image_local.sh "$(APP_IMAGE)" "$(APP_IMAGE_TAG)"

health:
	@test -n "$(DOMAIN)" || (echo "DOMAIN is required. Example: make health DOMAIN=api.stockplan.app" && exit 1)
	./scripts/ops/check_health.sh "$(DOMAIN)" "$(or $(ATTEMPTS),30)" "$(or $(SLEEP_SECONDS),2)"

production-preflight:
	@test -n "$(DOMAIN)" || (echo "DOMAIN is required. Example: make production-preflight DOMAIN=api.stockplan.app ORIGIN=https://www.norviqaapp.com" && exit 1)
	./scripts/ops/production_preflight.sh "$(DOMAIN)" "$(ORIGIN)"

rollback-app:
	@test -n "$(APP_IMAGE)" || (echo "APP_IMAGE is required. Example: make rollback-app APP_IMAGE=ghcr.io/owner/StockPlanBackend:<sha>" && exit 1)
	./scripts/ops/rollback_app_image.sh "$(APP_IMAGE)"

prune-images:
	./scripts/ops/prune_images.sh "$(or $(UNTIL),168h)"

backup-db:
	./scripts/ops/backup_postgres.sh

restore-drill:
	@test -n "$(BACKUP_FILE)" || (echo "BACKUP_FILE is required. Example: make restore-drill BACKUP_FILE=backups/stockplan.sql.gpg RESTORE_DATABASE_URL=postgres://..." && exit 1)
	@test -n "$(RESTORE_DATABASE_URL)" || (echo "RESTORE_DATABASE_URL is required." && exit 1)
	./scripts/ops/restore_drill_postgres.sh "$(BACKUP_FILE)"

export-user-data:
	@test -n "$(EXPORT_USER)" || (echo "EXPORT_USER is required. Example: make export-user-data EXPORT_USER=user@example.com DATABASE_URL=postgres://..." && exit 1)
	@test -n "$(DATABASE_URL)" || (echo "DATABASE_URL is required." && exit 1)
	./scripts/ops/export_user_data.sh "$(EXPORT_USER)"
