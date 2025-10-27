NAME = inception
COMPOSE_FILE = srcs/docker-compose.yml
ENV_FILE = srcs/.env
# Resolve DATA_PATH from srcs/.env if set; fallback to /home/$(USER)/data
DATA_PATH := $(shell awk -F= '/^DATA_PATH=/{print $$2}' $(ENV_FILE) 2>/dev/null)
ifeq ($(strip $(DATA_PATH)),)
DATA_PATH := /home/$(USER)/data
endif

# Determine docker compose command (prefer v2 `docker compose`, fallback to legacy `docker-compose`)
DOCKER_COMPOSE := $(if $(shell docker compose version >/dev/null 2>&1 && echo yes),docker compose,$(if $(shell command -v docker-compose >/dev/null 2>&1 && echo yes),docker-compose,docker compose))

# Detect whether current user can talk to the Docker daemon; if not, prefix with sudo
NEED_SUDO := $(shell docker info >/dev/null 2>&1 || echo yes)
ifeq ($(strip $(NEED_SUDO)),yes)
SUDO := sudo
else
SUDO :=
endif
DOCKER_CMD := $(SUDO) $(DOCKER_COMPOSE)
DOCKER := $(SUDO) docker

# Default target
all: build up

# Build all Docker images
build:
	@echo "Building Docker images..."
	@sudo mkdir -p $(DATA_PATH)/wordpress
	@sudo mkdir -p $(DATA_PATH)/mariadb
	@sudo chown -R $(USER):$(USER) $(DATA_PATH)
	@$(DOCKER_CMD) -f $(COMPOSE_FILE) build

# Start all services
up:
	@echo "Starting services..."
	@sudo mkdir -p $(DATA_PATH)/wordpress
	@sudo mkdir -p $(DATA_PATH)/mariadb
	@sudo chown -R $(USER):$(USER) $(DATA_PATH)
	@$(DOCKER_CMD) -f $(COMPOSE_FILE) up -d

# Stop all services
down:
	@echo "Stopping services..."
	@$(DOCKER_CMD) -f $(COMPOSE_FILE) down

# Stop and remove all containers, networks, and volumes
clean:
	@echo "Cleaning up containers, networks, and volumes..."
	@$(DOCKER_CMD) -f $(COMPOSE_FILE) down -v --remove-orphans
	@$(DOCKER) system prune -af

# Remove all data
fclean: clean
	@echo "Removing all data..."
	@sudo rm -rf $(DATA_PATH)
	@$(DOCKER) volume prune -f

# Rebuild everything from scratch
re: fclean all

# Show logs
logs:
	@$(DOCKER_CMD) -f $(COMPOSE_FILE) logs -f

# Show status of services
status:
	@$(DOCKER_CMD) -f $(COMPOSE_FILE) ps

# Restart services
restart: down up

# Enter a specific container (usage: make exec SERVICE=nginx)
exec:
	@$(DOCKER_CMD) -f $(COMPOSE_FILE) exec $(SERVICE) /bin/sh

# Print the configured domain name from srcs/.env
domain:
	@awk -F= '/^DOMAIN_NAME=/{print $$2}' $(ENV_FILE)

# Print the full HTTPS URL for the site
url:
	@echo "https://$$(awk -F= '/^DOMAIN_NAME=/{print $$2}' $(ENV_FILE))"

# Try to open the site in the VM's default browser (if xdg-open is available)
open:
	@which xdg-open >/dev/null 2>&1 && xdg-open "https://$$(awk -F= '/^DOMAIN_NAME=/{print $$2}' $(ENV_FILE))" || echo "Open this URL in your browser: https://$$(awk -F= '/^DOMAIN_NAME=/{print $$2}' $(ENV_FILE))"

.PHONY: all build up down clean fclean re logs status restart exec domain url open