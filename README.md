# Keycloak broker POC

This repository includes a Docker Compose stack for a proof of concept with **three separate Keycloak servers**, each backed by its **own PostgreSQL** instance and persistent volume.

## Layout

| Instance    | Keycloak URL | Postgres service |
|-------------|--------------|------------------|
| `onprem_1`  | **HTTPS** `https://localhost:8181` (main), **HTTP** `http://localhost:8182` (backchannel from cloud only), management **`https://localhost:9191`** | `postgres_onprem_1` |
| `onprem_2`  | **HTTPS** `https://localhost:8282`, **HTTP** `http://localhost:8283` (backchannel), management **`https://localhost:9292`** | `postgres_onprem_2` |
| `cloud_idp` | **HTTPS** `https://localhost:8080`, management **`https://localhost:9090`** | `postgres_cloud_idp` |

Run **`.\initial-setup.ps1`** once (accept UAC): it creates **`certs\keycloak-onprem-1.pfx`**, **`keycloak-onprem-2.pfx`**, **`keycloak-cloud-idp.pfx`**, and installs each into **LocalMachine\Trusted Root** so browsers and .NET trust the dev hostnames.

Images:

- Keycloak: `quay.io/keycloak/keycloak:26.0.5` (`start-dev`)
- PostgreSQL: `postgres:16-alpine`

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) with Compose v2 (`docker compose`)

## Start

From the repository root:

1. **`.\initial-setup.ps1`** (Administrator) — generates the three PFX files and trusts them.
2. **`docker compose up -d`**

The first run can take a short while while each Postgres passes its health check and Keycloak creates its schema.

