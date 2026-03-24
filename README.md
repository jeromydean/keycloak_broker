# Keycloak broker POC

This repository includes a Docker Compose stack for a proof of concept with **three separate Keycloak servers**, each backed by its **own PostgreSQL** instance and persistent volume.

## Layout

| Instance    | Keycloak URL                    | Host port | Postgres service       |
|-------------|---------------------------------|-----------|-------------------------|
| `onprem_1`  | http://localhost:8181           | 8181      | `postgres_onprem_1`     |
| `onprem_2`  | http://localhost:8282           | 8282      | `postgres_onprem_2`     |
| `cloud_idp` | http://localhost:8080         | 8080      | `postgres_cloud_idp`    |

Images:

- Keycloak: `quay.io/keycloak/keycloak:26.0.5` (`start-dev`)
- PostgreSQL: `postgres:16-alpine`

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) with Compose v2 (`docker compose`)

## Start

From the repository root:

```bash
docker compose up -d
```

The first run can take a short while while each Postgres passes its health check and Keycloak creates its schema.

## Admin login

Each Keycloak instance uses the same bootstrap credentials unless you override them (see below):

- **Username:** `admin`
- **Password:** `admin`

Bootstrap admin is created on **first start** when the realm data does not yet exist.

## Environment variables

You can place a `.env` file next to `docker-compose.yml` to override defaults.

| Variable | Purpose |
|----------|---------|
| `POSTGRES_PASSWORD_ONPREM_1` | Password for `postgres_onprem_1` / matching Keycloak DB URL (default: `keycloak_onprem_1`) |
| `POSTGRES_PASSWORD_ONPREM_2` | Same for `onprem_2` (default: `keycloak_onprem_2`) |
| `POSTGRES_PASSWORD_CLOUD_IDP` | Same for `cloud_idp` (default: `keycloak_cloud_idp`) |
| `KEYCLOAK_ADMIN` | Bootstrap admin username for **all three** Keycloak instances (default: `admin`) |
| `KEYCLOAK_ADMIN_PASSWORD` | Bootstrap admin password for **all three** (default: `admin`) |

## Stop and reset

Stop containers without removing volumes:

```bash
docker compose down
```

Stop and **delete** Postgres data (full reset of all three stacks):

```bash
docker compose down -v
```

## Project structure

- `docker-compose.yml` — three Keycloak + three Postgres services and named volumes.

Other folders (for example under `src/`) may contain application code for this POC; see those projects for build and run instructions.
