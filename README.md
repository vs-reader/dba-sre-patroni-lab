# Patroni lab

Кластер PostgreSQL 17 + Patroni + etcd на трёх Debian 13 и отметка смены лидера в Grafana.

## Подготовка

SSH, sudo и Ansible — как в занятии 4. На управляющем хосте:

```bash
git clone https://github.com/vs-reader/dba-sre-patroni-lab.git
cd dba-sre-patroni-lab
cp -n inventory.ini inventory.local.ini
nano inventory.local.ini
```

В `inventory.local.ini` укажите внутренние адреса трёх ВМ группы `database1`. `monitoring` — ВМ для Prometheus и Grafana, `zabbix` — для Zabbix.
Настройки кластера (имя, порты, установка etcd) — в `group_vars/database1.yml`.
Узлы должны быть без PostgreSQL 17/main и без etcd: `cluster.yml` откажется работать на занятых узлах.

## Запуск

```bash
just check
just ping
just apply
just verify
just monitoring
just switchover db02
just events
```

| Команда | Действие |
| --- | --- |
| `check` | Проверить синтаксис playbook |
| `ping` | Проверить подключения |
| `apply` | Установить etcd, PostgreSQL, Patroni и обработчик, отметить прогон в Grafana |
| `plan` | Показать план изменений (после первого `apply`) |
| `verify` | Проверить etcd, роли, запись и репликацию |
| `monitoring` | Установить Prometheus и Grafana, передать токен узлам |
| `logging` | Установить Loki и Vector, логи Patroni и PostgreSQL в Grafana |
| `zabbix` | Установить Zabbix server, агенты и проверку записи в кластер |
| `collections` | Установить коллекцию community.zabbix (один раз) |
| `zabbix-config` | Создать в Zabbix группу, шаблон, хосты, триггеры, сервис и SLA |
| `switchover db02` | Плановое переключение на указанную реплику |
| `events` | Показать события смены роли и аннотации Grafana |
| `stop`, `start` | Остановить или запустить кластер и мониторинг |

При sudo без пароля: `export SUDO_FLAGS=` один раз в сессии или `SUDO_FLAGS= just apply`.

## Несколько кластеров

Каждый кластер — своя группа inventory из трёх узлов (`database1`, `database2`, ...) в общей группе `database`,
настройки — в `group_vars/<группа>.yml` с уникальным `cluster_name`. Имена узлов в inventory должны быть уникальными.

```ini
[database2]
d2-db01 ansible_host=IP_4
d2-db02 ansible_host=IP_5
d2-db03 ansible_host=IP_6

[database:children]
database1
database2
```

Команды кластера принимают имя группы, без него — `database1`:

```bash
just apply database2
just verify database2
just switchover d2-db02 database2
just stop database2
```

Мониторинг, логи и Zabbix общие: `just monitoring`, `just logging`, `just zabbix`, `just zabbix-config` подключают все кластеры группы `database`.
На дашборде Patroni HA кластер выбирается переменной Cluster.

## Файлы

- `vars.yml`: точные версии пакетов, параметры PostgreSQL.
- `group_vars/database1.yml`: имя кластера, порты, установка etcd.
- `cluster.yml`: отметка прогона в Grafana, пины APT, etcd, Patroni и обработчик `on_role_change`.
- `templates/patroni.yml.j2`: конфигурация Patroni.
- `templates/role-event.j2`: обработчик: журнал `patroni-role`, затем аннотация Grafana.
- `monitoring.yml`: Prometheus и Grafana на одной ВМ, отдельно от кластера.
- `verify.yml`, `switchover.yml`, `events.yml`: проверка, переключение, показ события.
- `power.yml`: остановка и запуск служб без удаления данных.
- `logging.yml`, `templates/vector.yaml.j2`, `templates/loki.yml.j2`: сбор логов, см. [docs/logging.md](docs/logging.md) и [docs/vector.md](docs/vector.md).
- `zabbix.yml`, `zabbix-config.yml`, `requirements.yml`: Zabbix и SLI доступности записи, см. [docs/zabbix.md](docs/zabbix.md).

Пароли создаются при первом запуске в `credentials/` и не попадают в Git.
Grafana: пользователь `admin`, пароль в `credentials/grafana-admin`.
Токен сервисного аккаунта Grafana сохраните в `credentials/grafana-token`.