Keycloak serves **`/health`**, **`/health/ready`**, etc. on the [**management interface**](https://www.keycloak.org/server/management-interface) (default **`KC_HTTP_MANAGEMENT_PORT=9000`**), not on the main public HTTPS port. This compose maps **9000** to the host as **9191** / **9292** / **9090**; with dev TLS enabled, use **`https://localhost:9191/health/ready`** (and the matching ports for the other instances). **`keycloak-setup.ps1`** waits on those HTTPS URLs.

On-prem instances also expose a second **HTTP** port (**8182** / **8283**) mapped to Keycloak’s internal **8080** so the **cloud** container can call token/JWKS/userinfo without JVM TLS trust setup; **`KC_HOSTNAME_URL`** keeps OIDC issuer URLs on the public **HTTPS** ports.

The **cloud** Keycloak service includes `extra_hosts: host.docker.internal:host-gateway` for those backchannel calls.

## Organizations (cloud realm)

**`keycloak-setup.ps1`** turns on **`organizationsEnabled`** on the **`cloud`** realm, creates organizations **`org1`** and **`org2`**, and **links** identity providers **`onprem-1`** and **`onprem-2`** to them so each IdP appears under **Organization → Identity providers** in the admin UI (not only under realm **Identity providers**). Re-run the script if linking was skipped earlier (older script versions resolved org IDs using the wrong search API).

**`keycloak_cloud_idp`** is started with **`--features=organization`** so the Organizations Admin API exists on that instance. On-prem Keycloak containers do not need this unless you use organizations there too.

Override names via script parameters: **`Org1Alias`**, **`Org2Alias`**, **`Org1DisplayName`**, **`Org2DisplayName`**. Keycloak requires at least one **domain** per organization; defaults are **`Org1DomainName=org1.poc.local`** and **`Org2DomainName=org2.poc.local`** (change to real customer domains in production).

## Keycloak provisioning (realms, IdPs, users)

After the stack is healthy, run (from any directory; use a full path if needed):

```powershell
pwsh -File .\keycloak-setup.ps1
```

This script (idempotent where possible):

- Creates realm **`onprem`** on **onprem_1** and **onprem_2**, confidential OIDC client **`cloud-broker`** (per-instance secret), and users **`onprem1_user`** / **`onprem2_user`** with **email**, **first name**, and **last name** (defaults: `{username}@poc.local` and names parsed from the username; re-run fills missing profile fields on existing users). Passwords are in the script synopsis; optional overrides: **`User1Email`**, **`User1FirstName`**, **`User1LastName`** (and **`User2*`**).
- Creates realm **`cloud`** on **cloud_idp**, OIDC identity providers **`onprem-1`** and **`onprem-2`**, a **username template** mapper so broker usernames look like `onprem-1.<preferred_username>`, and public OIDC client **`test-client`** (redirect `*` — POC only).

Override defaults with script parameters (see `.SYNOPSIS` / `param` block in `keycloak-setup.ps1`). **Authorization** uses **HTTPS** on `localhost`; **token / JWKS / userinfo** from the cloud container use **HTTP** `host.docker.internal` on **8182** / **8283**. The broker IdP **issuer** matches the **public** on-prem URL ( **`iss`** follows **`KC_HOSTNAME_URL`** ). **Userinfo** is disabled on the broker IdP (`disableUserInfo`): calling userinfo on `http://host.docker.internal:8182` with an access token whose `iss` is `https://localhost:8181/...` makes on-prem return **invalid_token**. Re-run **`keycloak-setup.ps1`** to sync existing IdPs.

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
| `KEYCLOAK_KEYSTORE_PASSWORD` | PKCS#12 password for mounted **`certs\keycloak-*.pfx`** (default: `password`; must match `initial-setup.ps1`) |

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
- `initial-setup.ps1` — dev TLS: three PFX files + machine **Trusted Root** (elevated).
- `keycloak-setup.ps1` — provisions realms, IdPs, users, organizations, and clients (run from repo root).

## CloudAPI (JWT from cloud realm)

**`src/CloudAPI`** validates **Bearer** tokens issued by **`https://localhost:8080/realms/cloud`** (same realm the broker uses). Run it on a fixed port for the POC:

```bash
cd src/CloudAPI
dotnet run --launch-profile http
```

Default URL: **`http://localhost:5300`** (`/health` anonymous, **`/api/whoami`** requires a valid cloud access token whose **`aud`** includes **`cloudservices`** — provisioned by **`keycloak-setup.ps1`** via an audience mapper on **`test-client`**).

## TestClient (MSAL + cloud broker → on-prem)

The **`src/TestClient`** app signs in against the **cloud** realm with public client **`test-client`**. At Keycloak’s login UI, choose an identity provider (**`onprem-1`** or **`onprem-2`**), then sign in with the matching on-prem user (e.g. **`onprem1_user`** / **`onprem1_password`**). The **access token is issued by the cloud realm** (broker flow); it is **not** the raw on-prem token.

After sign-in, TestClient calls **`http://localhost:5300/api/whoami`** on CloudAPI.

1. Stack up + **`keycloak-setup.ps1`** (realm **`cloud`**, IdPs **`onprem-1`** / **`onprem-2`**, client **`test-client`**).
2. Start **CloudAPI** (`dotnet run --launch-profile http` in `src/CloudAPI`).
3. From **`src/TestClient`**: `dotnet run` (Keycloak shows **onprem-1** / **onprem-2**), or pin a broker tenant: **`dotnet run -- onprem_1`** / **`dotnet run -- onprem_2`** (sends Keycloak **`kc_idp_hint`** so the matching IdP alias is used—underscores are mapped to hyphens, e.g. `onprem_1` → `onprem-1`).

Uses **Microsoft.Identity.Client** **`WithOidcAuthority`** ([generic OIDC](https://github.com/AzureAD/microsoft-authentication-library-for-dotnet/pull/4653)). Requires TLS trust from **`initial-setup.ps1`** for `https://localhost:8080` and `8181`.

To sign in **directly** to on-prem only (no broker), use client **`msal-onprem`** and authority **`https://localhost:8181/realms/onprem`** in your own code; CloudAPI in this repo is configured for **cloud** tokens.
