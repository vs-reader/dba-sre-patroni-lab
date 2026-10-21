# Логи Patroni и PostgreSQL: Vector и Loki

Vector на каждом узле читает журнал службы `patroni.service`, отбрасывает шум, расставляет метки и отправляет строки в Loki. Grafana показывает их рядом с метриками.

```
узлы db01..db03                                   ВМ monitoring
journald: patroni.service   ──►   Vector   ──►   Loki :3100   ──►   Grafana
(Patroni, PostgreSQL,             разбор,        хранение 48 ч      Explore, панели
 обработчик role-event)           фильтр, метки
```

В одном журнале пишут три источника:

| Компонент | Пример строки |
| --- | --- |
| Patroni | `2026-10-21 10:59:58,707 INFO: no action. I am (db01), a secondary, ...` |
| PostgreSQL | `2026-10-21 08:18:37.009 UTC [4601] ERROR:  division by zero` |
| Обработчик `role-event` | `action=on_role_change node=db03 role=primary previous=none cluster=demo` |

87 % строк Patroni — служебное «no action. I am…» раз в 10 секунд. Vector их не отправляет.

## Установка через Ansible

После `just monitoring`:

```bash
just logging
```

`logging.yml` ставит Loki на ВМ `monitoring`, Vector на узлы `database` и добавляет источник Loki в Grafana. Версии и контрольные суммы — в `vars.yml`.

## Установка вручную

### Loki (ВМ monitoring)

```bash
cd /tmp
curl -fLO https://github.com/grafana/loki/releases/download/v3.7.9/loki_3.7.9_amd64.deb
echo "9647b50011ea4eb6d44b82bf708b3eb4fa5d837b33a52741cdda5f912f6cd45d  loki_3.7.9_amd64.deb" | sha256sum -c
sudo apt-get install -y ./loki_3.7.9_amd64.deb
sudo install -d -o loki -g nogroup -m 750 /var/lib/loki
```

Пакет сразу запускает Loki с учебной конфигурацией: данные в `/tmp/loki`, уровень журнала `debug`. Замените `/etc/loki/config.yml` содержимым `templates/loki.yml.j2`, подставив вместо `{{ ansible_host }}` адрес ВМ:

```bash
sudo nano /etc/loki/config.yml
sudo systemctl restart loki
curl http://IP_1:3100/ready
```

Ожидаем `ready`. Первые 15 секунд Loki отвечает `Ingester not ready`, это нормально.

### Vector (каждый узел)

```bash
cd /tmp
curl -fLO https://github.com/vectordotdev/vector/releases/download/v0.60.0/vector_0.60.0-1_amd64.deb
echo "985f74a8e07ac8efabc891324435451823e77da5b98b636bd7594f402db41219  vector_0.60.0-1_amd64.deb" | sha256sum -c
sudo apt-get install -y ./vector_0.60.0-1_amd64.deb
```

Пакет создаёт пользователя `vector` в группе `systemd-journal`, поэтому журнал он читает без дополнительных прав. Служба после установки не запущена.

Скопируйте `templates/vector.yaml.j2` в `/etc/vector/vector.yaml` и замените:
- `{{ cluster_name }}` на `demo`,
- `{{ inventory_hostname }}` на имя узла (`db01`),
- `{{ loki_url }}` на `http://IP_1:3100`,
- `{{ '{{' }} cluster {{ '}}' }}` и остальные метки в `sinks.loki.labels` на `{{ cluster }}`, `{{ node }}` и т. д.

```bash
sudo vector validate --no-environment /etc/vector/vector.yaml
sudo systemctl enable --now vector
journalctl -u vector -n 20
```

Ожидаем `Validated` и службу `active`.

### Источник в Grafana

Connections → Data sources → Add → Loki, URL `http://IP_1:3100` → Save & test.

## Проверка

В Grafana: Explore → источник Loki.

```logql
{cluster="demo", component="role-event"}
```

После `just switchover db02` — две строки: `role=primary` на новом лидере и `role=replica` на прежнем.

```logql
{cluster="demo"} |= "no action"
```

Пусто: шум отфильтрован Vector.

Ошибка и медленный запрос для проверки (на лидере; если порт изменён, добавьте `-p` с `pg_port`):

```bash
sudo -u postgres psql -XAtqc "select 1/0"
sudo -u postgres psql -Xq -c "set log_min_duration_statement = 0" -c "select pg_sleep(0.3)"
```

```logql
{cluster="demo", component="postgresql", level="ERROR"}
{cluster="demo", component="postgresql"} | json | duration_ms > 200
```

Без Grafana — через API Loki:

```bash
curl -s -G http://IP_1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={cluster="demo", component="role-event"}' \
  --data-urlencode 'since=1h'
curl -s http://IP_1:3100/loki/api/v1/label/component/values
```

## LogQL: основы

Запрос состоит из выбора потоков и конвейера обработки:

