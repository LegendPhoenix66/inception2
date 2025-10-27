NAME = inception
COMPOSE_FILE = srcs/docker-compose.yml
ENV_FILE = srcs/.env
# Resolve DATA_PATH from srcs/.env if set; fallback to /home/$(USER)/data
DATA_PATH := $(shell awk -F= '/^DATA_PATH=/{print $$2}' $(ENV_FILE) 2>/dev/null)
ifeq ($(strip $(DATA_PATH)),)
DATA_PATH := /home/$(USER)/data
endif

# Default target
all: build up

# Build all Docker images
build:
	@echo "Building Docker images..."
	@sudo mkdir -p $(DATA_PATH)/wordpress
	@sudo mkdir -p $(DATA_PATH)/mariadb
	@sudo chown -R $(USER):$(USER) $(DATA_PATH)
	@docker compose -f $(COMPOSE_FILE) build

# Start all services
up:
	@echo "Starting services..."
	@docker compose -f $(COMPOSE_FILE) up -d

# Stop all services
down:
	@echo "Stopping services..."
	@docker compose -f $(COMPOSE_FILE) down

# Stop and remove all containers, networks, and volumes
clean:
	@echo "Cleaning up containers, networks, and volumes..."
	@docker compose -f $(COMPOSE_FILE) down -v --remove-orphans
	@docker system prune -af

# Remove all data
fclean: clean
	@echo "Removing all data..."
	@sudo rm -rf $(DATA_PATH)
	@docker volume prune -f

# Rebuild everything from scratch
re: fclean all

# Show logs
logs:
	@docker compose -f $(COMPOSE_FILE) logs -f

# Show status of services
status:
	@docker compose -f $(COMPOSE_FILE) ps

# Restart services
restart: down up

# Enter a specific container (usage: make exec SERVICE=nginx)
exec:
	@docker compose -f $(COMPOSE_FILE) exec $(SERVICE) /bin/sh

.PHONY: all build up down clean fclean re logs status restart exec