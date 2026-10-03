# Aspia Router + Relay (Docker Compose)

Router and Relay for Aspia 3.x. Docker Compose manages the two containers, and all data lives
in the `./data` directory next to `docker-compose.yml`.

The stack runs in **host network mode** (`network_mode: host`): both containers share the host
network stack, so the service ports are opened on the host directly, without NAT or port
mapping, and the services see the host's real addresses.

> Russian documentation: [README.ru.md](README.ru.md).

## Requirements

- Docker Engine and Docker Compose v2.
- **x86_64** (amd64): the image and the Aspia packages are amd64 only.
- A public address for the Router and for the Relay; the ports opened on the host (see below).
- Host networking (`network_mode: host`), which is Linux-only.

## What to take from the repository

On the host you need only two files:

| Repository file      | Purpose                                    |
| -------------------- | ------------------------------------------ |
| `docker-compose.yml` | the stack definition                       |
| `.env.example`       | first-run settings (copy it to `.env`)     |

The rest is not needed on the host: `Dockerfile` (a source file, only to build the image),
`docker-entrypoint.sh` and `docker-healthcheck.sh` (their contents are already inside the
image), `.github/workflows/docker.yml` (builds and publishes the image), `README*` (docs).

## Deploying on a host

```sh
# 1. Working directory
sudo mkdir -p /opt/aspia && cd /opt/aspia

# 2. Get the two files from the repository - either way:

#    a) clone the repository
git clone https://github.com/paprikkafox/aspia-docker.git /tmp/aspia-docker
cp /tmp/aspia-docker/docker-compose.yml /tmp/aspia-docker/.env.example .

#    b) download just these two files
curl -fsSLO https://raw.githubusercontent.com/paprikkafox/aspia-docker/main/docker-compose.yml
curl -fsSLO https://raw.githubusercontent.com/paprikkafox/aspia-docker/main/.env.example

# 3. Configure and start
cp .env.example .env
nano .env                    # set ASPIA_RELAY_PEER_PUBLIC_ADDRESS
mkdir -p data                # ./data - the directory next to docker-compose.yml
docker compose up -d

# 4. Verify
docker compose ps
docker compose logs -f router
```

What happens on the first start:

- The Router creates `./data/config/router.conf`, the keys `./data/config/host.pub` and
  `./data/config/relay.pub`, and the database `./data/router/router.db3`.
- The Relay creates `./data/config/relay.conf` and reads the Router key from `relay.pub`.
- The values from `.env` are written into the config files.

The Router log prints the administrator credentials. By default they are **`admin` / `admin` —
change the password immediately** in the Aspia Client.

Open the ports in your firewall:

```sh
# ufw
sudo ufw allow 8060:8063/tcp
sudo ufw allow 8065/udp
sudo ufw allow 8070/tcp

# iptables
sudo iptables -A INPUT -p tcp -m multiport --dports 8060:8063 -j ACCEPT
sudo iptables -A INPUT -p udp --dport 8065 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 8070 -j ACCEPT
```

Autostart after a reboot is provided by `restart: unless-stopped` in compose; the Docker service
must be enabled: `sudo systemctl enable --now docker`.

## Variables

They are set in `.env` **only on the first start**. From then on the configs under `./data` are
the source of truth, and `.env` can be emptied.

| Variable                          | Default  | Purpose                                                        |
| --------------------------------- | -------- | -------------------------------------------------------------- |
| `ASPIA_RELAY_PEER_PUBLIC_ADDRESS` | —        | **required**: the Relay address used by Hosts and Clients      |
| `ASPIA_VERSION`                   | `3.0.23` | Aspia version (image tag)                                      |
| `ASPIA_RELAY_ROUTER_ADDRESS`      | `127.0.0.1` | Router address used by the Relay (loopback in host mode)    |
| `ASPIA_LOG_LEVEL`                 | `1`      | 0 trace … 4 fatal                                              |

A variable overrides the value in `./data/config/*.conf` on every start. To manage settings only
through the files, remove the variable from `.env`.

## Where things live

`./` is the current directory where `docker-compose.yml` is placed (in the example `/opt/aspia`).

| Directory       | In the container  | Contents                                             |
| --------------- | ----------------- | ---------------------------------------------------- |
| `./data/config` | `/etc/aspia`      | `router.conf`, `relay.conf`, `host.pub`, `relay.pub` |
| `./data/router` | `/var/lib/aspia`  | `router.db3` — the database                          |

Backup and migration are just copying the `./data` directory. The configs hold the private keys,
so treat `./data` as a secret.

## Ports

In host network mode these ports are opened directly on the host (nothing is published through
a proxy or NAT), so the firewall rules above apply to them as-is.

| Port | Protocol | Component | Purpose                |
| ---- | -------- | --------- | ---------------------- |
| 8060 | TCP      | Router    | Hosts older than 3.0.0 |
| 8061 | TCP      | Router    | Hosts 3.x              |
| 8062 | TCP      | Router    | Clients                |
| 8063 | TCP      | Router    | Relays                 |
| 8065 | UDP      | Router    | STUN                   |
| 8070 | TCP      | Relay     | peers (Hosts and Clients) |

## Day-to-day operations

```sh
docker compose logs -f router      # or: relay
docker compose restart
docker compose ps                  # services are reported as healthy
docker compose down                # stop (data in ./data is kept)
```

Updating Aspia:

```sh
# change ASPIA_VERSION in .env, then:
docker compose pull
docker compose up -d
```

## Notes

- The service runs as the unprivileged user uid/gid `1000`; when started as root the entrypoint
  sets the owner of `./data/config` and `./data/router`. If your uid is not `1000`, reading
  these files may need `sudo`.
- `sd_login_monitor_new failed` in the log at startup is normal in a container without systemd.
- There is no web UI: the Router and users are managed from the Aspia Client.
