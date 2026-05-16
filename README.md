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


## Deploy the stack

> _To be filled in next._


## Verify the installation

> _To be filled in next._


## Connecting from Drupal

> _To be filled in next._


## Operations

> _To be filled in next._


## Troubleshooting

> _To be filled in next._


## License

This stack configuration is released under the MIT License.

Manticore Search and Caddy have their own licenses — see their respective
projects for details.
