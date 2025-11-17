# Developer Infra Guide

## Prerequisites

- make, bash, curl, jq, kubectl
- Local Kubernetes cluster (Docker Desktop Kubernetes, kind, или minikube)
- Docker (для образов и k8s)

## Quick Start (Tilt + Kubernetes)

1) Скопируйте окружение:
   cp infra/.env.sample infra/.env

2) Поднимите инфраструктуру (Tilt установится автоматически):
   make tilt-up

3) Дождитесь готовности сервисов:
   make infra-wait

4) Запустите интеграционные проверки:
   make infra-test

5) Зарегистрируйте Avro‑схемы (TopicNameStrategy + BACKWARD_TRANSITIVE):
   make register-schemas

- Полный one‑shot прогон (поднять и проверить): make integration
- Остановка: make tilt-down; полная очистка: make infra-down

## Connectivity: Ports & Services

- Postgres/Citus (coordinator): localhost:5432
- Schema Registry: http://localhost:8081
- Redis: localhost:6379
- Redpanda (Kafka):
  - Broker: localhost:19092
  - Admin API: localhost:9644

Проброс портов выполняет Tilt (см. infra/Tiltfile). В k8s ресурсы разворачиваются в namespace `dev-infra`.

## Environment Variables

- Основной файл окружения: infra/.env (создайте из infra/.env.sample)
- Важные переменные:
  - K8S: `K8S_NAMESPACE=dev-infra`
  - Schema Registry: `SCHEMA_REGISTRY_URL=http://localhost:8081`, `SR_COMPATIBILITY=BACKWARD_TRANSITIVE`
  - Kafka topics: `TOPIC_BETS`, `TOPIC_PAYMENTS`, `TOPIC_BALANCES`, `TOPIC_COMPLIANCE`, `TOPIC_SYSTEM`
  - Docker Compose (опционально): `POSTGRES_*`, `SCHEMA_REGISTRY_PORT`, `REDIS_PORT`, `REDPANDA_*`

Примечания:
- Для k8s значения берутся из манифестов infra/k8s/*.yaml и пробросов Tilt; infra/.env используется скриптами и Docker Compose.
- Для запуска через Docker Compose используйте префикс: USE_DOCKER=1 make infra-up …

## Database (Postgres/Citus)

- Credentials по умолчанию: user `app`, password `app`, database `app`.
- Подключение (локально через Tilt):
  psql "host=localhost port=5432 dbname=app user=app password=app sslmode=disable"

- Примеры DSN:
  - Node.js: postgres://app:app@localhost:5432/app
  - PHP PDO: host=127.0.0.1;port=5432;dbname=app;user=app;password=app

### Тенанты в Citus

- Сид создаёт тенанта `tenant-1`. Таблица `tenants(id text primary key, created_at timestamptz)` распределена по `id` и инициализируется с помощью Job.
- Создать нового тенанта:
  INSERT INTO tenants(id) VALUES ('tenant-42');

- Распределять «тенантские» таблицы по `tenant_id` и коллокировать с `tenants`:
  SELECT create_distributed_table('your_table', 'tenant_id', colocate_with => 'tenants');

- Разместить данные тенанта на конкретном воркере:
  1) Узнать shard id: SELECT citus_get_shard_id_for_distribution_column('tenants'::regclass, 'tenant-42');
  2) Переместить шард: SELECT citus_move_shard_placement(<shard_id>, old_node, old_port, 'citus-worker-0.citus-worker.dev-infra.svc.cluster.local', 5432);
  В dev среде единственный воркер, поэтому перемещение обычно не требуется.

## Redpanda (Kafka)

- Брокер: localhost:19092
- Пример rpk:
  rpk cluster info --brokers localhost:19092
  rpk topic create V1_SYSTEM -p 1 -r 1 --brokers localhost:19092
  echo 'hello' | rpk topic produce V1_SYSTEM --brokers localhost:19092
  rpk topic consume V1_SYSTEM -n 1 --brokers localhost:19092

- Пример KafkaJS:
  const { Kafka } = require('kafkajs');
  const kafka = new Kafka({ brokers: ['localhost:19092'] });

## Schema Registry

- URL: http://localhost:8081
- Проверка:
  curl -fsS http://localhost:8081/subjects
- Регистрация схем: make register-schemas (использует TopicNameStrategy и ставит BACKWARD_TRANSITIVE на Subject)

## Kafka Topics & Naming

- Топики по контекстам: V1_BETS, V1_PAYMENTS, V1_BALANCES, V1_COMPLIANCE, V1_SYSTEM
- Субжекты SR: TopicNameStrategy → {topic}-value
- Совместимость SR: BACKWARD_TRANSITIVE
- Ключ сообщения Kafka: aggregate_id; рекомендуемые заголовки: tenant_id, version
- Поля событий:
  - TIER1 (bets/payments/balances/compliance): `event_type` (enum UPPER_SNAKE_CASE)
  - system_events: `event_type` (string, UPPER_SNAKE_CASE)

## Денежные суммы

- Всегда целые значения в «центах» (Avro long). Никаких float/double для денег.

## Команды разработчика

- make tilt-up: запустить инфраструктуру через Tilt (авто‑установка Tilt)
- make infra-wait: дождаться готовности всех сервисов (k8s‑aware)
- make infra-test: интеграционные тесты (БД транзакционно, Redis, Redpanda, SR)
- make register-schemas: зарегистрировать Avro схемы и задать совместимость
- make integration: поднять через Tilt (CI‑режим) и выполнить тесты
- make tilt-down: остановить Tilt
- make infra-down: удалить ресурсы и namespace

## Как добавить Git Submodule

```bash
git submodule add git@github.com:ts-ign0re/react-router-shadcn-starter.git packages/tenants-dashboard
```

### Где
1. `git@github.com:ts-ign0re/react-router-shadcn-starter.git` - URL репозитория который требуется подключить к системе
2. `packages/tenants-dashboard` - путь к папке, в которую будет добавлен репозиторий со всей историей
