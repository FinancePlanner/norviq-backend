COMPOSE ?= docker compose

.PHONY: help build services migrate start logs stop

help:
	@printf "Targets:\n"
	@printf "  make start    Build images, start db/redis, run migrations, then start app\n"
	@printf "  make migrate  Start db, then run database migrations\n"
	@printf "  make logs     Follow app logs\n"
	@printf "  make stop     Stop the compose stack\n"

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
