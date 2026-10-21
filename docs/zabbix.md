# Zabbix: доступность PostgreSQL и SLI

Zabbix проверяет кластер двумя способами и считает по второму SLI и SLA:

| Проверка | Что отвечает | Где |
| --- | --- | --- |
| порт PostgreSQL на каждом узле | жив ли узел | шаблон `PostgreSQL port lab` |
| запись в кластер, как у клиента | принимает ли кластер запись | хост группы `zabbix` |

Отказ реплики даёт тревогу по порту, но клиент его не замечает. Поэтому SLI считается только по проверке записи.

## Установка через Ansible

После `just apply`:

```bash
just zabbix
just collections
just zabbix-config
```

- `zabbix.yml` — сервер и веб-интерфейс на ВМ группы `zabbix` (в `inventory.ini` это db01), агенты на всех узлах, роль `zbx_monitor` и проверка записи.
- `just collections` — один раз ставит коллекцию `community.zabbix` из `requirements.yml`, около 2 минут.
- `zabbix-config.yml` — объекты в Zabbix через API: группа, шаблон, хосты, элементы, триггеры, сервис, SLA. Повторный запуск ничего не меняет.

Веб-интерфейс: `http://IP_1/zabbix`, пользователь `Admin`, пароль в `credentials/zabbix-admin`. При первом запуске `zabbix-config.yml` заменяет стандартный пароль `zabbix` на этот.

Через SSH-туннель со своего компьютера:

```bash
ssh -p ПОРТ_ПЕРВОЙ_ВМ -N -L 8080:IP_1:80 student@ВНЕШНИЙ_АДРЕС
```

Браузер: `http://localhost:8080/zabbix`.

## Что создаётся

**Сервер.** Пакеты Zabbix 7.0 из Debian 13. Служебная база — в отдельном экземпляре PostgreSQL (`pg_createcluster 17 zabbix`, порт 5433), не в кластере Patroni: авария кластера не роняет мониторинг. Сервер подключается к базе через Unix-сокет без пароля, веб-интерфейс — по TCP с паролем из `credentials/zabbix-db`.

**Агенты.** `zabbix-agent2` на трёх узлах, настройка в `/etc/zabbix/zabbix_agent2.d/server.conf`: адрес сервера и имя хоста.

**Проверка записи.** На ВМ `zabbix` агент выполняет `psql` по трём узлам с `target_session_attrs=read-write`: libpq сам находит лидера, как клиент. Роль `zbx_monitor` (член `pg_monitor`), пароль в `/etc/zabbix/zabbix.pgpass` (0600, владелец zabbix):

```
UserParameter=pgsql.write_available[*],PGPASSFILE=/etc/zabbix/zabbix.pgpass psql "host=$1 port=$2 dbname=postgres user=zbx_monitor target_session_attrs=read-write connect_timeout=3" -XAtqc "select 1" 2>/dev/null || echo 0
```

`[*]` делает ключ параметризованным: `$1` — список узлов кластера, `$2` — порт. Одна строка обслуживает все кластеры, в Zabbix у каждого свой элемент `pgsql.write_available["IP_1,IP_2,IP_3",5432]`.
Чтобы хост Zabbix мог подключаться к чужим кластерам, `patroni.yml.j2` добавляет его адрес в `pg_hba` каждого кластера.

В `zabbix-agent2` из Debian нет плагина PostgreSQL (`pgsql.ping` — Unknown metric), поэтому проверка через `UserParameter`.

**Объекты в Zabbix:**

