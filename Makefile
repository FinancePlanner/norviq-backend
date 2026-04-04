COMPOSE ?= docker compose

.PHONY: help build services migrate start logs stop lint dev

help:
	@printf "Targets:\n"
	@printf "  make dev      Start app in debug mode with hot-reloading (fastest)\n"
	@printf "  make start    Build images, start db/redis, run migrations, then start app (release)\n"
	@printf "  make migrate  Start db, then run database migrations\n"
	@printf "  make logs     Follow app logs\n"
	@printf "  make stop     Stop the compose stack\n"
	@printf "  make lint     Run SwiftLint with auto-fix\n"

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
