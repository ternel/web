-include .env
default: help

# Variables
CURRENT_UID ?= $(shell id -u)
DOCKER_UP_OPTIONS ?=
DOCKER_COMPOSE_BIN ?= docker compose

# Colors
COLOR_RESET = \033[0m
COLOR_TARGET = \033[32m
COLOR_TITLE = \033[33m
TEXT_BOLD = \033[1m

.PHONY: help
.SILENT: help
help:
	printf "\n${COLOR_TITLE}Usage:${COLOR_RESET}\n"
	printf "  ${COLOR_TARGET}make${COLOR_RESET} [target]\n"
	printf "\n"
	awk '/^[\w\.@%-]+:/i { \
		helpMessage = match(lastLine, /^### (.*)/); \
		if (helpMessage) { \
			helpCommand = substr($$1, 0, index($$1, ":") - 1); \
			helpMessage = substr(lastLine, RSTART + 3, RLENGTH); \
			printf "  ${COLOR_TARGET}%-30s${COLOR_RESET} %s\n", helpCommand, helpMessage; \
		} \
	} \
	/^##@.+/ { \
		printf "\n${TEXT_BOLD}${COLOR_TITLE}%s${COLOR_RESET}\n", substr($$0, 5); \
	} \
	{ lastLine = $$0 }' $(MAKEFILE_LIST)

.PHONY: install docker-up docker-stop docker-down test hooks vendors db-seed db-migrations reset-db init console phpstan

##@ Minimal (DX oriented usage)

### Start the stack (works every time)
start:
	# Let's build and up the containers
	CURRENT_UID=$(CURRENT_UID) ENABLE_XDEBUG=$(ENABLE_XDEBUG) $(DOCKER_COMPOSE_BIN) build
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) up --detach --wait --no-build
	# Install vendors and assets
	make config
	# DB stuff, create and migrate
	echo 'CREATE DATABASE IF NOT EXISTS web' | $(DOCKER_COMPOSE_BIN) run -T --rm db /opt/mysql_no_db
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) run --rm -u localUser apachephp make db-migrations
	@echo
	@printf "Stack is up & ready! 🚀"
	@echo
	@printf "Site Afup accessible sur \033[32mhttps://localhost:9205\033[0m\n"
	@printf "mailcatcher accessible sur \033[32mhttps://localhost:1181\033[0m\n"

### Launch fixtures
fixtures:
    # Easy/conventional name to load fixtures
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) run --rm -u localUser apachephp make db-seed
	@echo
	@printf "Fixtures chargés ! 🚀"
	@echo
	@printf "Compte utilisateur (avec accès admin) \033[32madmin@admin.fr / admin\033[0m\n"

### Stop the stack
stop:
	make docker-stop

##@ Setup

### Installer les dépendences (composer, npm)
install: vendors

### Initialisation générale (config, bdd)
init: htdocs/uploads
	make config
	make init-db

##@ Docker

### Démarrer les containers
docker-up: .env var/logs/.docker-build data compose.override.yml
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) up $(DOCKER_UP_OPTIONS)

### Stopper les containers
docker-stop:
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) stop

### Supprimer les containers
docker-down:
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) down

### Démarrer un bash dans le container PHP
console:
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) exec -u localUser -it apachephp bash

##@ Quality

### (Dans Docker) Tests unitaires
test:
	./bin/phpunit --testsuite unit
	./bin/php-cs-fixer fix --dry-run -vv

### (Dans Docker) Tests d'intégration
test-integration:
	./bin/phpunit --testsuite integration

### (Dans Docker) Tests fonctionnels
behat:
	./bin/behat

### (Dans Docker) PHP CS Fixer (dry run)
cs-lint:
	./bin/php-cs-fixer fix --dry-run -vv

### (Dans Docker) PHP CS Fixer (fix)
cs-fix:
	./bin/php-cs-fixer fix -vv

### (Dans Docker) Rector (dry run)
rector: var/cache/dev/AppKernelDevDebugContainer.xml
	./bin/rector --dry-run

### (Dans Docker) Rector (fix)
rector-fix: var/cache/dev/AppKernelDevDebugContainer.xml
	./bin/rector

### Tests fonctionnels
test-functional: data config htdocs/uploads tmp
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) stop dbtest apachephptest mailcatcher
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) up -d dbtest apachephptest mailcatcher
	make clean-test-deprecated-log
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) run --no-deps --rm -u localUser apachephp ./bin/behat
	make var/logs/test.deprecations_grouped.log
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) stop dbtest apachephptest mailcatcher

### Tests d'intégration avec start/stop des images docker
test-integration-ci:
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) stop dbtest apachephptest
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) up -d dbtest apachephptest
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) run --no-deps --rm -u localUser apachephp make vendor
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) run --no-deps --rm -u localUser apachephp ./bin/phpunit --testsuite integration
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) stop dbtest apachephptest

### (Dans Docker) Analyse PHPStan
phpstan:
	./bin/phpstan --memory-limit=-1

##@ Frontend

### Compiler les assets pour la production
.PHONY: assets
assets:
	./node_modules/.bin/webpack -p

### Lancer le watcher pour les assets
watch:
	./node_modules/.bin/webpack --progress --colors --watch

##@ Git

### Mise en place de hooks
hooks: .git/hooks/pre-commit .git/hooks/post-checkout

.git/hooks/pre-commit: Makefile
	echo "#!/bin/sh" > .git/hooks/pre-commit
	echo "docker compose run --rm -u localUser apachephp make test" >> .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit

.git/hooks/post-checkout: Makefile
	echo "#!/bin/sh" > .git/hooks/post-checkout
	echo "docker compose run --rm -u localUser apachephp make vendor" >> .git/hooks/post-checkout
	chmod +x .git/hooks/post-checkout


## Targets cachés

var/logs/.docker-build: compose.yml compose.override.yml $(shell find docker -type f)
	CURRENT_UID=$(CURRENT_UID) ENABLE_XDEBUG=$(ENABLE_XDEBUG) $(DOCKER_COMPOSE_BIN) build
	touch var/logs/.docker-build

.env:
	cp .env.dist .env

compose.override.yml:
	cp compose.override.yml-dist compose.override.yml

vendors: vendor node_modules

vendor: composer.lock
	composer install --no-scripts

node_modules:
	npm install --legacy-peer-deps

init-db:
	make reset-db
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) run --rm -u localUser apachephp make db-migrations
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) run --rm -u localUser apachephp make db-seed

config:
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) run --no-deps --rm -u localUser apachephp make vendors
	CURRENT_UID=$(CURRENT_UID) $(DOCKER_COMPOSE_BIN) run --no-deps --rm -u localUser apachephp make assets

data:
	mkdir data
	mkdir data/composer

htdocs/uploads:
	mkdir htdocs/uploads

tmp:
	mkdir -p tmp

reset-db:
	echo 'DROP DATABASE IF EXISTS web' | $(DOCKER_COMPOSE_BIN) run -T --rm db /opt/mysql_no_db
	echo 'CREATE DATABASE web' | $(DOCKER_COMPOSE_BIN) run -T --rm db /opt/mysql_no_db

db-migrations:
	php bin/phinx migrate

db-seed:
	php bin/phinx seed:run

clean-test-deprecated-log:
	rm -f var/logs/test.deprecations.log

var/logs/test.deprecations_grouped.log:
	cat var/logs/test.deprecations.log | cut -d "]" -f 2 | awk '{$$1=$$1};1' | sort | uniq -c | sort -nr > var/logs/test.deprecations_grouped.log

var/cache/dev/AppKernelDevDebugContainer.xml:
	php bin/console cache:warmup --env=dev
