# Manticore Search Docker Stack

A production-ready Docker Compose stack for running [Manticore Search](https://manticoresearch.com/)
behind a [Caddy](https://caddyserver.com/) reverse proxy with automatic HTTPS
and HTTP Basic Authentication.

Designed to be deployed by a webmaster on a VPS in under ten minutes, with no
prior DevOps experience. The stack is the recommended way to run a Manticore
server for use with the
[Search API Manticore](https://www.drupal.org/project/search_api_manticore)
Drupal module, but it is generic — any HTTP client can talk to it.

- **Manticore Search 25.0** — the latest stable release
- **Caddy 2** — automatic Let's Encrypt TLS certificates, HTTP Basic Auth
- **Production defaults** — memory locking, raised ulimits, persistent volume,
  healthcheck, automatic restart


## Table of contents

- [Deployment scenarios](#deployment-scenarios)
- [Requirements](#requirements)
- [Install Docker on Ubuntu 24.04 LTS](#install-docker-on-ubuntu-2404-lts)
- [Deploy the stack](#deploy-the-stack)
- [Verify the installation](#verify-the-installation)
- [Connecting from Drupal](#connecting-from-drupal)
- [Operations](#operations)
- [Troubleshooting](#troubleshooting)
- [License](#license)


## Deployment scenarios

There are two supported scenarios. Both use the same `docker-compose.yml`;
the difference is whether the Caddy reverse proxy is enabled and how Manticore
ports are exposed.

**Scenario A — Single VPS.** Drupal and Manticore live on the same server.
Manticore listens only on `127.0.0.1` and is reachable from the local Drupal
installation as `http://127.0.0.1:9308`. No TLS or authentication is needed
because the port is not exposed to the network. Best for small blogs and
wikis (≈ 1k–5k nodes) running on a single host.

**Scenario B — Two VPS, public endpoint.** Drupal runs on one server,
Manticore on another. The bundled Caddy reverse proxy terminates TLS
(automatic Let's Encrypt certificate) and enforces HTTP Basic Authentication
in front of Manticore's HTTP API. Only ports `80` and `443` are exposed
publicly; Manticore itself binds to `127.0.0.1` inside the host. Best for
medium-to-large sites (tens of thousands of documents and up) where the
search server is dedicated.

You choose between the two scenarios with a single Docker Compose flag.
Switching later is also possible.


## Requirements

- A VPS with **Ubuntu 24.04 LTS** (other modern Linux distributions will
  work too, but commands in this README are for Ubuntu)
- **2 GB RAM minimum** for small workloads; 4 GB+ recommended for
  hundreds of thousands of documents
- **`x86_64` or `arm64`** CPU architecture
- **Docker Engine 24+** and **Docker Compose plugin v2+**
  (installation instructions below)
- For Scenario B only:
  - a **domain or subdomain** with an `A` record pointing to the VPS
  - ports **80** and **443** open to the public internet


## Install Docker on Ubuntu 24.04 LTS

The instructions below follow the official Docker installation guide for
Ubuntu, adapted as a copy-paste-friendly sequence. They install Docker Engine
from Docker's own APT repository — not from Ubuntu's bundled `docker.io`
package, which is typically several versions behind.

Tested on a fresh Ubuntu 24.04.4 LTS (`noble`) `x86_64` VPS with Docker Engine
29.5.0 and Docker Compose plugin v5.1.3.

**1. Verify your system.** All commands below assume Ubuntu 24.04 LTS on the
`amd64` (x86_64) or `arm64` (aarch64) architecture. To verify:

```bash
lsb_release -a       # should show "Ubuntu 24.04" and codename "noble"
uname -m             # should show "x86_64" or "aarch64"
```

**2. Remove any conflicting packages.** Older or alternative container tools
shipped with Ubuntu can clash with Docker's own packages. On a fresh VPS this
step is a no-op and is safe to run:

```bash
for pkg in docker.io docker-doc docker-compose docker-compose-v2 \
           podman-docker containerd runc; do
  sudo apt-get remove -y $pkg 2>/dev/null
done
```

**3. Install prerequisites.** These let APT use HTTPS repositories and verify
GPG signatures:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
```

**4. Add Docker's official GPG key and APT repository.**

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
     -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
| sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
```

After the `apt-get update`, you should see a line referring to
`download.docker.com` in the output — that confirms the repository is
configured correctly.

**5. Install Docker Engine, CLI, containerd, Buildx and Compose plugins.**

```bash
sudo apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
```

**6. Enable and start the Docker service.**

```bash
sudo systemctl enable --now docker
sudo systemctl status docker --no-pager
```

The status output should contain `Active: active (running)`.

**7. Verify the installation.**

```bash
docker --version
docker compose version
sudo docker run --rm hello-world
```

The `hello-world` container should print a confirmation message starting with
`Hello from Docker!`. If you see it, Docker is fully functional and ready to
run Manticore.

> **A note on running Docker as a non-root user.** The commands above use
> `sudo`. To allow your regular user account to run `docker` without `sudo`,
> add it to the `docker` group: `sudo usermod -aG docker $USER`, then log out
> and back in. Be aware that membership in the `docker` group is effectively
> equivalent to having root access on the host — only add trusted users.

**8. Allow your regular user to run Docker without `sudo` (recommended).**

Running the rest of this guide as `root` is possible but discouraged. To
manage the stack as a non-root user (e.g. `webmaster`), add that user to the
`docker` group:

```bash
sudo usermod -aG docker $USER
```

Replace `$USER` with the target username if you are not currently logged in
as that user. Verify the change took effect:

```bash
getent group docker        # should list your user
```

**The group is applied at login time, not immediately.** Log out of all SSH
sessions and reconnect for the change to take effect. After reconnecting:

```bash
groups                     # the output should contain "docker"
docker ps                  # should work without sudo, showing an empty table
```

> ⚠️ **Security note.** Members of the `docker` group can effectively obtain
> root access on the host through container escapes (e.g. by mounting `/` into
> a privileged container). Only add users you fully trust. On a single-admin
> VPS this is the standard setup; on shared servers, consider
> [rootless Docker](https://docs.docker.com/engine/security/rootless/)
> instead.

All `docker` and `docker compose` commands in the rest of this README assume
they are run as a regular user from the `docker` group, without `sudo`.


## Deploy the stack

The stack consists of a single `docker-compose.yml` describing two services
(`manticore` and `caddy`) and a couple of supporting files. Clone this
repository and start the stack with one command — no further configuration
is needed for Scenario A.

**1. Clone the repository.**

Pick a location. For a production deployment, `/opt/manticore-stack/` is the
recommended FHS-compliant directory for self-managed services. For testing or
development, anywhere in your home directory works:

```bash
# Production deployment
sudo git clone https://github.com/dillix/manticore-docker.git /opt/manticore-stack
sudo chown -R $USER:$USER /opt/manticore-stack
cd /opt/manticore-stack

# Or, for development
mkdir -p ~/Projects && cd ~/Projects
git clone git@github.com:dillix/manticore-docker.git
cd manticore-docker
```

Use the HTTPS URL for read-only deployment, or the SSH URL if you plan to
contribute. The `chown` step transfers ownership to the current user so that
all subsequent `docker compose` commands can be run without `sudo` (assuming
your user is in the `docker` group, see installation step 8 above).

**2. Start Manticore (Scenario A — no Caddy).**

```bash
docker compose up -d
```

On the first run Docker downloads the `manticoresearch/manticore:25.0.0`
image from Docker Hub (~200 MB) and creates the container in detached
(background) mode. Expected output:

```
[+] up 2/2
 ✔ Network manticore-docker_manticore  Created
 ✔ Container manticore                 Started
```

**3. Verify that the container is running.**

```bash
docker compose ps
```

Within ~30 seconds (the healthcheck `start_period`) the status changes from
`(health: starting)` to `(healthy)`:

```
NAME        IMAGE                              STATUS                  PORTS
manticore   manticoresearch/manticore:25.0.0   Up X seconds (healthy)  127.0.0.1:9306->9306/tcp, 127.0.0.1:9308->9308/tcp, 9312/tcp
```

Note that ports `9306` and `9308` are bound to `127.0.0.1` only — they are
not reachable from the public network. Port `9312` is the internal Sphinx
protocol port, not exposed to the host at all.

**4. Inspect the daemon log.**

```bash
docker compose logs manticore --tail=20
```

You should see the daemon initialising and the line `accepting connections`:

```
manticore  | starting daemon version '25.0.0 ...' ...
manticore  | listening on all interfaces for mysql, port=9306
manticore  | listening on all interfaces for sphinx and http(s), port=9308
manticore  | listening on 172.18.0.2:9312 for sphinx and http(s)
manticore  | prereading 0 tables
manticore  | preread 0 tables in 0.000 sec
manticore  | accepting connections
manticore  | [BUDDY] started v3.44.1+... at http://127.0.0.1:...
manticore  | [BUDDY] Loaded plugins:
manticore  | [BUDDY]   core: empty-string, backup, emulate-elastic, fuzzy, create-table, ...
```

The `[BUDDY]` lines indicate that
[Manticore Buddy](https://github.com/manticoresoftware/manticoresearch-buddy)
— the embedded PHP plugin system that extends Manticore's SQL parser — has
loaded successfully. This is normal and required for many SQL features.


## Verify the installation

Manticore exposes a simple JSON over HTTP API on port 9308. The following
end-to-end smoke test creates a small table, inserts three documents,
performs full-text searches against them, and tears the table down. Run it
on the same VPS to confirm the stack is fully functional.

**1. Server status and version.**

```bash
curl -s http://127.0.0.1:9308/cli -d 'SHOW VERSION'
```

```
+------------+-----------------------------------+
| Component  | Version                           |
+------------+-----------------------------------+
| Daemon     | 25.0.0 ce3c27828@26032712         |
| Columnar   | columnar 13.0.0 e60b083@26032708  |
| Secondary  | secondary 13.0.0 e60b083@26032708 |
| Knn        | knn 13.0.0 e60b083@26032708       |
| Embeddings | embeddings 1.1.1 e60b083@26032708 |
| Buddy      | buddy v3.44.1+26031916-d0ff5bfe   |
+------------+-----------------------------------+
```

The image includes columnar storage, secondary indexes, KNN (vector search),
and embeddings — all extension modules are loaded by default.

**2. Create a test table and insert documents.**

```bash
# Create a real-time table with two text fields and one integer attribute.
curl -s http://127.0.0.1:9308/cli \
  -d 'CREATE TABLE testrt (title text, content text, gid integer)'

# Insert three documents.
curl -s http://127.0.0.1:9308/insert \
  -d '{"index":"testrt","id":1,"doc":{"title":"Hello world","content":"Manticore search test","gid":1}}'
curl -s http://127.0.0.1:9308/insert \
  -d '{"index":"testrt","id":2,"doc":{"title":"Drupal CMS","content":"Headless and decoupled architecture","gid":2}}'
curl -s http://127.0.0.1:9308/insert \
  -d '{"index":"testrt","id":3,"doc":{"title":"Search API","content":"Drupal module for unified search","gid":2}}'
```

Each insert returns `{"table":"testrt","id":N,"created":true,"result":"created","status":201}`.

**3. Run full-text searches.**

```bash
# Match "hello" — expect one hit, document #1.
curl -s http://127.0.0.1:9308/search \
  -d '{"index":"testrt","query":{"match":{"*":"hello"}}}'

# Match "drupal" — expect two hits, documents #2 and #3.
curl -s http://127.0.0.1:9308/search \
  -d '{"index":"testrt","query":{"match":{"*":"drupal"}}}'
```

Sample response (formatted for readability):

```json
{
  "took": 0,
  "timed_out": false,
  "hits": {
    "total": 2,
    "total_relation": "eq",
    "hits": [
      {"_id": 3, "_score": 1500, "_source": {"title": "Search API", "content": "Drupal module for unified search", "gid": 2}},
      {"_id": 2, "_score": 1500, "_source": {"title": "Drupal CMS", "content": "Headless and decoupled architecture", "gid": 2}}
    ]
  }
}
```

**4. Count and clean up.**

```bash
curl -s http://127.0.0.1:9308/cli -d 'SELECT COUNT(*) FROM testrt'
# +----------+
# | count(*) |
# +----------+
# | 3        |
# +----------+

curl -s http://127.0.0.1:9308/cli -d 'DROP TABLE testrt'
# Query OK, 0 rows affected
```

**5. Confirm the network boundary.**

The stack is configured to bind Manticore to `127.0.0.1` only. To verify
that the daemon is **not** reachable from outside the VPS, try connecting
through the public IP from the same host (or, more meaningfully, from any
remote machine):

```bash
curl --connect-timeout 5 http://<your-public-ip>:9308/cli -d 'SHOW STATUS'
```

Expected result:

```
curl: (7) Failed to connect to <your-public-ip> port 9308: Couldn't connect to server
```

This is the **correct** behaviour for Scenario A. If you can reach Manticore
through the public IP, your binding is wrong (likely a misconfigured port
mapping in `docker-compose.yml`) and your Manticore is open to the world
without authentication — **stop the stack immediately and fix it before
exposing the host further**.


## Connecting from Drupal

Once the stack is running, install the
[Search API Manticore](https://www.drupal.org/project/search_api_manticore)
module on your Drupal site, then add a new Search API server pointing at
this Manticore instance.

**Scenario A — Drupal and Manticore on the same VPS:**

- Backend: `Manticore Search`
- Host: `127.0.0.1`
- Port: `9308`
- HTTPS: disabled
- Authentication: none

**Scenario B — Drupal on a separate VPS:**

- Backend: `Manticore Search`
- Host: your domain (e.g. `search.example.com`)
- Port: `443`
- HTTPS: enabled
- Authentication: HTTP Basic Auth
- Username: the value of `MANTICORE_USERNAME` from your `.env`
- Password: the plaintext password whose bcrypt hash is in
  `MANTICORE_PASSWORD_HASH`

Refer to the module's documentation for the exact form field names and any
additional options.


## Operations

Common day-to-day operations for the stack. All commands are run from the
directory containing `docker-compose.yml`.

**Start the stack:**

```bash
docker compose up -d                          # Scenario A
docker compose --profile public up -d         # Scenario B (with Caddy)
```

**Stop the stack** (containers removed, data preserved):

```bash
docker compose down
```

**Restart Manticore only:**

```bash
docker compose restart manticore
```

**View logs** (live follow with `-f`):

```bash
docker compose logs -f manticore
docker compose logs -f caddy        # Scenario B only
```

**Check container health:**

```bash
docker compose ps
docker inspect manticore --format '{{json .State.Health}}' | python3 -m json.tool
```

**Open a MySQL shell inside the container** (useful for ad-hoc administration
and debugging — uses the always-present `mysql` client):

```bash
docker exec -it manticore mysql
```

From the prompt you can run any Manticore SQL: `SHOW TABLES`, `SELECT *
FROM <table>`, `OPTIMIZE`, `FLUSH RAMCHUNK`, etc.

**Upgrade Manticore** to a new minor or patch version:

1. Update the `image:` line in `docker-compose.yml` (e.g. `25.0.1` →
   `25.0.2`).
2. Pull the new image and recreate the container:

   ```bash
   docker compose pull
   docker compose up -d
   ```

3. Verify with `docker compose logs manticore --tail=20` that the new
   version is running.

**Back up your data.** The `./data` directory contains all tables. To take a
consistent snapshot, use Manticore's built-in physical backup tool:

```bash
docker exec manticore manticore-backup --backup-dir=/var/lib/manticore/backups
```

The backup is written inside the container's `/var/lib/manticore/backups`,
which maps to `./data/backups` on the host. Copy it off the VPS for
durability. For details and restore procedure, see
[Manticore's backup docs](https://manual.manticoresearch.com/Securing_and_compacting_a_table/Backup_and_restore).


## Troubleshooting

**`permission denied while trying to connect to the Docker API at
unix:///var/run/docker.sock`** — your user is not in the `docker` group. See
step 8 of [Install Docker](#install-docker-on-ubuntu-2404-lts).

**`docker compose ps` shows `(unhealthy)`** — inspect the last healthcheck
attempts:

```bash
docker inspect manticore --format '{{json .State.Health}}' | python3 -m json.tool
```

Look at the `Log` array — each entry has an `Output` field containing the
stderr/stdout of the probe command. If you see `wget: command not found` or
a network error, the container has not been recreated since the
`docker-compose.yml` was edited:

```bash
docker compose up -d --force-recreate manticore
```

**`The "MANTICORE_DOMAIN" variable is not set` warnings** when running
`docker compose` for Scenario A — make sure your `docker-compose.yml` uses
the default-expansion syntax `${MANTICORE_DOMAIN:-}` (with the trailing
`:-`), not just `${MANTICORE_DOMAIN}`. The colon-dash tells Compose to fall
back to an empty string rather than warn.

**Port 80 or 443 already in use** (Scenario B) — another web server on the
host is bound to those ports. If you have a system Nginx or Apache running,
either stop it (`sudo systemctl stop nginx`) or — better — choose a host
that does not also serve other websites for the Manticore endpoint.

**Caddy fails to obtain a Let's Encrypt certificate** — verify that
your domain's A record points to this VPS, and that port 80 is reachable
from the public internet (Let's Encrypt validates over HTTP first). Check
Caddy logs: `docker compose logs caddy --tail=50`.

**`failed to allocate memlock`** in Manticore logs — your kernel does not
allow unlimited memory locking. The stack requests `memlock=-1:-1` via
`ulimits`. If your provider's kernel disallows this, comment out the
`memlock` lines in `docker-compose.yml`; Manticore will still work, just
slightly less efficiently for very large indexes.

**Where is my data?** The `./data` directory next to `docker-compose.yml`.
It survives `docker compose down` and `docker compose up`. To start from
scratch, `docker compose down` then `rm -rf ./data` — but this destroys all
indexed content.


## License

This stack configuration is released under the MIT License.

Manticore Search and Caddy have their own licenses — see their respective
projects for details.
