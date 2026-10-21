# Логи: Vector и Loki

Vector читает логи на узлах, отбрасывает шум и отправляет строки в Loki. Grafana показывает их рядом с метриками.

```
узлы db01..db03                                   ВМ monitoring
journald: patroni.service ──►  Vector  ──►  Loki :3100  ──►  Grafana
/var/log/grafana/grafana.log ─┘ (monitoring)  хранение 48 ч    Explore
```

Два источника:

| Источник | Что в нём | Пример строки |
| --- | --- | --- |
| журнал `patroni.service` | Patroni, PostgreSQL под ним, обработчик `role-event` | `2026-10-21 08:18:37.009 UTC [4601] ERROR:  division by zero` |
| файл `/var/log/grafana/grafana.log` | Grafana, только на ВМ `monitoring` | `logger=context t=... level=info msg="Request Completed" ...` |

87 % строк Patroni — служебное «no action. I am…» раз в 10 секунд. Vector их не отправляет.

## Установка через Ansible

После `just monitoring`:

```bash
just logging
```

`logging.yml` ставит Loki на ВМ `monitoring`, Vector на узлы `database`, добавляет пользователя `vector` в группу `grafana` (чтобы читать файл Grafana) и подключает источник Loki в Grafana. Версии и контрольные суммы — в `vars.yml`.

## Конфигурация Vector

`templates/vector.yaml.j2`: журнал `patroni.service` на всех узлах и файл Grafana на ВМ `monitoring`, фильтр строк «no action», поле `env` и метки `cluster`, `node`, `app`, `env`. Разбор конфигурации и базовые примеры — в [vector.md](vector.md).

## Установка вручную

### Loki (ВМ monitoring)

```bash
cd /tmp
curl -fLO https://github.com/grafana/loki/releases/download/v3.7.9/loki_3.7.9_amd64.deb
echo "9647b50011ea4eb6d44b82bf708b3eb4fa5d837b33a52741cdda5f912f6cd45d  loki_3.7.9_amd64.deb" | sha256sum -c
sudo apt-get install -y ./loki_3.7.9_amd64.deb
sudo install -d -o loki -g nogroup -m 750 /var/lib/loki
```

Пакет запускает Loki с учебной конфигурацией: данные в `/tmp/loki`, уровень журнала `debug`. Замените `/etc/loki/config.yml` содержимым `templates/loki.yml.j2`, подставив адрес ВМ вместо `{{ ansible_host }}`:

```bash
sudo nano /etc/loki/config.yml
sudo systemctl restart loki
curl http://IP_1:3100/ready
```

Ожидаем `ready`. Первые 15 секунд Loki отвечает `Ingester not ready`.

### Vector (каждый узел)

```bash
cd /tmp
curl -fLO https://github.com/vectordotdev/vector/releases/download/v0.60.0/vector_0.60.0-1_amd64.deb
echo "985f74a8e07ac8efabc891324435451823e77da5b98b636bd7594f402db41219  vector_0.60.0-1_amd64.deb" | sha256sum -c
sudo apt-get install -y ./vector_0.60.0-1_amd64.deb
```

Пакет создаёт пользователя `vector` в группе `systemd-journal`: журнал он читает без дополнительных прав. На ВМ monitoring ещё:

```bash
sudo usermod -aG grafana vector
```

Запишите в `/etc/vector/vector.yaml` конфигурацию по образцу `templates/vector.yaml.j2` со своими адресом и именем узла (источник и получатель Grafana — только на ВМ monitoring), затем:

```bash
sudo vector validate --no-environment /etc/vector/vector.yaml
sudo systemctl enable --now vector
```

### Источник в Grafana

Connections → Data sources → Add → Loki, URL `http://IP_1:3100` → Save & test.

## Проверка

Grafana → Explore → источник Loki:

```logql
{app="patroni"} |= "on_role_change"
```

После `just switchover db02` — две строки: `role=primary` на новом лидере и `role=replica` на прежнем.

```logql
{app="patroni"} |= "no action"
```

Пусто: шум отфильтрован.

```logql
{app="grafana"}
```

Строки из файла Grafana.

Ошибка и медленный запрос для проверки (на лидере; если порт изменён, добавьте `-p` с `pg_port`):

```bash
sudo -u postgres psql -XAtqc "select 1/0"
sudo -u postgres psql -Xq -c "set log_min_duration_statement = 0" -c "select pg_sleep(0.3)"
```

```logql
{app="patroni"} |= "ERROR:"
{app="patroni"} |= "duration:" | regexp `duration: (?P<ms>[\d.]+) ms` | ms > 200
```

Без Grafana — через API Loki:

```bash
curl -s -G http://IP_1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={app="patroni"} |= "on_role_change"' \
  --data-urlencode 'since=1h'
curl -s http://IP_1:3100/loki/api/v1/label/app/values
```

## LogQL: основы

Запрос — выбор потоков по меткам и конвейер обработки:

```
{метки}  | фильтры  | разбор  | условия  | формат
```

**Выбор потоков:**

```logql
{app="patroni"}                           равно
{app!="grafana", env="lab"}               не равно
{node=~"db0[12]", app="patroni"}          регулярное выражение
{app="patroni", node!~"db03"}             не совпадает
```

Хотя бы одна метка должна быть с `=` или `=~`, иначе Loki отклонит запрос.

**Фильтры по тексту** — самые быстрые после меток:

```logql
{app="patroni"} |= "ERROR"                содержит
{app="patroni"} != "checkpoint"           не содержит
{app="patroni"} |~ "ERROR|FATAL"          регулярное выражение
{app="patroni"} !~ "LOG:  (checkpoint|connection)"
```

**Разбор строки в поля:**

```logql
{app="grafana"} | logfmt | level="error"                       key=value
{app="patroni"} |= "on_role_change" | regexp `role=(?P<role>\w+)` | role="primary"
{app="patroni"} |= "UTC [" | pattern "<_> <_> <_> <_> [<pid>] <lvl>:  <msg>" | lvl="ERROR"
```

**Форматирование вывода:**

```logql
{app="patroni"} |= "on_role_change" | regexp `node=(?P<n>\S+) role=(?P<role>\w+)` | line_format "{{.n}} -> {{.role}}"
```

**Метрики из логов** — для панелей и оповещений:

```logql
sum by (app) (count_over_time({app=~".+"}[5m]))                  строк за 5 минут
sum by (node) (count_over_time({app="patroni"} |~ "ERROR|FATAL" [1h]))   ошибок за час
count_over_time({app="patroni"} |= "role=primary" [1h])           смен лидера за час
quantile_over_time(0.95, {app="patroni"} |= "duration:" | regexp `duration: (?P<ms>[\d.]+) ms` | unwrap ms [10m]) by (node)
                                                                  95-й перцентиль длительности
```

`unwrap` берёт число из поля для агрегации.

Метки должны быть с небольшим числом значений: кластер, узел, приложение. Номер процесса, текст запроса, длительность в метки не кладут — каждая комбинация меток создаёт отдельный поток и раздувает индекс Loki. Такие значения разбирают в запросе.

Loki 3 сам добавляет метки `service_name` (из `app`) и `detected_level` (уровень из текста строки).

Документация LogQL: https://grafana.com/docs/loki/latest/query/
