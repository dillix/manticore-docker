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
- [Configuration helper reference](#configuration-helper-reference)
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

The stack consists of a single `docker-compose.yml` describing three
services (`manticore`, `caddy`, and an on-demand `config` helper) plus a
few supporting files. Clone this repository and start the stack with one
command — minimal configuration for Scenario A, just four values for
Scenario B (all managed through the `./config` helper).

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

### Scenario A — single VPS, no public endpoint

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

Within ~30 seconds (the healthcheck `start_period`) the status changes from
`(health: starting)` to `(healthy)`:

```bash
docker compose ps
```

```
NAME        IMAGE                              STATUS                  PORTS
manticore   manticoresearch/manticore:25.0.0   Up X seconds (healthy)  127.0.0.1:9306->9306/tcp, 127.0.0.1:9308->9308/tcp, 9312/tcp
```

Note that ports `9306` and `9308` are bound to `127.0.0.1` only — they are
not reachable from the public network. Port `9312` is the internal Sphinx
protocol port, not exposed to the host at all.

You can now point your local Drupal site at `http://127.0.0.1:9308`.

### Scenario B — public HTTPS endpoint with Caddy

Scenario B adds a Caddy reverse proxy in front of Manticore. Caddy obtains
a Let's Encrypt TLS certificate automatically and enforces HTTP Basic
Authentication on every request.

All configuration is managed through the `./config` helper, a thin wrapper
around `docker compose run --rm -it config` (see [Configuration helper
reference](#configuration-helper-reference) below for the full command
list).

**1. Configure the four required `.env` values.**

You can configure each value individually:

```bash
./config domain   search.example.com
./config email    admin@example.com
./config username drupal
./config password generate
```

Each command shows a preview of the planned change and asks for
confirmation. The `.env` file is created automatically from `.env.example`
the first time you run any of them.

Replace `search.example.com`, `admin@example.com`, and `drupal` with your
own values. The domain must have a public DNS `A` record pointing at this
VPS before you continue — Let's Encrypt will validate ownership by sending
an HTTP request to `http://<your-domain>/.well-known/acme-challenge/...`
within seconds of starting Caddy.

When you run `./config password generate`, you will see output like this:

```
============================================================
  PASSWORD (save this NOW — it will not be shown again):

      5J.vuTaj9vKvIibUSMMFVn7x

============================================================


  + MANTICORE_PASSWORD_HASH=$$2a$$14$$q2ZtT2gmqTmRgPCB1jG8f.eveOC/yFa1eSJY2rpJ94fLk8otYiP52

Apply this change? [y/N] y
Updated MANTICORE_PASSWORD_HASH.
```

**Copy the plaintext password to a password manager before answering `y`.**
It will not be shown again, and you will need it later when configuring the
Search API server in Drupal.

If you prefer to use a password of your own choosing instead of a random
one, use `password change` instead:

```bash
./config password change 'your-strong-password'
```

Wrap the password in **single quotes** — characters like `$`, `!`, `&`
may be interpreted by your host shell otherwise.

> **Why are there `$$` in the hash?** Compose interpolates values loaded
> from `.env` when substituting them into `docker-compose.yml`. A bcrypt
> hash like `$2a$14$XXXX` would be mis-parsed: Compose would try to expand
> `$2a`, `$14`, and `$XXXX` as variable references. Doubling each `$`
> escapes the interpolation; Compose strips one `$` from each pair when
> passing the value to Caddy, which then sees the correct single-`$` hash.
> The `./config password` commands handle this for you; never edit
> `MANTICORE_PASSWORD_HASH` by hand.

**2. Verify `.env` is complete.**

```bash
./config show
```

You should see all four values populated, with the password hash masked
for safety:

```
Current configuration (.env)

  MANTICORE_DOMAIN       = search.example.com
  MANTICORE_ACME_EMAIL   = admin@example.com
  MANTICORE_USERNAME     = drupal
  MANTICORE_PASSWORD_HASH= $$2a$$14$$••••••••
```

**3. Start the stack with the `public` profile.**

```bash
docker compose --profile public up -d
```

Expected output:

```
[+] up 3/3
 ✔ Network manticore-docker_manticore Created
 ✔ Container manticore                Healthy
 ✔ Container manticore-caddy          Started
```

Caddy starts after Manticore reaches the `healthy` state, thanks to a
`depends_on` directive — typically about 5-7 seconds.

**4. Watch the Caddy logs while it obtains the certificate.**

```bash
docker compose logs -f caddy
```

The certificate acquisition takes 10-30 seconds. Look for these lines in
order:

```
caddy  | "msg":"using ACME account","account_contact":["mailto:admin@example.com"]
caddy  | "msg":"trying to solve challenge","identifier":"search.example.com","challenge_type":"http-01"
caddy  | "msg":"served key authentication","identifier":"search.example.com","challenge":"http-01","remote":"23.178.112.104:XXXXX"
caddy  | "msg":"served key authentication","identifier":"search.example.com","challenge":"http-01","remote":"13.62.227.138:XXXXX"
... (several more from different Let's Encrypt validation servers)
caddy  | "msg":"authorization finalized","identifier":"search.example.com","authz_status":"valid"
caddy  | "msg":"successfully downloaded available certificate chains"
caddy  | "msg":"certificate obtained successfully","identifier":"search.example.com"
```

The `served key authentication` lines come from Let's Encrypt's validation
nodes pinging your VPS from multiple regions. Five or more of them is
normal. The final `certificate obtained successfully` is the signal that
the endpoint is ready.

Press `Ctrl+C` to stop following the log; the container continues running.


## Verify the installation

Manticore exposes a simple JSON over HTTP API on port 9308. The smoke tests
below confirm the stack is fully functional in your chosen scenario.

### Scenario A — local access

Run these on the same VPS as Manticore:

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

### Scenario B — public HTTPS access

Run these from any host (the same VPS or a remote machine). Replace
`search.example.com` and the password with your own values.

**1. Without authentication — expect `401 Unauthorized`.**

```bash
curl -sI https://search.example.com/cli
```

```
HTTP/2 401
www-authenticate: Basic realm="restricted"
server: Caddy
alt-svc: h3=":443"; ma=2592000
```

`HTTP/2` (rather than `HTTP/1.1`) means TLS is correctly negotiated;
`Caddy` in the `server` header confirms the reverse proxy is handling the
request; `www-authenticate: Basic` shows the auth challenge is active.

**2. With correct credentials — expect a Manticore status table.**

```bash
curl -s -u 'drupal:your-password' https://search.example.com/cli -d 'SHOW STATUS' | head -10
```

```
+-------------------------------+------------------------------------------------------------+
| Counter                       | Value                                                      |
+-------------------------------+------------------------------------------------------------+
| uptime                        | 86                                                         |
| connections                   | 9                                                          |
| version                       | 25.0.0 ce3c27828@26032712 (columnar 13.0.0 ...)            |
...
```

**3. HTTP → HTTPS redirect.**

```bash
curl -sI http://search.example.com/cli
```

```
HTTP/1.1 308 Permanent Redirect
Location: https://search.example.com/cli
Server: Caddy
```

If all three commands behave as shown, the endpoint is production-ready
and you can configure Drupal to connect to it.

**4. (Optional) Verify the certificate chain.**

```bash
echo | openssl s_client -connect search.example.com:443 -servername search.example.com 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```

You should see Let's Encrypt as the issuer and your domain as the subject:

```
issuer=C=US, O=Let's Encrypt, CN=R10
subject=CN=search.example.com
notBefore=May 16 14:00:00 2026 GMT
notAfter=Aug 14 14:00:00 2026 GMT
```

Caddy will renew this certificate automatically when ~30 days remain
before expiry.


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

**Manage configuration** (`.env` values):

```bash
./config show                         # see current settings
./config password generate            # rotate the Basic Auth password
./config domain   search.new.com      # change domain (will need to re-issue cert)
```

See [Configuration helper reference](#configuration-helper-reference)
for the full list of subcommands.

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


## Configuration helper reference

The `./config` wrapper provides a single entrypoint for managing the
`.env` file. Every subcommand validates input, shows a diff of the
planned change, asks for confirmation, and restores host file ownership
afterwards. The actual logic lives in `bin/config.sh`; the wrapper just
forwards arguments to `docker compose run --rm -it config <args>` with
the right Compose flags.

**Inspect current configuration:**

```bash
./config show
```

Displays all four `.env` values; the password hash is masked.

**Set domain, email, or username:**

```bash
./config domain   search.example.com
./config email    admin@example.com
./config username drupal
```

Each command validates its argument:

- **Domain:** must be a valid hostname (lowercase letters, digits,
  hyphens, dots) — no protocol prefix, no slashes, no spaces.
- **Email:** standard local-part `@` domain `.` TLD form.
- **Username:** 1–32 characters, ASCII letters/digits/underscore/hyphen
  only.

Invalid input is rejected without changing `.env`. If the new value is
identical to the current one, the command reports `No change` and exits.

**Manage the Basic Auth password:**

```bash
./config password generate            # random 24-char password + hash
./config password change 'my-pwd'     # hash a specific password
```

The `generate` form prints the plaintext password once in a clearly
framed block — **save it immediately**; it is not stored anywhere on
disk in cleartext. Both commands write the bcrypt hash to
`MANTICORE_PASSWORD_HASH` in `.env` with the required `$$` escaping for
Compose interpolation.

Always wrap the password in **single quotes** when using `change` —
characters like `$`, `!`, `&` are interpreted by the host shell
otherwise.

**Interactive setup wizard:**

```bash
./config setup
```

Walks you through all four values in a single guided flow — useful for
first-time deployment. _(Coming soon — currently shows a stub message.)_

**Help:**

```bash
./config help
```

**Wrapper not executable on a fresh clone?**

The `./config` wrapper has its executable bit recorded in git (mode
`100755`), so `git clone` on Linux and macOS leaves it executable. On
Windows under WSL, or after some `git apply`/`git format-patch` round
trips, the bit may be lost. Restore it:

```bash
chmod +x ./config
```

If you intend to commit and push this fix back, also tell git:

```bash
git update-index --chmod=+x ./config
```


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

**`WARN[0000] The "xyz" variable is not set. Defaulting to a blank string`**
when running any `docker compose` command — Compose is trying to interpolate
a `$xyz...` substring it found inside one of your `.env` values. This
almost always means `MANTICORE_PASSWORD_HASH` was written without the
required `$$` escaping. Regenerate it using the bundled helper:

```bash
docker compose --profile public down
./config password generate
docker compose --profile public up -d
```

After the fix, `MANTICORE_PASSWORD_HASH` in `.env` should start with
`$$2a$$` or `$$2b$$` (doubled dollars), and there should be no WARN
messages on subsequent commands.

**`./config` prompts don't respond to `y` at the confirmation prompt** —
the wrapper already passes `-it` to `docker compose run`. If you're
invoking the underlying compose service directly (without the wrapper),
make sure to pass both flags:

```bash
docker compose run --rm -it config password generate
```

Without `-it`, Compose may not allocate a TTY, and `read` silently treats
the prompt as cancelled.

**`docker compose config --services` does not list `caddy` or `config`**
— these services have `profiles:` and are hidden from `config --services`
unless the matching profiles are explicitly active:

```bash
docker compose --profile public --profile tools config --services
```

This is documented Compose behaviour, not a bug. Helper commands like
`docker compose run --rm <service>` activate the matching profile
automatically.

**Caddy fails to obtain a Let's Encrypt certificate** — typical causes:

- Your domain's `A` record does not point at this VPS, or DNS has not yet
  propagated. Verify with `dig +short search.example.com @1.1.1.1`.
- Port 80 is blocked by the host firewall or a cloud provider's network
  ACL. ACME's `http-01` challenge requires inbound 80; Caddy listens on
  it for that purpose. Check `sudo ufw status` and any provider firewall.
- Another service is already listening on port 80 (system Nginx or
  Apache). Stop it (`sudo systemctl stop nginx`) or use a host that does
  not also serve websites for the Manticore endpoint.
- Let's Encrypt rate limit reached after multiple failed attempts. Wait
  one hour, fix the underlying problem (DNS, firewall), and retry.

Check Caddy's diagnostic output:

```bash
docker compose logs caddy --tail=100
```

**`failed to allocate memlock`** in Manticore logs — your kernel does not
allow unlimited memory locking. The stack requests `memlock=-1:-1` via
`ulimits`. If your provider's kernel disallows this, comment out the
`memlock` lines in `docker-compose.yml`; Manticore will still work, just
slightly less efficiently for very large indexes.

**Where is my data?** The `./data` directory next to `docker-compose.yml`.
It survives `docker compose down` and `docker compose up`. To start from
scratch, `docker compose down` then `rm -rf ./data` — but this destroys all
indexed content.

**I forgot the Basic Auth password.** The bcrypt hash in `.env` is
one-way; the plaintext cannot be recovered. Generate a new one:

```bash
docker compose --profile public down
./config password generate
docker compose --profile public up -d
```

Don't forget to update the Drupal Search API server configuration with the
new password afterwards.


## License

This stack configuration is released under the MIT License.

Manticore Search and Caddy have their own licenses — see their respective
projects for details.