```
{метки}  | фильтры  | разбор  | условия  | формат
```

**Выбор потоков** — обязательная часть, по меткам:

```logql
{cluster="demo"}                          равно
{component!="patroni"}                    не равно
{level=~"ERROR|FATAL|PANIC"}              регулярное выражение
{cluster="demo", node!~"db0[12]"}         не совпадает
```

Хотя бы одна метка должна быть с `=` или `=~`, иначе Loki отклонит запрос.

**Фильтры по тексту строки** — самые быстрые после меток:

```logql
{cluster="demo"} |= "timeout"             содержит
{cluster="demo"} != "checkpoint"          не содержит
{cluster="demo"} |~ "(?i)connection.*refused"   регулярное выражение
{cluster="demo"} !~ "LOG:  (checkpoint|connection)"
```

**Разбор** — превращает строку в поля:

```logql
| json                                    поля из JSON
| logfmt                                  key=value
| regexp `role=(?P<role>\w+)`             именованные группы
| pattern "<_> <_> <_> [<pid>] <lvl>:  <msg>"   по шаблону
```

Строки в нашем Loki — JSON: `{"message": "...", "duration_ms": 301.9}`. Чтобы разбирать сам текст, сначала достаём его: `| json | line_format "{{.message}}"`.

**Условия по полям** после разбора:

```logql
{component="postgresql"} | json | duration_ms > 200
{component="role-event"} | json | line_format "{{.message}}" | logfmt | role="primary"
{component="postgresql"} | json | line_format "{{.message}}" | pattern "<_> <_> <_> [<pid>] <lvl>:  <msg>" | lvl="ERROR"
```

**Форматирование вывода:**

```logql
{component="role-event"} | json | line_format "{{.message}}" | logfmt | line_format "{{.node}} -> {{.role}}"
```

**Метрики из логов** — для панелей и оповещений:

```logql
sum by (component) (count_over_time({cluster="demo"}[5m]))     строк за 5 минут
sum by (node) (rate({level="ERROR"}[5m]))                      ошибок в секунду
count_over_time({component="role-event"} |= "role=primary" [1h])   смен лидера за час
quantile_over_time(0.95, {component="postgresql"} | json | unwrap duration_ms [10m]) by (node)
                                                               95-й перцентиль длительности
```

`unwrap` берёт числовое поле как значение для агрегации.

Метки должны быть с небольшим числом значений: кластер, узел, компонент, уровень. Номер процесса, текст запроса, длительность в метки не кладут — каждая уникальная комбинация меток создаёт отдельный поток и раздувает индекс Loki. Такие значения разбирают в запросе (`| json`, `| regexp`).

Loki 3 сам добавляет метки `service_name` (из `component`) и `detected_level` (из `level`).

## Vector: основы

Конфигурация — три вида блоков, связанных через `inputs`:

```yaml
sources:      откуда читать (journald, file, syslog, kafka ...)
transforms:   что делать (remap, filter, route, sample, dedupe ...)
sinks:        куда отправлять (loki, prometheus_exporter, file, console ...)
```

**remap** — изменение события на языке VRL (Vector Remap Language). Событие доступно как `.`, поля — `.message`, `.SYSLOG_IDENTIFIER`.

```
.env = "lab"                                  добавить поле
del(.PRIORITY)                                удалить поле
.level = upcase(string!(.level))              string! — проверка типа, ошибка останавливает событие
.level = parse_regex(string!(.message), r'(?P<lvl>[A-Z]+):').lvl ?? "INFO"
                                              ?? — значение по умолчанию при ошибке
if contains(string!(.message), "FATAL") { .level = "FATAL" }
parsed, err = parse_json(string!(.message))   ошибку можно обработать
if err == null { .user = parsed.user }
. = {"message": .message, "node": "db01"}     заменить событие целиком
abort                                         отбросить событие
```

Функции с `!` останавливают обработку при ошибке, без `!` возвращают ошибку вторым значением или требуют `??`. VRL проверяет типы заранее: `vector validate` найдёт ошибку до запуска. Некоторые слова зарезервированы: переменную `duration` назвать нельзя.

**filter** — пропустить только подходящие события:

```yaml
drop_noise:
  type: filter
  inputs: [parse]
  condition: '!contains(string!(.message), "no action. I am")'
```

**route** — разложить поток по веткам:

```yaml
by_component:
  type: route
  inputs: [parse]
  route:
    postgresql: '.component == "postgresql"'
    patroni: '.component == "patroni"'
```

Дальше `inputs: [by_component.postgresql]`.

**Отладка:**

```bash
vector validate /etc/vector/vector.yaml       проверить конфигурацию
vector tap --outputs-of parse                 события после transform в реальном времени
vector top                                    сколько событий проходит через каждый блок
```

Для `tap` и `top` в конфигурацию добавляют `api: {enabled: true}`.

Песочница VRL: https://playground.vrl.dev
