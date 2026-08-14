# Manticore Search Docker Stack

A production-ready Docker Compose stack for running [Manticore Search](https://manticoresearch.com/)
behind a [Caddy](https://caddyserver.com/) reverse proxy with automatic HTTPS.

Designed to be deployed by a webmaster on a VPS in under ten minutes, with no
prior DevOps experience. The stack is the recommended way to run a Manticore
server for use with the
[Search API Manticore](https://www.drupal.org/project/search_api_manticore)
Drupal module, but it is generic — any HTTP client can talk to it.

- **Manticore Search 27.1.5** — authentication is enforced by the engine
  itself, on both the HTTP and MySQL protocols, with users, passwords, bearer
  tokens and per-action grants
- **Caddy 2.11.4** — automatic Let's Encrypt TLS certificates. It terminates
  TLS and forwards the `Authorization` header untouched; it holds no
  credentials and checks none
- **Production defaults** — memory locking, raised ulimits, persistent volume,
  healthcheck, automatic restart


## Table of contents

- [Deployment scenarios](#deployment-scenarios)
- [Requirements](#requirements)
- [Prerequisites: a sudo-capable non-root user](#prerequisites-a-sudo-capable-non-root-user)
- [Install Docker on Ubuntu 24.04 LTS](#install-docker-on-ubuntu-2404-lts)
- [Deploy the stack](#deploy-the-stack)
- [Upgrading from 1.0.0](#upgrading-from-100)
- [Verify the installation](#verify-the-installation)
- [Authentication and the permission model](#authentication-and-the-permission-model)
- [Connecting from Drupal](#connecting-from-drupal)
- [Operations](#operations)
- [Embedding models for vector search](#embedding-models-for-vector-search)
- [Morphology and lemmatization](#morphology-and-lemmatization)
- [Configuration helper reference](#configuration-helper-reference)
- [Troubleshooting](#troubleshooting)
- [License](#license)


## Deployment scenarios

There are two supported scenarios. Both use the same `docker-compose.yml`;
the difference is whether the Caddy reverse proxy is enabled and how Manticore
ports are exposed.

**Scenario A — Single VPS.** Drupal and Manticore live on the same server.
Manticore listens only on `127.0.0.1` and is reachable from the local Drupal
installation as `http://127.0.0.1:9308`. TLS is not needed because the port is
not exposed to the network, but **credentials are** — the engine authenticates
every request in every deployment. Best for small blogs and wikis
(≈ 1k–5k nodes) running on a single host.

The same setup also covers the case where you already run nginx, Apache,
or any other web server on the host: keep Manticore on `127.0.0.1` and
add a reverse-proxy block (with TLS) to your existing web server. That
proxy must **not** authenticate and must **not** strip the `Authorization`
header — the engine checks credentials itself. The Manticore stack stays
unchanged; only your web server config grows by one server block. See the
[Scenario A deployment section](#scenario-a--single-vps) below.

**Scenario B — Dedicated Manticore VPS with public endpoint.** Drupal
runs on one server, Manticore on a **separate, dedicated** server. The
bundled Caddy reverse proxy terminates TLS (automatic Let's Encrypt
certificate) in front of Manticore's HTTP API, and forwards the
`Authorization` header through untouched so the engine can authenticate.
Manticore itself binds to `127.0.0.1` inside the host; only Caddy is
publicly reachable, on ports `80` and `443`.

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
  hundreds of thousands of documents. If you use vector search, size for the
  embedding model instead: loading one peaks at around **1.6 GB** on its own,
  which makes a 2 GB host marginal. See
  [Embedding models for vector search](#embedding-models-for-vector-search)
- **`x86_64` or `arm64`** CPU architecture
- **Docker Engine 20.10+** and **Docker Compose plugin v2.1.1+**
  (installation instructions below). The binding constraint is Compose rather
  than the Engine, because `./config setup` runs
  `docker compose up -d --wait`
- For Scenario B only:
  - a **dedicated VPS** for Manticore (no other web server on it)
  - a **domain or subdomain** with an `A` record pointing to that VPS
  - ports **80** and **443** must be **free** on that VPS (not just
    open in the firewall — no other service may be listening on them).
    See diagnostics in [Deploy the stack →
    Scenario B](#scenario-b--public-https-endpoint-with-caddy)

> **Why not a newer Docker?** The Compose healthcheck deliberately does not use
> `start_interval`, so there is **no Engine 25 requirement**. The healthcheck
> block rejects unknown keys outright, so shipping a newer key would be a hard
> validation failure on an older Compose — the stack would refuse to start at
> all — rather than a graceful degrade. On Engine 25 and later the first health
> probe simply lands sooner.


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
few supporting files. Clone this repository, start the stack, and run the
setup wizard, which creates the engine credentials both scenarios need.

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

This stack enables two non-default Manticore server options, both set via
environment variables on the `manticore` service in `docker-compose.yml`.

`searchd_not_terms_only_allowed = 1` allows fulltext queries containing
only negative (NOT) terms — for example, _"show me all documents that
do NOT mention `obsolete`"_ without a positive term to anchor the
search. This option is required by the
[Search API Manticore](https://www.drupal.org/project/search_api_manticore)
Drupal module to support its negation features. If you use the stack
standalone (without the module), the option is harmless: it relaxes a
parser constraint without affecting performance.

`searchd_auth = 1` turns on the engine's built-in authentication. Every
request on both the HTTP and MySQL protocols then needs credentials — a
username and password, or a bearer token. Until you run `./config setup`
the daemon has no accounts at all and answers **every** request with
HTTP 401; tables load and are intact, they are simply inaccessible.

No action is needed from you — both options are applied automatically the
first time you start the stack. If you ever edit `docker-compose.yml`
to tune server options yourself, recreate the container so the new
values take effect:

```bash
docker compose up -d --force-recreate manticore
```

Now choose your scenario:

### Scenario A — single VPS

**1. Start the stack.**

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

`(healthy)` here means the daemon is alive and serving, not that it is
configured. The healthcheck probes anonymously and deliberately accepts the
HTTP 401 that an unauthenticated request gets, because until the wizard has
run there is no account it could authenticate as.

**2. Create the credentials.**

The daemon is running but has no accounts yet, so it answers every request
with HTTP 401. Run the setup wizard to bootstrap the engine's admin and
create the user your Drupal site will authenticate as:

```bash
./config setup
```

Its first question is which scenario you are deploying. Answer **A** and it
asks two more — an ACME email and the application username — for three in
total. It does **not** ask for a domain: there is no Caddy here to serve
one, so it writes `MANTICORE_DOMAIN=localhost` itself.

That value is deliberate rather than a stand-in for "unset". If
`--profile public` is ever started on this host by mistake, a local hostname
makes Caddy issue a self-signed certificate from its internal CA and stay
quiet; a hostname that does not resolve would instead send it into repeated
Let's Encrypt attempts against a domain that can never validate.

The ACME email is still asked for, even though nothing in Scenario A reads
it: with a local hostname Caddy uses its internal CA and never contacts
Let's Encrypt, but its `tls` directive needs an argument to parse at all, so
the value cannot be empty. The wizard offers a default; if you accept the
`.env.example` placeholder it says so on screen rather than writing an
invented address you would find months later with no way to account for it.

The wizard prints the application user's password **once** at the end. Save
it immediately — it is not stored in `.env` or anywhere else in this
repository.

[Scenario B](#scenario-b--public-https-endpoint-with-caddy) below carries a
full annotated transcript, but it is **Scenario B's** transcript: four
questions, and instructions about DNS, certificates and `--profile public`
that do not apply here. What a Scenario A run does differently:

- there is no domain question, so the steps read "of 3" rather than "of 4";
- the ACME email question is worded for a deployment that never uses it, and
  offers the `.env.example` placeholder as its default instead of stripping
  it out the way Scenario B does;
- the closing "Next steps" block is local-only — testing against
  `http://127.0.0.1:9308` and putting the credential into Drupal. No DNS
  record, no certificate to wait for, no public profile.

You can now point your local Drupal site at `http://127.0.0.1:9308`, using
that username and password. The endpoint requires them — requests without
credentials return HTTP 401.

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
**one extra `server` block** that terminates TLS and proxies into
Manticore on `127.0.0.1`. From Drupal's point of view the result is
identical to Scenario B.

> **Your proxy must not authenticate.** The engine checks credentials
> itself, so the proxy's only jobs are TLS and forwarding. Do **not** add
> `auth_basic` in front of Manticore: nginx would validate the Drupal
> module's credential against its own user file and reject it at the
> proxy, before the engine ever saw it. Do **not** strip or rewrite the
> `Authorization` header either — that credential is precisely what the
> engine needs. nginx forwards `Authorization` to the upstream by default,
> so the correct configuration is simply to leave it alone.

**Step 1. Add the nginx server block.**

Pick a hostname for the endpoint, for example `search.example.com`, and
ensure its DNS `A` record points to this VPS. Then create a new file
`/etc/nginx/sites-available/manticore.conf` with the following content:

```nginx
# Manticore Search reverse proxy: TLS termination only.
# Manticore itself listens on 127.0.0.1:9308 (from the Docker stack);
# this server block makes it reachable as https://search.example.com.
# Authentication is enforced by the Manticore engine, not here.

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

    # No auth_basic here — the engine authenticates. Adding one would
    # reject the application's credential at the proxy.

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

        # The Authorization header is deliberately NOT touched. nginx
        # forwards it to the upstream by default, and the engine needs
        # it to authenticate the request. Never clear it here.
    }
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

**Step 2. (If needed) Obtain a TLS certificate.**

If your existing nginx already uses certbot for other domains:

```bash
sudo certbot --nginx -d search.example.com
```

Certbot reads the new vhost, adds the certificate paths automatically,
and reloads nginx. If you use a different ACME client (acme.sh, lego,
manual ISPmanager workflow, etc.), follow its usual procedure for adding
a new domain — there's nothing Manticore-specific.

**Step 3. Create the engine credentials.**

If you have not already done so, run the setup wizard on the Manticore
host. It creates the user your Drupal site authenticates as and prints its
password once:

```bash
./config setup
```

Answer **A** at the scenario question. The public domain here is served by
your own nginx, not by the bundled Caddy, so the stack is still Scenario A
and the wizard has no use for the hostname — put it in the nginx `server`
block above, not in `.env`.

**Step 4. Verify from outside the VPS.**

```bash
# Without credentials — expect HTTP/2 401:
curl -sI https://search.example.com/cli

# With credentials — expect Manticore status table:
curl -s -u 'drupal:your-password' https://search.example.com/cli \
     -d 'SHOW STATUS' | head -5
```

The `401` is returned by Manticore itself and forwarded by nginx; it
confirms both that TLS works and that the engine is enforcing
authentication. The table confirms Manticore is reachable through the
proxy and that the credential is accepted. From Drupal's configuration
page, fill in:

- **Host:** `search.example.com`
- **Port:** `443`
- **Path:** (empty)
- **Use HTTPS:** yes
- **HTTP Basic Auth username:** the value of `MANTICORE_USERNAME`
- **HTTP Basic Auth password:** the password the wizard displayed

> **Why not just bind Manticore to `0.0.0.0:9308`?**
> The engine does authenticate, so this is no longer the only barrier —
> but a public port is still worth avoiding. It invites credential
> stuffing against a service with no rate limiting or lockout of its own,
> and it removes a layer for free. Automated scanners index public ports
> within seconds. The 127.0.0.1 binding plus a reverse proxy that
> terminates TLS remains the safe pattern; never open 9308 to the public.

### Scenario B — public HTTPS endpoint with Caddy

Scenario B adds a Caddy reverse proxy in front of Manticore. Caddy obtains
a Let's Encrypt TLS certificate automatically, terminates TLS, and forwards
requests to the engine with the `Authorization` header untouched. It holds
no credentials of its own — the engine authenticates every request.

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

**1. Run the setup wizard.**

The wizard asks which scenario you are deploying, collects the values that
scenario actually uses, bootstraps the engine's admin, creates the
application user, and shows you that user's password once:

```bash
./config setup
```

In Scenario B that is four questions — the scenario, a domain, an ACME email
and the application username — and then it provisions the engine:

```
============================================================
  Manticore Search Docker Stack — interactive setup
============================================================

Creating .env from .env.example.

Step 1 — Deployment scenario
A — single VPS. Manticore listens on 127.0.0.1 only, for a Drupal
    site on this same host (or your own reverse proxy in front).
    No Caddy, no public port, no domain needed.
B — dedicated Manticore VPS with the bundled Caddy reverse proxy,
    started with '--profile public'. Caddy terminates TLS on a
    public domain and obtains a Let's Encrypt certificate.

Scenario (A or B): B

Scenario B — 4 steps in total.

Step 2 of 4 — Domain name
The fully-qualified hostname pointing at this VPS, with a public
DNS A record. Example: search.example.com
Rules: lowercase letters, digits, hyphens and dots only.

Domain: search.example.com

Step 3 of 4 — ACME email
Email address used by Let's Encrypt for renewal notices.
Rules: standard email form, e.g. admin@example.com.

Email: admin@example.com

Step 4 of 4 — Application username
The engine user the Drupal site will authenticate as. It will be
created with exactly the grants the module needs, and a password
shown to you once at the end.
Rules: 1-32 characters, ASCII letters/digits/underscore/hyphen.

Username [drupal]: drupal

Summary

  MANTICORE_SCENARIO   = B — bundled Caddy on a public domain
  MANTICORE_DOMAIN     = search.example.com
  MANTICORE_ACME_EMAIL = admin@example.com
  MANTICORE_USERNAME   = drupal

Next, the engine's admin is bootstrapped and the user above is
created. Nothing has been changed yet.

Write these values to .env and continue? [y/N] y

.env written.
```

The username offers `drupal` as a default; in Scenario B the domain and email
do not offer one, because the placeholders in `.env.example` cannot work
anywhere and offering them would only invite a broken deployment. (Scenario A
is the exception for the email: nothing reads it there, so the placeholder is
offered and its use announced.)

On a re-run, the scenario question offers whatever `MANTICORE_SCENARIO`
already records as its default, so you answer it once and press Enter
thereafter.

Nothing has touched the engine up to this point — aborting here leaves it
exactly as it was. After you answer `y`, the wizard starts the daemon if it
is not already running, bootstraps the admin account, and provisions the
application user:

```
Starting the manticore service and waiting for it to report healthy.
This is usually a few seconds, but can take up to 30 on the first
start or on older Docker versions.

Bootstrapping the engine's admin account...
Issuing the admin token...
Admin configured; MANTICORE_ADMIN_TOKEN written to .env.

Application user

Created engine user 'drupal'.

Grants for 'drupal':
  grant read: granted
  grant write: granted
  grant schema: granted

Checking that the engine executes queries...
Admin credential works.
```

Finally — and this is the part worth reading — the wizard checks the
application credential **the way Drupal will use it**: over HTTP Basic,
against a scratch table it creates and drops. It reports each grant
separately:

```
Verifying the application credential (drupal) over HTTP Basic...
  index a document (/bulk): OK (grant 'write')
  search (/search): OK (grant 'read')
  availability probe (SHOW STATUS): OK (grant 'schema')

Setup complete.

============================================================
  PASSWORD for 'drupal' (save this NOW — shown only once):

      5J.vuTaj9vKvIibUSMMFVn7x

============================================================

It is not stored in .env, or anywhere else in this repo.
Put it straight into the Drupal Key entity your Search API
server uses, alongside the username 'drupal'.
```

Indexing runs before the search probe so that the read probe has something
to find. A failing probe prints `FAILED (grant '<name>')` together with the
daemon's own error, and the password is still shown afterwards — you will
need it either way.

> **Two similar-looking blocks.** The `grant read: granted` lines report
> what was **provisioned**; the `search (/search): OK (grant 'read')` lines
> report what was **verified** against the live credential. They are
> different checks, and only the second proves the credential works.

**Copy the password to a password manager now.** It is not stored in `.env`
or anywhere else in this repository, it will not be shown again, and you
will need it when configuring the Search API server in Drupal. If you lose
it, issue a new one with `./config password change`.

The domain you enter must have a public DNS `A` record pointing at this
VPS before you continue — Let's Encrypt will validate ownership by
sending an HTTP request to
`http://<your-domain>/.well-known/acme-challenge/...` within seconds of
starting Caddy.

The wizard always generates the application password itself. If you would
rather choose one, run `./config password change` afterwards and pick
option **2**; you will be prompted twice with hidden input. A password is
**never** accepted as a command-line argument — arguments are recorded in
shell history, visible in `ps auxw` while the command runs, and may end up
in SSH session logs.

<details>
<summary>Alternative: configure each value individually</summary>

If you prefer to set values one at a time (for example, to update just
one field after the initial setup), use the individual subcommands:

```bash
./config domain   search.example.com
./config email    admin@example.com
./config username drupal            # creates the user in the engine
./config password change            # new password for the application user
```

Each command shows a preview of the planned change and asks for
confirmation. The `.env` file is created automatically from
`.env.example` the first time you run any of them.

Note that these do not replace `./config setup` on a fresh install: the
engine's admin has to be bootstrapped before any of them can talk to it.

</details>

**2. Verify the configuration.**

```bash
./config show
```

This prints the `.env` values — with the admin token masked — followed by
the engine's own users and their grants:

```
Current configuration (.env)

  MANTICORE_SCENARIO     = B — bundled Caddy on a public domain
  MANTICORE_DOMAIN       = search.example.com
  MANTICORE_ACME_EMAIL   = admin@example.com
  MANTICORE_USERNAME     = drupal
  MANTICORE_ADMIN_TOKEN  = a1b2c3...

  The application user's password is not stored here.
  Issue a new one with './config password change'.

Engine users and grants

  admin
      read on *
      write on *
      schema on *
      replication on *
      admin on *
  drupal
      read on *
      write on *
      schema on *

  Internal (system.*) accounts are deliberately not listed.
```

The contrast is the point: the admin holds all five grants, and the
application user deliberately holds three of them. See
[Authentication and the permission model](#authentication-and-the-permission-model)
for why those three and no others.

**3. Start the stack with the `public` profile.**

The wizard already started the `manticore` service in order to bootstrap it,
but it does not start Caddy on a fresh install. Bring up the full stack:

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

If Caddy was **already running** when you ran the wizard — for example when
re-running it to change the domain — you do not need this step: the wrapper
recreates Caddy for you as the wizard exits, so it picks up the new values.

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


## Upgrading from 1.0.0

In 1.0.0 authentication was enforced by the Caddy reverse proxy, using a
bcrypt hash in `.env`. In 2.0.0 the Manticore engine authenticates itself, on
both protocols, in **both** scenarios. Caddy keeps doing TLS and nothing
else.

**Indexed data is not affected.** Enabling authentication over a populated
volume loads every table normally, and credentials survive a container
recreate.

The upgrade is the same command in both scenarios:

```bash
git pull
docker compose up -d manticore     # recreates it with searchd_auth=1
./config setup
```

Run them in that order: the admin bootstrap is a local `searchd` call, so it
needs a running daemon. (`./config setup` will start the daemon itself if you
forget, so this is belt-and-braces rather than strictly required — but the
explicit `up -d` is what recreates the container with the new setting.)

For Scenario B, finish by recreating Caddy so it picks up the new Caddyfile:

```bash
docker compose --profile public up -d --force-recreate caddy
```

If Caddy was already running when you ran the wizard, `./config` does this
for you as the wizard exits.

The wizard detects which upgrade you are in the middle of and prints the
matching notice before it changes anything.

### Scenario B — you had Caddy Basic Auth

- `MANTICORE_PASSWORD_HASH` is dead. Nothing reads it, and the wizard removes
  it from `.env`.
- The application user is created **in the engine**, with a new password
  shown to you once.
- On the Drupal side the connector keeps exactly the same shape — URL,
  username, and a Key entity holding the password. **Only the value inside
  the Key entity changes.** No code change is required.

### Scenario A — you had no credentials at all

This is the one that can surprise you. Scenario A had no authentication in
1.0.0, and now has it.

- Requests that used to succeed anonymously now return **HTTP 401**.
- Your Drupal connector needs a username and a Key entity holding a password
  **for the first time**.
- Anything else pointed at `127.0.0.1:9308` — scripts, cron jobs, monitoring
  — needs credentials too.

If your reverse proxy strips the `Authorization` header, requests will fail
with 401 no matter what credentials you supply; see
[Every request returns 401 despite correct credentials](#every-request-returns-401-despite-correct-credentials).


## Verify the installation

Manticore exposes a simple JSON over HTTP API on port 9308. The smoke tests
below confirm the stack is fully functional in your chosen scenario.

### Scenario A — local access

Run these on the same VPS as Manticore. Every request needs credentials —
the engine authenticates on the loopback interface exactly as it does
through a proxy. Substitute the username from `.env` and the password the
wizard displayed:

```bash
export MC_AUTH='drupal:your-password'
```

**1. Server status and version.**

```bash
curl -s -u "$MC_AUTH" http://127.0.0.1:9308/cli -d 'SHOW VERSION'
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
curl -s -u "$MC_AUTH" http://127.0.0.1:9308/cli \
  -d 'CREATE TABLE testrt (title text, content text, gid integer)'

# Insert three documents.
curl -s -u "$MC_AUTH" http://127.0.0.1:9308/insert \
  -d '{"index":"testrt","id":1,"doc":{"title":"Hello world","content":"Manticore search test","gid":1}}'
curl -s -u "$MC_AUTH" http://127.0.0.1:9308/insert \
  -d '{"index":"testrt","id":2,"doc":{"title":"Drupal CMS","content":"Headless and decoupled architecture","gid":2}}'
curl -s -u "$MC_AUTH" http://127.0.0.1:9308/insert \
  -d '{"index":"testrt","id":3,"doc":{"title":"Search API","content":"Drupal module for unified search","gid":2}}'
```

Each insert returns `{"table":"testrt","id":N,"created":true,"result":"created","status":201}`.

**3. Run full-text searches.**

```bash
# Match "hello" — expect one hit, document #1.
curl -s -u "$MC_AUTH" http://127.0.0.1:9308/search \
  -d '{"index":"testrt","query":{"match":{"*":"hello"}}}'

# Match "drupal" — expect two hits, documents #2 and #3.
curl -s -u "$MC_AUTH" http://127.0.0.1:9308/search \
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
curl -s -u "$MC_AUTH" http://127.0.0.1:9308/cli -d 'SELECT COUNT(*) FROM testrt'
# +----------+
# | count(*) |
# +----------+
# | 3        |
# +----------+

curl -s -u "$MC_AUTH" http://127.0.0.1:9308/cli -d 'DROP TABLE testrt'
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
through the public IP, your binding is wrong — likely a misconfigured port
mapping in `docker-compose.yml`. The engine will still demand credentials,
so this is not an immediate breach the way it was before authentication
moved into the daemon, but it exposes the service to anyone who wants to
guess at them. **Fix it before exposing the host further.**

### Scenario B — public HTTPS access

Run these from any host (the same VPS or a remote machine). Replace
`search.example.com` and the password with your own values.

**1. Without authentication — expect `401 Unauthorized`.**

```bash
curl -sI https://search.example.com/cli
```

```
HTTP/2 401
www-authenticate: Basic realm="Manticore daemon", charset="UTF-8"
server: Caddy
alt-svc: h3=":443"; ma=2592000
```

`HTTP/2` (rather than `HTTP/1.1`) means TLS is correctly negotiated, and
`Caddy` in the `server` header confirms the reverse proxy is handling the
request. The `www-authenticate` challenge is **Manticore's own** — the realm
`Manticore daemon` is emitted by the engine and passed back through Caddy
untouched. Seeing it proves the whole chain: TLS terminated at the proxy,
the request forwarded to the daemon, and the daemon enforcing
authentication.

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


## Authentication and the permission model

Manticore 27.1.5 authenticates natively, on both the HTTP and MySQL
protocols. A reverse proxy in front of it — the bundled Caddy, or your own
nginx — terminates TLS and forwards the `Authorization` header; it holds no
credentials and checks none.

### Two credentials, deliberately different in kind

| | Application user | Admin token |
|---|---|---|
| Where it lives | a Drupal Key entity | `MANTICORE_ADMIN_TOKEN` in `.env` |
| Form | username + password, sent as HTTP Basic | bearer token |
| Scope | `read`, `write`, `schema` | root-equivalent for the engine |
| Used by | the Drupal module | `./config` |
| Rotate with | `./config password change` | `./config token rotate` |

The application user's password is generated by the wizard, **displayed
once, and stored nowhere in this repository**. The admin token is written to
`.env`, which `./config` forces to mode `600` whenever it writes to it.

The admin password itself is never stored at all — it exists only during the
bootstrap and is discarded. That is why a lost admin token cannot be
recovered, only reset; see
[I lost the admin token](#i-lost-the-admin-token).

### Why the application user gets exactly three grants

The wizard issues these and nothing else:

```sql
GRANT read ON * TO 'drupal';
GRANT write ON * TO 'drupal';
GRANT schema ON * TO 'drupal';
```

Each one is forced by something specific the Drupal module does:

- **`read`** — `POST /search`. Also covers `DESCRIBE` and
  `SHOW CREATE TABLE`.
- **`write`** — `POST /bulk`, which is how the module indexes. **`TRUNCATE
  TABLE` also lives under `write`**, not under `schema`, so a user with
  `write` but no `schema` can still empty an index — which is what Search
  API's "clear index" does.
- **`schema`** — `CREATE`, `DROP` and `ALTER TABLE`, and **`SHOW STATUS`**.

`schema` is the one that surprises people. `SHOW STATUS` is the module's
availability probe, so a search-only site still needs it: without `schema`
the module reports the backend as **down** while search and indexing in fact
work perfectly.

**`admin` and `replication` are never granted.** The admin account holds all
five, which is why `./config show` lists it with more than the application
user.

Grants attach to the *user*, not to the credential, so they are unaffected by
how the user authenticates.

> **A note on tokens.** `CREATE USER` mints a bearer token for the new user
> whether or not one is asked for, so the application user has one from the
> moment it exists. The wizard deliberately discards it: the Drupal module
> can only send HTTP Basic today, so a token it cannot use is a credential
> with nowhere safe to live.


## Connecting from Drupal

Once the stack is running, install the
[Search API Manticore](https://www.drupal.org/project/search_api_manticore)
module on your Drupal site, then add a new Search API server pointing at
this Manticore instance.

The connector takes the same three things in every deployment: a URL, a
username, and a Key entity holding the password. Only the host, port and
TLS setting differ between scenarios.

**Scenario A — Drupal and Manticore on the same VPS:**

- Backend: `Manticore Search`
- Host: `127.0.0.1`
- Port: `9308`
- HTTPS: disabled
- Authentication: HTTP Basic Auth
- Username: the value of `MANTICORE_USERNAME` from your `.env`
- Password: the password the wizard displayed, held in a Key entity

**Scenario B — Drupal on a separate VPS:**

- Backend: `Manticore Search`
- Host: your domain (e.g. `search.example.com`)
- Port: `443`
- HTTPS: enabled
- Authentication: HTTP Basic Auth
- Username: the value of `MANTICORE_USERNAME` from your `.env`
- Password: the password the wizard displayed, held in a Key entity

**Scenario A behind your own reverse proxy — Drupal anywhere:**

- Backend: `Manticore Search`
- Host: the hostname you configured in your nginx server block
  (e.g. `search.example.com`)
- Port: `443`
- HTTPS: enabled
- Authentication: HTTP Basic Auth
- Username: the value of `MANTICORE_USERNAME` from your `.env`
- Password: the password the wizard displayed, held in a Key entity

The credential is the same in all three cases because it is checked in the
same place in all three cases — the engine. The proxy, where there is one,
only forwards it.

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
docker exec -it manticore mysql -u drupal -p
```

The MySQL protocol is authenticated as well as the HTTP one, so log in as a
user the engine knows and enter its password at the prompt. From there you
can run any Manticore SQL: `SHOW TABLES`, `SELECT * FROM <table>`,
`OPTIMIZE`, `FLUSH RAMCHUNK`, etc., subject to that user's grants.

A wrong password is refused like this:

```
ERROR 1045 (42000): Access denied for user 'drupal' (using password: YES)
```

The application user holds `read`, `write` and `schema` but not `admin`, so
administrative statements are refused too — and this is the part worth
noting, because it returns the **same error number**:

```
ERROR 1045 (42000) at line 1: Permission denied for user 'drupal'
```

Over the MySQL protocol, `ERROR 1045` therefore cannot tell you whether the
credential is wrong or the grant is missing. Only the message text
distinguishes them: *Access denied* is a bad credential, *Permission denied*
is a valid credential without the required grant. The HTTP API keeps the two
apart properly, as `401` and `403`.

**Manage configuration and credentials:**

```bash
./config show                         # .env values, plus engine users and grants
./config check                        # authenticated query against the engine
./config password change              # new password for the application user
./config token rotate                 # new admin token
./config domain   search.example.com  # change domain (will need to re-issue cert)
```

After changing a value that Caddy reads (domain or email), recreate the
Caddy container so it picks up the new value. `./config` does this for you
automatically when Caddy is running; to do it by hand:

```bash
docker compose --profile public up -d --force-recreate caddy
```

Credential changes need no recreate at all — Caddy holds no credentials.

See [Configuration helper reference](#configuration-helper-reference)
for the full list of subcommands.

**Upgrade Manticore** to a new minor or patch version:

1. Update the `image:` line in `docker-compose.yml` (e.g. `27.1.5` →
   `27.1.6`).
2. Pull the new image and recreate the container:

   ```bash
   docker compose pull
   docker compose up -d
   ```

3. Verify with `docker compose logs manticore --tail=20` that the new
   version is running.

Recreating the container does not disturb authentication: users, grants and
tokens live in `auth.json` inside the `manticore-data` volume, and survive
`up -d --force-recreate` untouched.

### Renaming the data volume to match the pinned project name

`docker-compose.yml` pins the Compose project name:

```yaml
name: manticore-docker
```

Without that key, Compose derives the project name from the directory holding
`docker-compose.yml`, so a deployment created before the key was added may own its data
under a different volume prefix. This section moves that data onto the pinned name.

Every step below keys off volume names rather than the current project name, so the
procedure works whether or not you have already pulled the commit that added `name:`.

#### Does this apply to you

List the data volumes on this host:

```bash
docker volume ls --format '{{.Name}}' | grep '_manticore-data$'
```

If the only line is `manticore-docker_manticore-data`, nothing here applies and you can
skip the rest of this section.

If a line with any other prefix appears, that prefix is your old project name. A clone at
`/opt/manticore`, for example, produces `manticore_manticore-data`.

Do not use `docker compose config` to answer this question. Once the `name:` key is in
your working tree, it reports `manticore-docker` for everyone, including deployments whose
data still lives under the old name.

#### Check for a collision first

```bash
docker volume ls --format '{{.Name}}' | grep -x 'manticore-docker_manticore-data'
```

If that prints nothing, continue to Option A or Option B.

If it prints a match, both volumes exist and you must resolve that before going further.
Inspect what is in the target:

```bash
docker run --rm -v manticore-docker_manticore-data:/data alpine sh -c "ls -la /data; du -sh /data"
```

Back it up or remove it by hand if it holds anything you do not recognize. The steps below
assume `manticore-docker_manticore-data` either does not exist or is empty:
`docker volume create` succeeds silently on an existing volume, and the copy would then
merge your data on top of whatever is already there.

#### Option A: rename the volume (recommended)

This copies your data onto the volume name Compose uses from now on, so future clones
behave the same regardless of the directory they land in.

Record the old project name from the listing above:

```bash
OLD_PROJECT=manticore    # the prefix from ${OLD_PROJECT}_manticore-data above
```

Stop the old project explicitly. With the `name:` key present, a plain `docker compose
down` addresses `manticore-docker` and leaves the old containers running:

```bash
docker compose -p "$OLD_PROJECT" down
# with the public profile: docker compose -p "$OLD_PROJECT" --profile public down
```

`down` does not remove named volumes, so your data is not at risk here.

Confirm nothing is still holding the volume:

```bash
docker ps --filter volume="${OLD_PROJECT}_manticore-data"
```

This must list no containers. Copying while Manticore is writing produces an unusable copy
and reports no error at any point.

Copy the data:

```bash
docker volume create manticore-docker_manticore-data
docker run --rm \
    -v "${OLD_PROJECT}_manticore-data":/from \
    -v manticore-docker_manticore-data:/to \
    alpine \
    sh -c "cp -a /from/. /to/"
```

Compare the two volumes before starting anything:

```bash
docker run --rm -v "${OLD_PROJECT}_manticore-data":/data alpine sh -c "ls -la /data; du -sh /data"
docker run --rm -v manticore-docker_manticore-data:/data alpine sh -c "ls -la /data; du -sh /data"
```

The file listing and the reported size should match. Once they do, pull if you have not
already, and start:

```bash
git pull
docker compose up -d
# with the public profile: docker compose --profile public up -d
```

Verify the running deployment itself: your tables should be present and searches should
return what you expect. Starting successfully is not verification. Only after that, remove
the old volume by hand:

```bash
docker volume rm "${OLD_PROJECT}_manticore-data"
```

#### Option B: keep the old name

Lower risk if you would rather not touch a live volume right now. Write the old project
name into `.env` literally, substituting your own prefix:

```bash
echo 'COMPOSE_PROJECT_NAME=manticore' >> .env
```

`COMPOSE_PROJECT_NAME` takes precedence over the `name:` key in `docker-compose.yml`, so
Compose keeps using the volume you already have.

This survives `./config setup`. The wizard rewrites only the keys it collected and leaves
every other line alone, `.env.example` being copied only when `.env` does not exist at all —
so a hand-added `COMPOSE_PROJECT_NAME`, and its comment, come through a re-run untouched.
See [the `setup` reference](#configuration-helper-reference) for what the wizard does and
does not rewrite.

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

Which model to use is the Drupal module's decision — it supplies the model
name. What follows is what running one **costs on this stack**, so you can
size a host and avoid one specific surprise.

### `CREATE TABLE` is what blocks, not the first `INSERT`

This is the most useful operational fact in this section. The model download
happens during the `CREATE TABLE` that first names the model — not on the
first document you index. Measured on a cold cache, a
several-hundred-megabyte model took **around 50 seconds** to create the
table, against **under a second** for a single-row insert afterwards.

That matters because index creation from Drupal is a synchronous HTTP
request. A cold-cache `CREATE TABLE` can therefore exceed a typical PHP or
web-server timeout (commonly 30–60 seconds), and the operator sees a failed
request rather than a slow but successful one. Pre-warming the cache — by
creating a throwaway table that names the model, from the command line —
avoids it entirely. The cache is per-model, so this is a one-off per model.

### Sizing the host

For a multilingual model, measured on this stack:

- **about 465 MB** on disk, inside the `manticore-data` volume
- **about 1.6 GB** peak container memory while the model loads

The memory peak is the number to size by. It occurs during model load and
bulk indexing never exceeded it. Smaller models cost proportionally less.
Note that 1.6 GB on its own makes a 2 GB host marginal — see
[Requirements](#requirements).

### The cache persists

The cache lives inside the existing `manticore-data` volume, so it survives
`docker compose down` and `docker compose up -d --force-recreate` with no
re-download. **No additional volume and no Compose change are needed** for
embeddings to work or for the cache to persist.

### Verify a model before relying on it

Create a throwaway table that names the model and drop it again, before
pointing a real index at it. A published model repository can download
completely and still fail at load, and the failure surfaces only when the
table is created.

Two further situations need manual steps: a host with no outbound internet,
and a container started with no network at all.

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


## Morphology and lemmatization

Morphology is what makes a search for `mice` find a document containing
`mouse`. Manticore offers two kinds, set per table with the `morphology`
option at `CREATE TABLE`:

- **Stemmers** (`stem_en`, `stem_ru`, …) chop words down by rule. They need
  nothing installed and are always available.
- **Lemmatizers** (`lemmatize_en_all`, `lemmatize_ru_all`, …) look words up
  in a dictionary and return real base forms. They need a `.pak` dictionary
  file.

**The dictionaries are already installed.** This is the short version of
this whole section: the `manticore` package ships them inside the image, at
the path the engine reads by default. There is nothing to download, nothing
to mount, and no `./config` subcommand to run.

| Language | Code | `.pak` size |
|---|---|---|
| English | `en` | 1.6 MB |
| German | `de` | 7.2 MB |
| Russian | `ru` | 9.8 MB |
| Ukrainian | `uk` | 29.9 MB |

All four live in `/usr/share/manticore` inside the container — about 48 MB
of the image you already pulled. They are byte-identical to the tarballs
published at `repo.manticoresearch.com/repository/morphology/`, whose index
currently lists exactly these four languages and no others.

`docker-compose.yml` sets the directory explicitly:

```yaml
    environment:
      common_lemmatizer_base: /usr/share/manticore
```

That value is also the engine's own built-in default, so the line changes no
behaviour — lemmatization works with it removed. It is there to state the
path in the file rather than leave it implicit.

Confirm what this host has:

```bash
./config show
```

```
Morphology dictionaries

  lemmatizer_base = /usr/share/manticore
                    read from the running engine

  Installed: de en ru uk
```

### Choosing a morphology is the client's job, not the stack's

There is deliberately no setting here to "turn the lemmatizer on". Morphology
is fixed per table when the table is created, so the choice belongs to
whatever creates it — for Drupal, that is the
[Search API Manticore](https://www.drupal.org/project/search_api_manticore)
module, per index. This stack's responsibility ends at supplying the
dictionaries and the path to them.

A switch here would be actively misleading: it would suggest the stack
controls something it does not, and could leave you believing lemmatization
is on while the client is still creating tables with `stem_ru`.

### What a lemmatizer buys over a stemmer

Measured on this image, with `CALL KEYWORDS` showing the token each table
actually indexes:

| Query word | `lemmatize_en_all` | `stem_en` |
|---|---|---|
| `ran` | `run` | `ran` |
| `running` | `run` | `run` |
| `mice` | `mouse` | `mice` |
| `geese` | `goose` | `gees` |

| Query word | `lemmatize_ru_all` | `stem_ru` |
|---|---|---|
| `люди` | `человек` | `люд` |

The stemmer cannot connect `ran` to `run`, `mice` to `mouse`, or `люди` to
`человек`, because no suffix rule relates them — the words share no stem.
A dictionary can. In exchange, a stemmer costs no memory and covers any
language approximately, while a lemmatizer covers four languages precisely.

Which to use is a judgement about your content, and worth measuring on it
rather than assuming.

### One index per language, or one index for all of them

`morphology` accepts a **comma-separated list**, so a single table can carry
several languages:

```sql
CREATE TABLE polyglot (title text)
  morphology='lemmatize_ru_all, lemmatize_en_all, lemmatize_de_all'
```

Verified end to end: with Russian, English and German documents in that one
table, a query in each language retrieves its own document. So a multilingual
site does **not** structurally need an index per language.

Two caveats before choosing that:

1. **Order matters, and processing stops early.** The manual: processors are
   "applied to incoming words in the order they are listed, and the
   processing will stop once one of the stemmers modifies the word." The
   first processor to change a word wins, and the rest never see it.
2. **The `_all` variants add cross-language noise.** In the three-language
   table above, `geese` indexed as `geesen geese goose` and `ging` as
   `gehen g ging` — earlier processors firing on words from another
   language. Harmless for recall, but it inflates the dictionary and can
   cost precision.

Where a site's languages are cleanly separated into different indexes
anyway, a single morphology per index stays the cleaner choice. The
comma-separated list is what makes a genuinely mixed-language index possible.

### When a dictionary is missing

Only relevant if you repoint `common_lemmatizer_base` somewhere else, since
nothing is missing by default. The engine loads a dictionary lazily, when a
table that needs it is created — not at daemon start. So a missing file does
not stop the stack; it fails the `CREATE TABLE`:

```json
{"error":"error adding table 'x': failed to open /some/dir/ru.pak: No such file or directory"}
```

The table is **not** created, which is the correct outcome: it fails loudly
rather than silently giving you an index with no morphology.

Because the load is lazy, dropping a dictionary into place takes effect
immediately — the next `CREATE TABLE` succeeds against the same running
daemon, with **no restart**.

> **Check morphology over `/sql?mode=raw`, never `/cli`.** `/cli` is served
> through Buddy, which can report a failed `CREATE TABLE` as `Query OK` and
> silently drop the offending column. The error above appears in full on
> `/sql?mode=raw`, which `searchd` serves directly. Every command in this
> section uses it for that reason.

One trap worth knowing: if you ignore a failed `CREATE TABLE` and insert
anyway, Manticore auto-creates the table from the document — with no
morphology at all. The error is loud, but carrying on past it is quiet.

### Verify it yourself

Proves the dictionary is loaded and *used*, not merely present. Uses
`$MC_AUTH` from [Verify the installation](#verify-the-installation):

```bash
# Two tables, identical but for the morphology.
curl -s -u "$MC_AUTH" 'http://127.0.0.1:9308/sql?mode=raw' \
  --data-urlencode "query=CREATE TABLE lem_probe (title text) morphology='lemmatize_ru_all'"
curl -s -u "$MC_AUTH" 'http://127.0.0.1:9308/sql?mode=raw' \
  --data-urlencode "query=CREATE TABLE stem_probe (title text) morphology='stem_ru'"

# Index the singular in both.
curl -s -u "$MC_AUTH" 'http://127.0.0.1:9308/sql?mode=raw' \
  --data-urlencode "query=INSERT INTO lem_probe (id, title) VALUES (1, 'человек')"
curl -s -u "$MC_AUTH" 'http://127.0.0.1:9308/sql?mode=raw' \
  --data-urlencode "query=INSERT INTO stem_probe (id, title) VALUES (1, 'человек')"

# Search the irregular plural. The lemmatizer table hits; the stemmer's does not.
curl -s -u "$MC_AUTH" 'http://127.0.0.1:9308/sql?mode=raw' \
  --data-urlencode "query=SELECT id FROM lem_probe WHERE MATCH('люди')"
curl -s -u "$MC_AUTH" 'http://127.0.0.1:9308/sql?mode=raw' \
  --data-urlencode "query=SELECT id FROM stem_probe WHERE MATCH('люди')"
```

The first search returns `{"id":1}` and the second returns nothing. To see
why, ask what each table made of the word:

```bash
curl -s -u "$MC_AUTH" 'http://127.0.0.1:9308/sql?mode=raw' \
  --data-urlencode "query=CALL KEYWORDS('люди', 'lem_probe')"
# "tokenized":"люди","normalized":"человек"   <- the dictionary at work

curl -s -u "$MC_AUTH" 'http://127.0.0.1:9308/sql?mode=raw' \
  --data-urlencode "query=CALL KEYWORDS('люди', 'stem_probe')"
# "tokenized":"люди","normalized":"люд"       <- the stemmer's best effort
```

Clean up:

```bash
curl -s -u "$MC_AUTH" 'http://127.0.0.1:9308/sql?mode=raw' \
  --data-urlencode "query=DROP TABLE lem_probe"
curl -s -u "$MC_AUTH" 'http://127.0.0.1:9308/sql?mode=raw' \
  --data-urlencode "query=DROP TABLE stem_probe"
```

### The CI image does not need this

The separate `ghcr.io/dillix/manticore-ci` image used by the Drupal module's
test suite needs no dictionary and is unaffected by anything here. Those
tests assert the *structure* of the queries the module builds, not
linguistic results, and the stemmers cover that without the weight. Nothing
in this section applies to it.


## Configuration helper reference

The `./config` wrapper is a single entrypoint for managing both the `.env`
file and the engine's own users, tokens and grants. Every subcommand
validates input, shows a diff of the planned change where one applies, asks
for confirmation, and restores host file ownership afterwards — `.env` is
forced to mode `600` whenever it is written.

Most of the logic lives in `bin/config.sh` and runs in a throwaway container;
the wrapper forwards to `docker compose run --rm -it config <args>`. A few
operations must run on the host instead, because they are local `searchd`
calls with no network equivalent — the admin bootstrap in `setup`, and
`admin reset`. Always invoke through `./config` rather than calling the
compose service directly.

There are no flags; every argument is positional.

```
setup                         Interactive wizard for first-time config
show                          Display .env, the morphology dictionaries
                              and the engine's users/grants
check                         Authenticated query against the engine
domain <fqdn>                 Set MANTICORE_DOMAIN
email <addr>                  Set MANTICORE_ACME_EMAIL
username <name>               Set MANTICORE_USERNAME and create the user
password change               New password for the application user
token rotate                  New admin token in .env
admin reset                   Wipe all engine users and start again
```

**Inspect current configuration:**

```bash
./config show
```

Displays the five `.env` values — the recorded scenario, domain, ACME email,
username and the admin token, masked to its first few characters — then the
morphology dictionaries installed on this host and the directory the engine
reads them from, and finally the engine's users with their grants.
Internal `system.*` accounts are deliberately filtered out. If the stack is
stopped or the token is missing it says so and still prints the `.env` half —
that is exactly the situation you would run it to diagnose.

The dictionary listing is careful about what it actually knows. The path is
labelled by where it came from: read from the running engine, the engine's
built-in default, or — when the daemon cannot be reached — the value in
`docker-compose.yml`, which is a statement about the file rather than about
the daemon. Likewise, "no dictionaries" and "cannot check from here" are
reported as different things, because they are: the helper container sees the
image but not the data volume, so a `lemmatizer_base` pointed into the volume
is something it must decline to answer rather than report as empty. See
[Morphology and lemmatization](#morphology-and-lemmatization).

**Check that the engine is reachable and the token works:**

```bash
./config check
```

Runs an authenticated `SELECT 1` against the engine using
`MANTICORE_ADMIN_TOKEN`. It verifies the **admin** credential only; the
application user's password is not stored anywhere, so it cannot be checked
after the fact — `./config password change` verifies a new one at the moment
it is issued.

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

`domain` and `email` only touch `.env`, and recreate Caddy afterwards if it
is running. **`username` does more than that: it creates the user in the
engine** and grants it `read`, `write` and `schema`.

The engine has **no rename**. Pointing `MANTICORE_USERNAME` at a new name
therefore creates a *new* user with a *new* password, which means updating
the Drupal Key entity as well. The old user is not removed automatically —
`./config username` offers to drop it, and if you decline it keeps working
until you drop it by hand:

```sql
DROP USER 'old-name';
```

**Change the application user's password:**

```bash
./config password change              # prompts interactively
```

Offers a generated 24-character password or one you type yourself (hidden
input via `stty -echo`, entered twice, re-prompting on mismatch). It sets the
password **in the engine**, verifies the new credential over HTTP Basic
immediately, and displays it once.

The password is **never** accepted as a command-line argument, and the
command refuses outright if given one — arguments are recorded in shell
history, visible in `ps auxw` during execution, and may end up in SSH session
logs.

Nothing is written to `.env`: the application password is not stored there,
or anywhere else in this repository. It belongs in a Drupal Key entity.

**Rotate the admin token:**

```bash
./config token rotate
```

Issues a new `MANTICORE_ADMIN_TOKEN`, writes it to `.env`, and confirms it
authenticates. **The previous token stops working immediately**, so anything
else configured with it must be updated. Caddy holds no credentials, so
nothing needs recreating.

**Reset the engine's authentication:**

```bash
./config admin reset
```

Destructive recovery for a lost admin token — see
[I lost the admin token](#i-lost-the-admin-token).

**Interactive setup wizard:**

```bash
./config setup
```

Asks which scenario this host runs and collects only what that scenario
uses — **Scenario A**: scenario, ACME email, application username, with
`MANTICORE_DOMAIN=localhost` written for you; **Scenario B**: scenario,
domain, ACME email, application username. It then bootstraps the engine's
admin, creates the application user with its grants, verifies that
credential, and displays its password once. Recommended for first-time
deployment, and re-runnable afterwards.

The scenario is asked, never inferred — not from `COMPOSE_PROFILES`, not from
the current domain, not from anything else. Which scenario a host runs is a
decision, and the answer is recorded in `MANTICORE_SCENARIO` so it is visible
in `./config show` afterwards and offered as the default on the next run.

Collection happens before anything else, so aborting during the questions
leaves the engine untouched. If `.env` already exists and is fully populated,
the wizard asks before overwriting. If the engine already has an admin and
the token in `.env` still works, the bootstrap is skipped and it continues
with the application user.

**A `.env` written before `MANTICORE_SCENARIO` existed keeps working.**
Nothing infers a value for the missing key — `MANTICORE_DOMAIN=localhost` in
particular is *not* read as proof of Scenario A, since a Scenario B operator
may legitimately have used it. Every subcommand behaves exactly as before,
`./config show` reports the scenario as `(not recorded)`, and the next
`./config setup` records your answer.

Running the wizard again on a live install to record it is safe: **a re-run
does not rotate any credential.** If the engine already has an admin and the
token in `.env` authenticates, the bootstrap is skipped and
`MANTICORE_ADMIN_TOKEN` is left alone; if the token no longer works the
wizard stops and writes nothing rather than reissuing anything. The
application user's password is only reissued if you answer **yes** to *Issue
a new password for 'drupal'?*, which defaults to no — answer no and the
password already held in your Drupal Key entity keeps working. `auth.json`
inside the data volume is only ever read.

`setup` is the safe one. The commands that *do* replace a credential are
`./config password change` (reissues the application user's password — your
Drupal Key entity stops authenticating until you update it), `./config token
rotate` (reissues the admin token, invalidating the previous one
immediately), and `./config admin reset`. Only the last destroys every user,
token and grant at once, which is why it asks you to type `reset` rather than
answer y/N.

The wizard also **preserves keys it does not own.** It rewrites the values it
collected and leaves every other line in `.env` — including anything you
added by hand, such as `COMPOSE_PROJECT_NAME` — exactly as it found it.
`.env.example` is copied only when `.env` does not exist at all.

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

### Every request returns 401 despite correct credentials

First, confirm the credentials are actually correct — reissue them with
`./config password change`, which verifies the new credential as it is
issued.

If they are correct and requests still fail, the most likely cause is a
reverse proxy that **removes or rewrites the `Authorization` header** before
the request reaches Manticore. The engine then sees an anonymous request and
can only answer 401 — even though the client did send a credential.

In nginx, look for this directive and delete it:

```nginx
proxy_set_header Authorization "";
```

Under 1.0.0 that line was correct: the proxy authenticated, and Manticore had
no authentication of its own to feed. Under 2.0.0 it is fatal. If you copied
an older recipe into your own vhost, this is the line to remove. nginx
forwards `Authorization` to the upstream by default, so no replacement
directive is needed.

Check too that the proxy is not enforcing its own `auth_basic` in front of
Manticore. It would reject the application's credential at the proxy, before
the engine ever saw it.

A blanket 401 immediately after upgrading usually means something simpler:
`./config setup` has not been run yet, so the engine has no accounts at all.

### `./config` prompts don't respond to `y` at the confirmation step

The wrapper already passes `-it` to `docker compose run`. If you're
invoking the underlying Compose service directly (without the wrapper),
make sure to pass both flags:

```bash
docker compose run --rm -it config password change
```

Without `-it`, Compose may not allocate a TTY, and `read` silently
treats the prompt as cancelled.

Note that `setup` and `admin reset` cannot be run this way at all — they
need the host wrapper, and refuse to run without it.

### `docker compose config --services` does not list `caddy` or `config`

Services with `profiles:` are hidden from `config --services` unless the
matching profiles are explicitly active:

```bash
docker compose --profile public --profile tools config --services
```

This is documented Compose behaviour, not a bug. Helper commands like
`docker compose run --rm <service>` activate the matching profile
automatically.

### Caddy still serves the old domain or certificate after changing `.env`

You changed `MANTICORE_DOMAIN` or `MANTICORE_ACME_EMAIL`, but Caddy is still
serving the previous domain. This is expected — Docker container environment
variables are fixed at container creation time and are not re-read when
`.env` changes. Recreate the Caddy container to pick up the new values:

```bash
docker compose --profile public up -d --force-recreate caddy
```

The Manticore container does not need recreating; those two values are the
only ones Caddy reads. Verify what actually reached it:

```bash
docker exec manticore-caddy printenv MANTICORE_DOMAIN
```

**Credential changes never require this.** Caddy holds no credentials — the
engine checks them — so a new password or a rotated token takes effect
immediately with no restart anywhere.

> When you use `./config` through the wrapper, this recreate happens
> automatically — the wrapper detects that `.env` changed and a Caddy
> container is running, then issues the `--force-recreate caddy` for
> you. This entry covers the case where you edited `.env` outside the
> helper (manually, via Ansible playbook, etc.), or invoked the
> in-container `config` service directly without the wrapper.
>
> If a wizard run fails partway through, it tells you that `.env` was
> updated while Caddy is still running with the previous values, and gives
> you the recreate command — it deliberately does not swap the certificate
> the proxy is serving while you are still fixing the problem.

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

### I lost the application user's password

The engine stores it hashed, so it cannot be recovered — but reissuing it is
routine and non-destructive:

```bash
./config password change
```

This sets a new password on the existing user in the engine, verifies it over
HTTP Basic straight away, and prints it once. Grants, tokens and indexed data
are untouched. **Copy the password to a password manager before dismissing
the output** — it will not be shown again.

Then update the Drupal Key entity holding the password. Indexing and search
fail between the change and that update, so do them together.

### I lost the admin token

> **Read this before running anything.** The recovery below **destroys every
> user, token and grant in the engine**. Your indexed data is *not* touched,
> but the application user must be recreated and Drupal's Key entity updated
> with its new password. Use it only when the admin token is genuinely lost.

`MANTICORE_ADMIN_TOKEN` cannot be recovered, and neither can the admin
password — it is never stored. If you have the token recorded somewhere else,
put it back into `.env` as `MANTICORE_ADMIN_TOKEN` and re-run
`./config setup` instead of doing any of this.

Otherwise:

1. Reset the engine's authentication:

   ```bash
   ./config admin reset
   ```

2. Confirm by typing the word `reset` when prompted. Anything else aborts
   without changing a thing.

3. The command empties the engine's authentication file, bootstraps a new
   admin, and writes a fresh `MANTICORE_ADMIN_TOKEN` to `.env`. **No restart
   is needed.**

4. Recreate the application user and get a new password for it:

   ```bash
   ./config setup
   ```

5. Update the Drupal Key entity with the password from step 4.

Verify with `./config check`, which runs an authenticated query using the new
token.

### `/autocomplete` returns HTTP 501 `no such table`

```
HTTP 501 {"error":"no such table 'my_index'"}
```

The table exists. This is a **missing `read` grant**, misreported as a schema
error: the endpoint is resolved under the calling user's identity, and the
permission failure surfaces as a lookup failure. Chasing it as an indexing or
naming problem will waste your time.

Check the user's grants:

```bash
./config show
```

The application user should have `read`, `write` and `schema` on `*`. If any
are missing, re-run `./config setup`, which re-applies whichever grants are
absent without disturbing the rest.

### A 401 does not always mean a bad password

On the HTTP API, the two failures are normally distinct: **401** is an
authentication failure (wrong or missing credential) and **403** is an
authorisation failure (valid credential, missing grant). The wizard's own
probes report them that way.

There is at least one exception. The explicit
`SET PASSWORD '<new>' FOR '<user>'` form is refused with **401** and an
authentication-shaped message rather than 403 — and it does this even when
the target is the caller's own account, while the bare `SET PASSWORD '<new>'`
form succeeds. So a 401 does not prove the credential is wrong; it can also
mean the credential is fine and the operation is not allowed. Scripts that
branch on 401 to mean "re-authenticate" will loop on it.

Over the **MySQL protocol** the distinction collapses entirely: both come
back as `ERROR 1045`, and only the message text tells them apart —
`Access denied` for a bad credential, `Permission denied` for a missing
grant.

If a credential fails everywhere rather than on one operation, see
[Every request returns 401 despite correct credentials](#every-request-returns-401-despite-correct-credentials).


## License

This stack configuration is released under the MIT License.

Manticore Search and Caddy have their own licenses — see their respective
projects for details.
