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
- [Prerequisites: a sudo-capable non-root user](#prerequisites-a-sudo-capable-non-root-user)
- [Install Docker on Ubuntu 24.04 LTS](#install-docker-on-ubuntu-2404-lts)
- [Deploy the stack](#deploy-the-stack)
- [Verify the installation](#verify-the-installation)
- [Connecting from Drupal](#connecting-from-drupal)
- [Operations](#operations)
- [Embedding models for vector search](#embedding-models-for-vector-search)
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

The same setup also covers the case where you already run nginx, Apache,
or any other web server on the host: keep Manticore on `127.0.0.1` and
add a reverse-proxy block (with TLS and Basic Auth) to your existing web
server. The Manticore stack itself stays unchanged; only your web server
config grows by one location block. See the
[Scenario A deployment section](#scenario-a--single-vps) below.

**Scenario B — Dedicated Manticore VPS with public endpoint.** Drupal
runs on one server, Manticore on a **separate, dedicated** server. The
bundled Caddy reverse proxy terminates TLS (automatic Let's Encrypt
certificate) and enforces HTTP Basic Authentication in front of
Manticore's HTTP API. Manticore itself binds to `127.0.0.1` inside the
host; only Caddy is publicly reachable, on ports `80` and `443`.

This scenario **requires ports 80 and 443 to be free** on the Manticore
VPS — nothing else can be listening on them, including any existing
nginx, Apache, or other web server. Let's Encrypt's `http-01` challenge
strictly validates on port 80; there is no way around this. **Best for
medium-to-large sites (tens of thousands of documents and up) where the
Manticore VPS has no other duties.** If this VPS already serves other
websites and you cannot free ports 80/443, use the "behind your own
reverse proxy" variant of Scenario A instead.

You choose between Scenario A and Scenario B with a single Docker Compose
flag. Switching later is also possible. The "behind your own reverse proxy"
variant of Scenario A is purely a matter of your web server configuration —
the Manticore stack does not need to be changed to support it.


## Requirements

- A VPS with **Ubuntu 24.04 LTS** (other modern Linux distributions will
  work too, but commands in this README are for Ubuntu)
- **2 GB RAM minimum** for small workloads; 4 GB+ recommended for
  hundreds of thousands of documents
- **`x86_64` or `arm64`** CPU architecture
- **Docker Engine 24+** and **Docker Compose plugin v2+**
  (installation instructions below)
- For Scenario B only:
  - a **dedicated VPS** for Manticore (no other web server on it)
  - a **domain or subdomain** with an `A` record pointing to that VPS
  - ports **80** and **443** must be **free** on that VPS (not just
    open in the firewall — no other service may be listening on them).
    See diagnostics in [Deploy the stack →
    Scenario B](#scenario-b--public-https-endpoint-with-caddy)


## Prerequisites: a sudo-capable non-root user

Before installing Docker, make sure you're working as a regular Linux
user with `sudo` rights — **not** as `root`. Running services under root
is bad practice (any mistake runs with full system privileges), and the
rest of this guide is written for a non-root user who escalates with
`sudo` when needed.

If your VPS provider already gave you such a user, you can skip this
section. Common defaults:

- Hetzner Cloud, AWS: `ubuntu`, `admin`, or `root` (you must create your
  own user if it's only `root`)
- DigitalOcean: `root` only (unless you specified otherwise during
  droplet creation)
- Manual Ubuntu install: whatever you set during installation

Check your current user and confirm `sudo` works:

```bash
whoami                # should NOT print 'root'
sudo -v               # asks for your password, no error
groups                # should include 'sudo' (or 'wheel' on RHEL-likes)
```

If `whoami` prints `root`, create a new user (you'll do this only once):

```bash
# As root, pick any name you like — examples: 'admin', 'ops', 'deploy':
adduser <username>
usermod -aG sudo <username>

# Log out and reconnect as the new user.
```

SSH key setup, password policies, and other host-hardening topics are
outside the scope of this guide — your VPS provider's documentation
will cover them.

From now on, all commands in this guide assume you're logged in as this
non-root user. When `sudo` is required, the command will explicitly say
so. After installing Docker, you'll also add this user to the `docker`
group ([step 8](#install-docker-on-ubuntu-2404-lts) below) so that
`docker` and `docker compose` commands work without `sudo`.


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

The `docker` group grants its members access to the Docker daemon socket,
which is equivalent to root privileges on the host. Add the non-root user
you set up in [Prerequisites](#prerequisites-a-sudo-capable-non-root-user)
to that group so you can run `docker` and `docker compose` commands
without typing `sudo` each time:

```bash
sudo usermod -aG docker $USER
```

`$USER` is automatically your current login name. If you want to grant
access to a different user, replace `$USER` with that username. Verify
the change took effect:

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

The recommended location for a self-managed service on Linux is
`/opt/manticore/`, following the FHS convention:

```bash
sudo git clone https://github.com/dillix/manticore-docker.git /opt/manticore
sudo chown -R $USER:$USER /opt/manticore
cd /opt/manticore
```

Use the HTTPS URL for read-only deployment, or the SSH URL
(`git@github.com:dillix/manticore-docker.git`) if you plan to contribute.
The `chown` step transfers ownership to the current user so that all
subsequent `docker compose` commands can be run without `sudo` (assuming
your user is in the `docker` group, see installation step 8 above).

**2. Pre-configured server options.**

This stack enables one non-default Manticore server option:
`searchd_not_terms_only_allowed = 1`, set via the
`searchd_not_terms_only_allowed` environment variable on the `manticore`
service in `docker-compose.yml`. It allows fulltext queries containing
only negative (NOT) terms — for example, _"show me all documents that
do NOT mention `obsolete`"_ without a positive term to anchor the
search.

This option is required by the
[Search API Manticore](https://www.drupal.org/project/search_api_manticore)
Drupal module to support its negation features. If you use the stack
standalone (without the module), the option is harmless: it relaxes a
parser constraint without affecting performance.

No action is needed from you — the option is applied automatically the
first time you start the stack. If you ever edit `docker-compose.yml`
to tune server options yourself, recreate the container so the new
values take effect:

```bash
docker compose up -d --force-recreate manticore
```

Now choose your scenario:

### Scenario A — single VPS

```bash
docker compose up -d
```

On the first run Docker downloads the `manticoresearch/manticore:27.1.5`
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
manticore   manticoresearch/manticore:27.1.5   Up X seconds (healthy)  127.0.0.1:9306->9306/tcp, 127.0.0.1:9308->9308/tcp, 9312/tcp
```

Note that ports `9306` and `9308` are bound to `127.0.0.1` only — they are
not reachable from the public network. Port `9312` is the internal Sphinx
protocol port, not exposed to the host at all.

You can now point your local Drupal site at `http://127.0.0.1:9308`.

#### Exposing Manticore through your existing reverse proxy

If your Drupal site runs on a **different** server, you need a public
HTTPS endpoint for it to reach Manticore. There are two ways to do this:

1. Use the bundled Caddy reverse proxy — see
   [Scenario B](#scenario-b--public-https-endpoint-with-caddy) below.
   Best if Manticore is on a dedicated VPS with ports `80` and `443` free.

2. **Use your existing nginx** on this host — the rest of this section.
   Best if this VPS already serves other websites and ports `80`/`443`
   are taken.

The Manticore stack stays exactly as in Scenario A — bound to
`127.0.0.1:9308`, no Caddy, no public ports. Your existing nginx adds
**one extra `server` block** that terminates TLS, checks Basic Auth, and
proxies into Manticore on localhost. From Drupal's point of view the
result is identical to Scenario B.

**Step 1. Generate Basic Auth credentials.**

Install `htpasswd` if you don't have it:

```bash
sudo apt install apache2-utils
```

Create a credentials file in nginx's config directory:

```bash
sudo htpasswd -cB /etc/nginx/.htpasswd-manticore drupal
# Enter a strong password when prompted. Save it — you'll paste it
# into Drupal's Search API server form later.
```

The `-B` flag selects bcrypt (the same hash family Scenario B's Caddy
uses). `-c` creates the file. For subsequent users on the same file,
omit `-c`.

**Step 2. Add the nginx server block.**

Pick a hostname for the endpoint, for example `search.example.com`, and
ensure its DNS `A` record points to this VPS. Then create a new file
`/etc/nginx/sites-available/manticore.conf` with the following content:

```nginx
# Manticore Search reverse proxy with Basic Auth and TLS.
# Manticore itself listens on 127.0.0.1:9308 (from the Docker stack);
# this server block makes it reachable as https://search.example.com.

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name search.example.com;

    # TLS — replace with your actual certificate paths. If you don't
    # have certificates yet, see Step 3 below for certbot.
    ssl_certificate     /etc/letsencrypt/live/search.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/search.example.com/privkey.pem;

    # Modern TLS defaults. Adjust to match the rest of your sites if you
    # already have a shared snippet.
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;

    # HTTP Basic Authentication. The realm string is shown by browsers
    # in the password prompt; the user-file holds bcrypt-hashed creds.
    auth_basic           "Manticore Search";
    auth_basic_user_file /etc/nginx/.htpasswd-manticore;

    # Proxy everything into the Manticore container.
    location / {
        proxy_pass         http://127.0.0.1:9308;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;

        # Manticore responses can be large for big result sets — give the
        # proxy room to forward them without buffering to disk.
        proxy_buffering    off;
        client_max_body_size 64M;
    }

    # Strip the Authorization header before forwarding to Manticore.
    # Auth is enforced by nginx; Manticore itself has no auth and should
    # never see the credentials.
    proxy_set_header Authorization "";
}

# Plain-HTTP redirect to HTTPS. Required for browsers that hit the
# bare hostname, and for Let's Encrypt's HTTP-01 challenge.
server {
    listen 80;
    listen [::]:80;
    server_name search.example.com;
    return 301 https://$host$request_uri;
}
```

Enable the site and reload nginx:

```bash
sudo ln -s /etc/nginx/sites-available/manticore.conf \
           /etc/nginx/sites-enabled/manticore.conf
sudo nginx -t                  # validate the configuration
sudo systemctl reload nginx
```

**Step 3. (If needed) Obtain a TLS certificate.**

If your existing nginx already uses certbot for other domains:

```bash
sudo certbot --nginx -d search.example.com
```

Certbot reads the new vhost, adds the certificate paths automatically,
and reloads nginx. If you use a different ACME client (acme.sh, lego,
manual ISPmanager workflow, etc.), follow its usual procedure for adding
a new domain — there's nothing Manticore-specific.

**Step 4. Verify from outside the VPS.**

```bash
# Without credentials — expect HTTP/2 401:
curl -sI https://search.example.com/cli

# With credentials — expect Manticore status table:
curl -s -u 'drupal:your-password' https://search.example.com/cli \
     -d 'SHOW STATUS' | head -5
```

The `401` response confirms TLS and Basic Auth are active; the table
confirms Manticore is reachable through the proxy. From Drupal's
configuration page, fill in:

- **Host:** `search.example.com`
- **Port:** `443`
- **Path:** (empty)
- **Use HTTPS:** yes
- **HTTP Basic Auth username:** `drupal`
- **HTTP Basic Auth password:** the value you set in Step 1

> **Why not just bind Manticore to `0.0.0.0:9308`?**
> Manticore has no built-in authentication. Binding it to a public
> interface — even "temporarily, while I set up nginx" — exposes the
> database directly to the internet. Automated scrapers index public
> ports within seconds; databases left exposed this way are routinely
> wiped or ransom-locked. The 127.0.0.1 binding plus a reverse proxy is
> the safe pattern; never open 9308 to the public.

### Scenario B — public HTTPS endpoint with Caddy

Scenario B adds a Caddy reverse proxy in front of Manticore. Caddy obtains
a Let's Encrypt TLS certificate automatically and enforces HTTP Basic
Authentication on every request.

> **⚠ Prerequisites before you start.**
>
> - **This VPS must be dedicated to the Manticore stack.** Caddy needs
>   exclusive ownership of ports **80** and **443**, and Let's Encrypt's
>   `http-01` challenge cannot validate on a non-standard port. If this
>   VPS also runs nginx, Apache, or any other web server on those ports,
>   Caddy will fail to start.
>
> - **Verify ports 80 and 443 are free** before proceeding:
>
>   ```bash
>   sudo ss -tlnp | grep -E ':(80|443) '
>   ```
>
>   If the output is empty, you're good. If it shows another process
>   (typically `nginx` or `apache2`), either stop and disable that
>   service, move it to a different VPS, or use the
>   ["behind your own reverse proxy"](#exposing-manticore-through-your-existing-reverse-proxy)
>   variant of Scenario A instead.
>
> - **DNS must point at this VPS already.** Let's Encrypt validates
>   ownership immediately on first start; if the `A` record hasn't
>   propagated yet, certificate issuance will fail. Verify with:
>
>   ```bash
>   dig +short search.example.com @1.1.1.1
>   ```
>
>   The output should match this VPS's public IP.

All configuration is managed through the `./config` helper, a thin wrapper
around `docker compose run --rm -it config` (see [Configuration helper
reference](#configuration-helper-reference) below for the full command
list).

**1. Configure the four required `.env` values.**

The fastest path is the interactive setup wizard:

```bash
./config setup
```

It walks you through all four values in a single guided flow:

```
============================================================
  Manticore Search Docker Stack — interactive setup
============================================================

Creating .env from .env.example.

Step 1 of 4 — Domain name
The fully-qualified hostname pointing at this VPS, with a public
DNS A record. Example: search.example.com

Domain: search.example.com

Step 2 of 4 — ACME email
Email address used by Let's Encrypt for renewal notices.

Email: admin@example.com

Step 3 of 4 — HTTP Basic Auth username
Username the Drupal application will authenticate as.

Username: drupal

Step 4 of 4 — HTTP Basic Auth password
How would you like to set the password?

  1) Generate a strong random password (recommended)
  2) Enter your own password

Choice [1]: 1

============================================================
  PASSWORD (save this NOW — it will not be shown again):

      5J.vuTaj9vKvIibUSMMFVn7x

============================================================

Summary

  MANTICORE_DOMAIN       = search.example.com
  MANTICORE_ACME_EMAIL   = admin@example.com
  MANTICORE_USERNAME     = drupal
  MANTICORE_PASSWORD_HASH= $$2a$$14$$••••••••

Write these values to .env? [y/N] y

Setup complete. .env has been written.
```

**Copy the plaintext password to a password manager before answering `y`.**
It will not be shown again, and you will need it later when configuring
the Search API server in Drupal.

The domain you enter must have a public DNS `A` record pointing at this
VPS before you continue — Let's Encrypt will validate ownership by
sending an HTTP request to
`http://<your-domain>/.well-known/acme-challenge/...` within seconds of
starting Caddy.

If you chose option **2** (enter your own password), you will be prompted
twice with hidden input. The password is **never** accepted as a
command-line argument — arguments are recorded in shell history, visible
in `ps auxw` while the command runs, and may end up in SSH session logs.
For non-interactive deployment (Ansible, CI), ship a pre-populated
`.env` file via your configuration management tool instead.

<details>
<summary>Alternative: configure each value individually</summary>

If you prefer to set values one at a time (for example, to update just
one field after the initial setup), use the individual subcommands:

```bash
./config domain   search.example.com
./config email    admin@example.com
./config username drupal
./config password generate          # random password + hash
./config password change            # prompt for password interactively
```

Each command shows a preview of the planned change and asks for
confirmation. The `.env` file is created automatically from
`.env.example` the first time you run any of them.

</details>

> **Why are there `$$` in the hash?** Compose interpolates values loaded
> from `.env` when substituting them into `docker-compose.yml`. A bcrypt
> hash like `$2a$14$XXXX` would be mis-parsed: Compose would try to expand
> `$2a`, `$14`, and `$XXXX` as variable references. Doubling each `$`
> escapes the interpolation; Compose strips one `$` from each pair when
> passing the value to Caddy, which then sees the correct single-`$` hash.
> The `./config` commands handle this for you; never edit
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
| Daemon     | 27.1.5 5a1cf9399@26061911         |
| Columnar   | columnar 13.6.1 94c1040@26061507  |
| Secondary  | secondary 13.6.1 94c1040@26061507 |
| Knn        | knn 13.6.1 94c1040@26061507       |
| Embeddings | embeddings 1.1.1 94c1040@26061507 |
| Buddy      | buddy v4.0.1+26061913-64a3819f    |
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
| version                       | 27.1.5 5a1cf9399@26061911 (columnar 13.6.1 ...)            |
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

**Scenario A behind your own reverse proxy — Drupal anywhere:**

- Backend: `Manticore Search`
- Host: the hostname you configured in your nginx server block
  (e.g. `search.example.com`)
- Port: `443`
- HTTPS: enabled
- Authentication: HTTP Basic Auth
- Username: the username you passed to `htpasswd` (e.g. `drupal`)
- Password: the password you set when creating the htpasswd entry

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
docker compose down                       # Scenario A
docker compose --profile public down      # Scenario B (with Caddy)
```

> **Watch the `--profile` flag.** Compose only sees services from
> profiles you activate. Running plain `docker compose down` on a stack
> started with `--profile public` will stop and remove `manticore` but
> leave `manticore-caddy` running on its own. Always pass the same
> `--profile` flags to `down` that you passed to `up`. If you forgot
> and ended up with an orphan Caddy, just rerun with the profile:
>
> ```bash
> docker compose --profile public down
> ```

If you also want to wipe persistent data (Manticore tables, Caddy's
TLS certificates), add `-v` to remove named volumes too:

```bash
docker compose --profile public down -v
```

This is destructive — see [Where is my data?](#troubleshooting) before
running it.

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

After changing any value used by Caddy (domain, email, username, or
password), recreate the Caddy container so it picks up the new value:

```bash
docker compose --profile public up -d --force-recreate caddy
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

**Back up your data.** Manticore's data lives in the `manticore-data`
Docker named volume. To get its location on the host:

```bash
docker volume inspect manticore-docker_manticore-data --format '{{ .Mountpoint }}'
```

For a consistent application-level snapshot (preferred for production),
use Manticore's built-in backup tool:

```bash
docker exec manticore manticore-backup --backup-dir=/var/lib/manticore/backups
```

The backup is written to `/var/lib/manticore/backups` inside the
container, which is also inside the `manticore-data` volume.
See [Manticore's backup docs](https://manual.manticoresearch.com/Securing_and_compacting_a_table/Backup_and_restore)
for details and the restore procedure.

For a raw volume-level snapshot (faster, useful for whole-host backups),
archive the entire volume into a tarball via a one-shot helper container:

```bash
docker run --rm \
    -v manticore-docker_manticore-data:/data:ro \
    -v "$(pwd)":/backup \
    alpine \
    tar czf /backup/manticore-data-$(date +%F).tar.gz -C /data .
```

This produces `manticore-data-YYYY-MM-DD.tar.gz` in the current
directory. Copy it off the VPS for durability.

To restore from a tarball (stop the stack first so nothing writes
during the restore):

```bash
docker compose --profile public down
docker run --rm \
    -v manticore-docker_manticore-data:/data \
    -v "$(pwd)":/backup \
    alpine \
    sh -c "rm -rf /data/* && tar xzf /backup/manticore-data-YYYY-MM-DD.tar.gz -C /data"
docker compose --profile public up -d
```


## Embedding models for vector search

Manticore can generate text embeddings itself for vector (semantic /
more-like-this) search, used by the
[Search API Manticore](https://www.drupal.org/project/search_api_manticore)
Drupal module. The first time a table that names an embedding model is
created, the engine downloads that model from the internet and caches it
inside its data volume, under `/var/lib/manticore/.cache`. On a normal
internet-connected host this is automatic and needs no preparation.

Two situations need manual steps: a host with no outbound internet, and a
container started with no network at all.

### Pre-populate the model cache (air-gapped host)

A Manticore host with no outbound internet cannot download a model on
demand — the `CREATE TABLE` that names it fails with
`Failed to download model configuration`. Supply the cache pre-baked
instead: warm it once on a machine that does have internet, then copy it
into this host's data volume **before** the first table is created.

The model cache lives in the named volume `manticore-docker_manticore-data`
(mounted at `/var/lib/manticore` in the container), under `.cache`. On the
host it resolves to:

```bash
docker volume inspect manticore-docker_manticore-data --format '{{ .Mountpoint }}'
# e.g. /var/lib/docker/volumes/manticore-docker_manticore-data/_data
# the cache is the .cache subdirectory of that path
```

1. On an internet-connected machine running the same image, create a
   throwaway table that names the model you intend to use, so the engine
   downloads it. For example `sentence-transformers/all-MiniLM-L6-v2`
   (~88 MB) or `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2`.
2. Archive the warmed cache from that machine's volume:

   ```bash
   docker run --rm \
       -v manticore-docker_manticore-data:/data \
       -v "$(pwd)":/backup \
       alpine \
       tar czf /backup/manticore-cache.tar.gz -C /data .cache
   ```

3. Transfer `manticore-cache.tar.gz` to the air-gapped host and unpack it
   into that host's volume **before the first vector table is created**
   (with the stack stopped):

   ```bash
   docker compose down            # or: docker compose --profile public down
   docker run --rm \
       -v manticore-docker_manticore-data:/data \
       -v "$(pwd)":/backup \
       alpine \
       tar xzf /backup/manticore-cache.tar.gz -C /data
   docker compose up -d           # or: --profile public up -d
   ```

With the cache present, creating a table that names that model succeeds
offline and KNN queries work, because the engine finds the model locally
instead of trying to download it.

### Starting with no network (`--network none`)

The stock Manticore image does not start under `--network none`. Its
entrypoint derives the replication listen address from `hostname -I`,
which returns an empty string when there is no network interface; the
empty value produces an invalid `port 0` replication listen spec and
`searchd` refuses to start.

This stack does not use `--network none` (Manticore always has at least the
internal Docker network), so it is unaffected. If you nonetheless need a
fully network-isolated container, override the listen specification to drop
the replication listeners. The official image maps any `searchd_<name>`
environment variable to the corresponding `searchd` setting, so set
`searchd_listen` to an explicit non-replication spec, for example:

```yaml
    environment:
      searchd_listen: "9308:http"
```

Replication is only needed for multi-node clusters; a single isolated node
does not use it.


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
./config password change              # prompts for password interactively
```

The `generate` form prints the plaintext password once in a clearly
framed block — **save it immediately**; it is not stored anywhere on
disk in cleartext.

The `change` form prompts for the password twice (input is hidden via
`stty -echo`), with a confirmation step that re-prompts on mismatch.
The password is **never** accepted as a command-line argument because
arguments are recorded in shell history, visible in `ps auxw` during
execution, and may end up in SSH session logs. For non-interactive
deployment, ship a pre-populated `.env` via Ansible/Puppet/etc. instead.

Both commands write the bcrypt hash to `MANTICORE_PASSWORD_HASH` in
`.env` with the required `$$` escaping for Compose interpolation.

**Interactive setup wizard:**

```bash
./config setup
```

Walks you through all four values in a single guided flow — recommended
for first-time deployment. If `.env` already exists and is fully
populated, the wizard asks before overwriting. The password step lets
you choose between auto-generated and manually entered (with confirmed
input).

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

### Permission denied connecting to the Docker daemon

If you see:

```
permission denied while trying to connect to the Docker API at
unix:///var/run/docker.sock
```

— your user is not in the `docker` group. See
step 8 of [Install Docker](#install-docker-on-ubuntu-2404-lts).

### Container shows `(unhealthy)` status

`docker compose ps` reports `(unhealthy)` for `manticore`. Inspect the
last healthcheck attempts:

```bash
docker inspect manticore --format '{{json .State.Health}}' | python3 -m json.tool
```

Look at the `Log` array — each entry has an `Output` field containing
the stderr/stdout of the probe command. If you see `wget: command not
found` or a network error, the container has not been recreated since
the `docker-compose.yml` was edited:

```bash
docker compose up -d --force-recreate manticore
```

### `WARN` about an unset variable found inside a value

When running any `docker compose` command you see:

```
WARN[0000] The "xyz" variable is not set. Defaulting to a blank string.
```

— Compose is trying to interpolate a `$xyz...` substring it found inside
one of your `.env` values. This almost always means
`MANTICORE_PASSWORD_HASH` was written without the required `$$` escaping
(typically by editing `.env` by hand with single dollars). Regenerate it
using the bundled helper, which writes the value correctly:

```bash
./config password generate
```

If the stack is running, the wrapper will also recreate Caddy
automatically so it picks up the corrected value. After the fix,
`MANTICORE_PASSWORD_HASH` in `.env` should start with `$$2a$$` or
`$$2b$$` (doubled dollars), and there should be no WARN messages on
subsequent commands.

### `./config` prompts don't respond to `y` at the confirmation step

The wrapper already passes `-it` to `docker compose run`. If you're
invoking the underlying Compose service directly (without the wrapper),
make sure to pass both flags:

```bash
docker compose run --rm -it config password generate
```

Without `-it`, Compose may not allocate a TTY, and `read` silently
treats the prompt as cancelled.

### `docker compose config --services` does not list `caddy` or `config`

Services with `profiles:` are hidden from `config --services` unless the
matching profiles are explicitly active:

```bash
docker compose --profile public --profile tools config --services
```

This is documented Compose behaviour, not a bug. Helper commands like
`docker compose run --rm <service>` activate the matching profile
automatically.

### Caddy still rejects new credentials after changing `.env`

You changed the password (or username, or domain) via `./config`, but
Caddy still responds with `401 Unauthorized` to the new credentials.
This is expected — Docker container environment variables are fixed at
container creation time and are not re-read when `.env` changes. You
need to recreate the Caddy container to pick up the new value:

```bash
docker compose --profile public up -d --force-recreate caddy
```

The Manticore container does not need recreation; only Caddy depends on
the `.env` values. Verify the new value reached Caddy:

```bash
docker exec manticore-caddy printenv MANTICORE_PASSWORD_HASH
```

This must show a hash with **single** dollars (`$2a$14$...`), not double
(`$$2a$$...`). The doubling only exists in `.env` to survive Compose
interpolation; by the time the value reaches Caddy, it has been
de-doubled.

> When you use `./config` through the wrapper, this recreate happens
> automatically — the wrapper detects that `.env` changed and a Caddy
> container is running, then issues the `--force-recreate caddy` for
> you. This entry covers the case where you edited `.env` outside the
> helper (manually, via Ansible playbook, etc.), or invoked the
> in-container `config` service directly without the wrapper.

### Caddy fails to obtain a Let's Encrypt certificate

Typical causes, in rough order of likelihood:

- Your domain's `A` record does not point at this VPS, or DNS has not
  yet propagated. Verify with `dig +short search.example.com @1.1.1.1`.
- Port 80 is blocked by the host firewall or a cloud provider's network
  ACL. ACME's `http-01` challenge requires inbound 80; Caddy listens on
  it for that purpose. Check `sudo ufw status` and any provider firewall.
- Another service is already listening on port 80 (system nginx or
  Apache). Stop it (`sudo systemctl stop nginx`) or use a host that
  does not also serve other websites — see
  [Scenario B prerequisites](#scenario-b--public-https-endpoint-with-caddy).
- Let's Encrypt rate limit reached after multiple failed attempts. Wait
  one hour, fix the underlying problem (DNS, firewall), and retry.

Check Caddy's diagnostic output:

```bash
docker compose logs caddy --tail=100
```

### `failed to allocate memlock` in Manticore logs

Your kernel does not allow unlimited memory locking. The stack requests
`memlock=-1:-1` via `ulimits`. If your provider's kernel disallows this,
comment out the `memlock` lines in `docker-compose.yml`; Manticore will
still work, just slightly less efficiently for very large indexes.

### Where is my data?

Manticore's data is stored in a Docker-managed named volume called
`manticore-docker_manticore-data`, not in a folder next to
`docker-compose.yml`. The volume survives `docker compose down` and
`docker compose up`. To inspect the location on the host:

```bash
docker volume inspect manticore-docker_manticore-data --format '{{ .Mountpoint }}'
```

This typically prints something like
`/var/lib/docker/volumes/manticore-docker_manticore-data/_data` —
root-owned, so reading it requires `sudo`. For backup or restore, see
the [Operations](#operations) section above which uses helper containers
rather than direct host access.

To start from scratch and destroy all indexed content:

```bash
docker compose --profile public down -v
```

The `-v` flag tells Compose to also delete named volumes — both
Manticore's data and Caddy's TLS certificates will be gone, and a fresh
`up -d` starts with an empty Manticore and a new ACME registration.

### I forgot the Basic Auth password

The bcrypt hash in `.env` is one-way; the plaintext cannot be recovered.
Generate a new one:

```bash
./config password generate
```

The helper writes the new hash to `.env`, prints the plaintext password
once, and — if the stack is running — silently recreates Caddy so the
new credentials take effect immediately. No `down`/`up` cycle needed.
**Copy the plaintext password to a password manager before pressing
Enter to dismiss the output** — it will not be shown again.

Don't forget to update the Drupal Search API server configuration with
the new password afterwards.


## License

This stack configuration is released under the MIT License.

Manticore Search and Caddy have their own licenses — see their respective
projects for details.
