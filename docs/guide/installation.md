# Installation

There are two separate paths depending on what you want to do: hack on the framework itself (using the CLI to scaffold modules/plugins), or run an actual FiveM server that loads `core` as a resource.

## Path A — Framework development (npm + CLI)

From the `core` directory:

```bash
cd core
npm install
node cli/index.js --help
```

If you'd rather invoke the CLI as `obelisk` instead of `node cli/index.js`, link it globally:

```bash
chmod +x cli/index.js
npm link
obelisk --help
```

`package.json` also exposes the generators as npm scripts (`npm run make:module`, `npm run make:plugin`, `npm run make:model`, `npm run make:migration`, `npm run make:seeder`, `npm run make:action`, `npm run make:interaction`, `npm run make:policy`), which call the same CLI commands.

Generated files are written relative to the current working directory, so run `obelisk make:module` / `obelisk make:plugin` (and the other generators) from inside `core/` — not from the repository root.

## Path B — Running an actual FiveM server (Docker)

The repository root (one level above `core/`) has a `docker-compose.yml`, a `docker/fivem/` build context, and a `server-data/` directory with the server config. The FXServer build itself isn't baked into the Docker image — it's pulled onto the host first:

```bash
# from the repo root (one level above core/)
scripts/update-fivem-server.sh        # or scripts\update-fivem-server.bat on Windows
docker compose --profile mariadb up --build mariadb fxserver
```

`mariadb` and `postgres` are both gated behind a Compose profile (`--profile mariadb` / `--profile postgres`) so only one database container ever starts. There's no implicit default profile, even for MariaDB, so the flag is required in every invocation, including this one.

`docker compose --profile mariadb up --build mariadb fxserver` starts three things: the `mariadb` service (the default DB backend), the `fxserver` service (built from `docker/fivem/Dockerfile`, which mounts `./core` and `./oblsk_connector` straight from the repo as resources), and `oblsk_connector`'s Node.js sidecar, which the container's entrypoint script starts alongside FXServer before running `./run.sh +exec server.cfg`.

Before the server will actually run, edit `server-data/server.cfg` and set a real `sv_licenseKey` — get one from [keymaster.fivem.net](https://keymaster.fivem.net). The placeholder value `"changeme"` will not work.

### Switching to PostgreSQL

MariaDB is the default DB backend. To use PostgreSQL instead:

1. In `server-data/server.cfg`, set `db_driver "postgres"` and point `mysql_connection_string` at the `postgres` service instead of `mariadb`.
2. Start the `postgres` compose service alongside the rest:

   ```bash
   docker compose --profile postgres up postgres fxserver
   ```

   `mariadb` is gated behind its own `mariadb` profile, so it does not start alongside `postgres` here. `db_driver postgres` in `server.cfg` is still what actually selects the database the connector talks to; the profile flag only controls which containers run.

`db_driver` is the only thing that selects the ORM's SQL dialect — see [ORM: Dialects](/concepts/orm#dialects) for details.
