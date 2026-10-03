# Aspia Router + Relay (Docker Compose)

Router и Relay для Aspia 3.x. Двумя контейнерами управляет Docker Compose, все данные — в
папке `./data` рядом с `docker-compose.yml`.

> English documentation: [README.md](README.md).

## Требования

- Docker Engine и Docker Compose v2.
- Архитектура **x86_64** (amd64): образ и пакеты Aspia — только под amd64.
- Публичный адрес для Router и для Relay; порты открыты (см. ниже).

## Что взять из репозитория

На хосте нужны только два файла:

| Файл в репозитории | Зачем                                         |
| ------------------ | --------------------------------------------- |
| `docker-compose.yml` | описание стека                              |
| `.env.example`       | настройки первого запуска (скопировать в `.env`) |

Остальное на хосте не нужно: `Dockerfile` (исходник, нужен только для сборки образа),
`docker-entrypoint.sh` и `docker-healthcheck.sh` (их содержимое уже внутри образа),
`.github/workflows/docker.yml` (сборка и публикация образа), `README*` (документация).

## Развёртывание на хосте

```sh
# 1. Рабочий каталог
sudo mkdir -p /opt/aspia && cd /opt/aspia

# 2. Взять из репозитория два файла — любым способом:

#    а) клонировать репозиторий
git clone https://github.com/paprikkafox/aspia-docker.git /tmp/aspia-docker
cp /tmp/aspia-docker/docker-compose.yml /tmp/aspia-docker/.env.example .

#    б) скачать только эти два файла
curl -fsSLO https://raw.githubusercontent.com/paprikkafox/aspia-docker/main/docker-compose.yml
curl -fsSLO https://raw.githubusercontent.com/paprikkafox/aspia-docker/main/.env.example

# 3. Настройки и запуск
cp .env.example .env
nano .env                    # укажите ASPIA_RELAY_PEER_PUBLIC_ADDRESS
mkdir -p data                # ./data — папка рядом с docker-compose.yml
docker compose up -d

# 4. Проверка
docker compose ps
docker compose logs -f router
```

Что происходит при первом запуске:

- Router создаёт `./data/config/router.conf`, ключи `./data/config/host.pub` и
  `./data/config/relay.pub`, а также базу `./data/router/router.db3`.
- Relay создаёт `./data/config/relay.conf` и берёт ключ Router из `relay.pub`.
- Значения из `.env` записываются в конфиги.

Лог Router печатает учётные данные администратора. По умолчанию **`admin` / `admin` —
сразу смените пароль** в Aspia Client.

Откройте порты в фаерволе:

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

Автозапуск после перезагрузки обеспечивает `restart: unless-stopped` в compose; служба Docker
должна быть включена: `sudo systemctl enable --now docker`.

## Переменные

Задаются в `.env` **только при первом запуске**. Дальше конфиги в `./data` — источник истины,
и `.env` можно очистить.

| Переменная                        | По умолчанию | Зачем                                                            |
| --------------------------------- | ------------ | ---------------------------------------------------------------- |
| `ASPIA_RELAY_PEER_PUBLIC_ADDRESS` | —            | **обязательна**: адрес Relay, по которому к нему подключаются Host и Client |
| `ASPIA_VERSION`                   | `3.0.23`     | версия Aspia (тег образа)                                        |
| `ASPIA_RELAY_ROUTER_ADDRESS`      | `router`     | адрес Router для Relay (внутри compose)                          |
| `ASPIA_LOG_LEVEL`                 | `1`          | 0 trace … 4 fatal                                                |

Переменная при каждом старте переопределяет значение в `./data/config/*.conf`. Чтобы управлять
настройками только через файлы — уберите переменную из `.env`.

## Где что лежит

`./` — это текущий каталог, где лежит `docker-compose.yml` (в примере — `/opt/aspia`).

| Папка           | В контейнере     | Что это                                              |
| --------------- | ---------------- | ---------------------------------------------------- |
| `./data/config` | `/etc/aspia`     | `router.conf`, `relay.conf`, `host.pub`, `relay.pub` |
| `./data/router` | `/var/lib/aspia` | `router.db3` — база данных                           |

Бэкап и перенос — это копирование папки `./data`. В конфигах лежат приватные ключи, поэтому
храните `./data` как секрет.

## Порты

| Порт | Протокол | Кто    | Зачем                  |
| ---- | -------- | ------ | ---------------------- |
| 8060 | TCP      | Router | Hosts < 3.0.0          |
| 8061 | TCP      | Router | Hosts 3.x              |
| 8062 | TCP      | Router | Clients                |
| 8063 | TCP      | Router | Relays                 |
| 8065 | UDP      | Router | STUN                   |
| 8070 | TCP      | Relay  | пиры (Hosts и Clients) |

## Обычные операции

```sh
docker compose logs -f router      # или: relay
docker compose restart
docker compose ps                  # сервисы помечаются healthy
docker compose down                # остановить (данные в ./data остаются)
```

Обновление версии Aspia:

```sh
# поменяйте ASPIA_VERSION в .env, затем:
docker compose pull
docker compose up -d
```

## Примечания

- Сервис работает от непривилегированного пользователя uid/gid `1000`; при запуске от root
  entrypoint выставляет владельца `./data/config` и `./data/router`. Если ваш uid не `1000`,
  чтение этих файлов может потребовать `sudo`.
- `sd_login_monitor_new failed` в логе при старте — нормально в контейнере без systemd.
- Веб-интерфейса нет: Router и пользователями управляют из Aspia Client.
