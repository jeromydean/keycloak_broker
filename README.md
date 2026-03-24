# Keycloak broker POC

This repository includes a Docker Compose stack for a proof of concept with **three separate Keycloak servers**, each backed by its **own PostgreSQL** instance and persistent volume.

## Layout

| Instance    | Keycloak URL                    | Host port | Postgres service       |
|-------------|---------------------------------|-----------|-------------------------|
| `onprem_1`  | http://localhost:8181 (main), http://localhost:9191 (management) | 8181, 9191 | `postgres_onprem_1` |
| `onprem_2`  | http://localhost:8282 (main), http://localhost:9292 (management) | 8282, 9292 | `postgres_onprem_2` |
| `cloud_idp` | http://localhost:8080 (main), http://localhost:9090 (management) | 8080, 9090 | `postgres_cloud_idp` |

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

Keycloak serves **`/health`**, **`/health/ready`**, etc. on the [**management interface**](https://www.keycloak.org/server/management-interface) (default **`KC_HTTP_MANAGEMENT_PORT=9000`**), not on the main HTTP port. This compose maps **9000** to the host as **9191** / **9292** / **9090** so you can open e.g. http://localhost:9191/health/ready for **onprem_1**. **`KC_HEALTH_ENABLED`** and **`KC_METRICS_ENABLED`** are set so those endpoints exist.

The **cloud** Keycloak service includes `extra_hosts: host.docker.internal:host-gateway` so it can reach on-prem Keycloak on the host during broker token/JWKS calls (used by `keycloak-setup.ps1`).

## Organizations (cloud realm)

**`keycloak-setup.ps1`** turns on **`organizationsEnabled`** on the **`cloud`** realm, creates organizations **`org1`** and **`org2`**, and **links** identity providers **`onprem-1`** and **`onprem-2`** to them so they appear as linked organizations in the admin console (see [management interface](https://www.keycloak.org/server/management-interface) / Organizations in server docs).

**`keycloak_cloud_idp`** is started with **`--features=organization`** so the Organizations Admin API exists on that instance. On-prem Keycloak containers do not need this unless you use organizations there too.

Override names via script parameters: **`Org1Alias`**, **`Org2Alias`**, **`Org1DisplayName`**, **`Org2DisplayName`**. Keycloak requires at least one **domain** per organization; defaults are **`Org1DomainName=org1.poc.local`** and **`Org2DomainName=org2.poc.local`** (change to real customer domains in production).

## Keycloak provisioning (realms, IdPs, users)

After the stack is healthy, run (from any directory; use a full path if needed):

```powershell
pwsh -File .\keycloak-setup.ps1
```

This script (idempotent where possible):

- Creates realm **`onprem`** on **onprem_1** and **onprem_2**, confidential OIDC client **`cloud-broker`** (per-instance secret), and users **`onprem1_user`** / **`onprem2_user`** (default passwords in the script synopsis).
- Creates realm **`cloud`** on **cloud_idp**, OIDC identity providers **`onprem-1`** and **`onprem-2`**, a **username template** mapper so broker usernames look like `onprem-1.<preferred_username>`, and public OIDC client **`test-client`** (redirect `*` — POC only).

Override defaults with script parameters (see `.SYNOPSIS` / `param` block in `keycloak-setup.ps1`). **Authorization** endpoints use `localhost` (browser); **token / JWKS / userinfo** use `host.docker.internal` from the cloud container.

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
- `keycloak-setup.ps1` — provisions realms, IdPs, users, organizations, and clients (run from repo root).

## TestClient (MSAL + onprem_1 Keycloak)

The **`src/TestClient`** console app uses **Microsoft.Identity.Client** with **`WithExperimentalFeatures(true)`** and **`WithOidcAuthority(...)`** so MSAL treats **Keycloak** as a generic OIDC provider (see [MSAL generic OIDC](https://github.com/AzureAD/microsoft-authentication-library-for-dotnet/pull/4653)).

1. Run **`keycloak-setup.ps1`** from the repo root (creates realm **`onprem`**, user **`onprem1_user`**, and public client **`msal-onprem`** with redirects `http://localhost` and `http://127.0.0.1`).
2. From `src/TestClient`: `dotnet run`
3. Complete login in the system browser (`onprem1_user` / `onprem1_password` by default).

Defaults in code: authority `http://localhost:8181/realms/onprem`, client id `msal-onprem`, redirect `http://localhost`.

Other folders under `src/` (for example **CloudAPI**) have their own build and run instructions.
