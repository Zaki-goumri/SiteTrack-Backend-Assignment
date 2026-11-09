set dotenv-load := true

default:
    @just --list

up:
    docker compose up -d --build

down:
    docker compose down

reset:
    docker compose down -v

logs service="api":
    docker compose logs -f {{service}}

ps:
    docker compose ps

migrate:
    docker compose run --rm migrate

seed:
    docker compose run --rm migrate /app/migrate seed

psql:
    docker compose exec postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}

run:
    go run ./cmd/api

build:
    go build -o bin/api ./cmd/api

fmt:
    go fmt ./...

vet:
    go vet ./...

tidy:
    go mod tidy

new-migration name:
    #!/usr/bin/env bash
    set -euo pipefail
    n=$(ls db/migrations/*.sql | wc -l)
    f=$(printf "db/migrations/%05d_%s.sql" $((n + 1)) "{{name}}")
    touch "$f"
    echo "$f"

explain file:
    docker compose exec -T postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} < {{file}}

docs:
    xdg-open http://localhost:${API_PORT}/docs
