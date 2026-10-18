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

В `inventory.local.ini` укажите внутренние адреса трёх ВМ. `monitoring` — ВМ для Prometheus и Grafana.
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
| `switchover db02` | Плановое переключение на указанную реплику |
| `events` | Показать события смены роли и аннотации Grafana |
| `stop`, `start` | Остановить или запустить кластер и мониторинг |

При sudo без пароля: `export SUDO_FLAGS=` один раз в сессии или `SUDO_FLAGS= just apply`.

## Файлы

- `vars.yml`: имя кластера, точные версии пакетов, параметры PostgreSQL.
- `cluster.yml`: отметка прогона в Grafana, пины APT, etcd, Patroni и обработчик `on_role_change`.
- `templates/patroni.yml.j2`: конфигурация Patroni.
- `templates/role-event.j2`: обработчик: журнал `patroni-role`, затем аннотация Grafana.
- `monitoring.yml`: Prometheus и Grafana на одной ВМ, отдельно от кластера.
- `verify.yml`, `switchover.yml`, `events.yml`: проверка, переключение, показ события.
- `power.yml`: остановка и запуск служб без удаления данных.

Пароли создаются при первом запуске в `credentials/` и не попадают в Git.
Grafana: пользователь `admin`, пароль в `credentials/grafana-admin`.
Токен сервисного аккаунта Grafana сохраните в `credentials/grafana-token`.