| Объект | Настройка | Зачем |
| --- | --- | --- |
| группа `DBA SRE lab` | | права и фильтры |
| шаблон `PostgreSQL port lab` | item `net.tcp.service[tcp,{HOST.IP},{$PG.PORT}]`, 10s, макрос `{$PG.PORT}` = 5432 | один набор проверок на все узлы |
| trigger в шаблоне | `last(...)=0`, High, тег `service=postgresql-node` | узел недоступен |
| хосты `db01..db03` | интерфейс агента, шаблон, макрос `{$PG.PORT}` из `pg_port`, тег `cluster=demo` | |
| item `pgsql.write_available["IP_1,IP_2,IP_3",5432]` | 10s, на хосте `zabbix`, по одному на кластер | доступность для клиента |
| trigger `PostgreSQL demo does not accept writes` | `max(...,30s)=0`, Disaster, тег `service=postgresql-demo` | 30 секунд без записи — авария сервиса |
| item `sli.write_availability[demo]` | Calculated, `avg(//pgsql.write_available[...],1h)*100`, % | SLI за час |
| service `PostgreSQL demo cluster` | проблемы с тегом `service=postgresql-demo` | что обещаем |
| SLA `PostgreSQL demo 99.9` | SLO 99,9, неделя | отчёт Services → SLA report |

Для каждого кластера из группы `database` создаётся свой набор: проверка записи, SLI, trigger, service и SLA.

Для SLA в `community.zabbix` нет модуля, он создаётся через API модулем `uri`.

## Проверка

```bash
sudo -u zabbix zabbix_agent2 -t 'pgsql.write_available["IP_1,IP_2,IP_3",5432]'   # на ВМ zabbix: [s|1]
zabbix_agent2 -t net.tcp.service[tcp,IP_1,5432]           # на узле: [s|1]
```

В интерфейсе: Monitoring → Latest data, группа `DBA SRE lab` — порт 1 на трёх узлах, запись 1, SLI около 100.

## Установка вручную

Те же шаги без Ansible, на ВМ Zabbix:

```bash
sudo apt-get install -y zabbix-server-pgsql zabbix-frontend-php php-pgsql apache2 libapache2-mod-php
sudo pg_createcluster 17 zabbix --port 5433 --start

read -rsp 'DB password: ' P; echo
sudo -u postgres psql -p 5433 -XAtq <<SQL
CREATE ROLE zabbix LOGIN PASSWORD '$P';
CREATE DATABASE zabbix OWNER zabbix;
SQL
for f in schema images data; do
  zcat /usr/share/zabbix-server-pgsql/$f.sql.gz | PGPASSWORD="$P" psql -XAtq -h 127.0.0.1 -p 5433 -U zabbix zabbix >/dev/null
done

printf 'DBHost=\nDBPort=5433\n' | sudo tee /etc/zabbix/zabbix_server.conf.d/database.conf
sudo systemctl restart zabbix-server
```

Веб-интерфейс: файл `/etc/zabbix/zabbix.conf.php` по образцу `templates/zabbix.conf.php.j2`, права `root:www-data 0640`. Затем:

```bash
printf 'post_max_size = 16M\nmax_execution_time = 300\nmax_input_time = 300\ndate.timezone = Europe/Moscow\n' | sudo tee /etc/php/8.4/apache2/conf.d/99-zabbix.ini
sudo sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && sudo locale-gen
sudo a2enconf zabbix-frontend-php
sudo systemctl restart apache2
```

Подводные камни Debian:
- пакет сам запускает `zabbix-server` при установке: после настройки нужен `restart`;
- веб-интерфейс читает `/etc/zabbix/zabbix.conf.php`, а не `/usr/share/zabbix/conf/`;
- конфигурация Apache из пакета рассчитана на PHP 8.2, лимиты PHP — отдельным файлом;
- без локали `en_US.UTF-8` интерфейс пишет «Locale for language en_US is not found».

Объекты в интерфейсе — по таблице выше: Data collection → Host groups, Templates (ссылки Items и Triggers в строке шаблона), Hosts; Services → Services и SLA.

## Существующий Zabbix

Если сервер уже есть, `zabbix-config.yml` можно запустить отдельно:

- пароль `Admin` положите в `credentials/zabbix-admin`;
- если имена хостов в Zabbix отличаются от имён в inventory, задайте их переменной хоста: `db01 ansible_host=... zabbix_host_name=sre-t-1`;
- если служебная база в другом экземпляре, задайте `zabbix_db_cluster` и `zabbix_db_port` в `vars.yml`;
- имена объектов включают `cluster_name`: на сервере, где объекты создавались вручную, появятся новые рядом со старыми.
