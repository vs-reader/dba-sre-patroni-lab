# Vector: базовые примеры

Vector собирает логи: читает из источника, при необходимости меняет строку и отправляет дальше. Конфигурация — YAML из трёх видов блоков, связанных через `inputs`:

```yaml
sources:      откуда читать
transforms:   что сделать со строкой
sinks:        куда отправить
```

В практике конфигурация — `templates/vector.yaml.j2`, на узле — `/etc/vector/vector.yaml`.

## 1. Журнал в Loki

```yaml
sources:
  patroni:
    type: journald
    include_units:
      - patroni.service

sinks:
  loki_patroni:
    type: loki
    inputs:
      - patroni
    endpoint: http://IP_1:3100
    encoding:
      codec: text
    labels:
      node: db01
      app: patroni
```

`labels` — метки потока в Loki, по ним потом ищут: `{app="patroni"}`.

## 2. Файл в Loki

```yaml
sources:
  grafana:
    type: file
    include:
      - /var/log/grafana/grafana.log
```

Пользователь `vector` должен иметь право читать файл. Файл Grafana принадлежит группе `grafana`, поэтому: `sudo usermod -aG grafana vector`.

## 3. Отбросить лишнее

```yaml
transforms:
  drop_noise:
    type: filter
    inputs:
      - patroni
    condition: '!contains(string!(.message), "no action. I am")'
```

Дальше строки идут уже из `drop_noise`: в получателе `inputs: [drop_noise]`.

## 4. Добавить поле и текст

```yaml
transforms:
  add_info:
    type: remap
    inputs:
      - drop_noise
    source: |
      .env = "lab"
      .message = "[" + .env + "] " + string!(.message)
```

В получателе поле можно сделать меткой: `env: "{{ env }}"`.

`remap` использует язык VRL. `.message` — текст строки, `.env` — новое поле. `string!(...)` говорит, что поле — строка: VRL проверяет типы заранее.

## 5. Разобрать строку (дальше)

```
level, err = parse_regex(string!(.message), r'(?P<lvl>ERROR|FATAL|WARNING):')
if err == null { .level = level.lvl }
```

Часто проще разбирать при запросе в Loki: `| regexp`, `| logfmt`, `| pattern` (см. [logging.md](logging.md)).

## Проверка

```bash
sudo vector validate --no-environment /etc/vector/vector.yaml   проверить конфигурацию
sudo systemctl restart vector
journalctl -u vector -n 20                                      ошибки и доступ к файлам
```

## Документация

- Обзор: https://vector.dev/docs/
- Источники: [journald](https://vector.dev/docs/reference/configuration/sources/journald/), [file](https://vector.dev/docs/reference/configuration/sources/file/)
- Преобразования: [filter](https://vector.dev/docs/reference/configuration/transforms/filter/), [remap](https://vector.dev/docs/reference/configuration/transforms/remap/)
- Получатель: [loki](https://vector.dev/docs/reference/configuration/sinks/loki/)
- Язык VRL: https://vector.dev/docs/reference/vrl/, функции: https://vector.dev/docs/reference/vrl/functions/
- Песочница VRL: https://playground.vrl.dev
