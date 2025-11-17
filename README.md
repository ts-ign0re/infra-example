# Developer Infra Guide

## Prerequisites

- make, bash, curl, jq, kubectl
- Local Kubernetes cluster (Docker Desktop Kubernetes, kind, или minikube)
- Docker (для образов и k8s)

## Quick Start (Tilt + Kubernetes)

На MacOS + установленный OrbStack + Активированный в настройках K8S не требуется ничего из нижеперечисленного. Достаточно выполнить команду `make tilt-up` и все заведется

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

- Сид создаёт тенанта 10001. Таблица `tenants(id bigint primary key, created_at timestamptz)` распределена по `id` и инициализируется через Job.
- Создать нового тенанта:
  INSERT INTO tenants(id) VALUES (10002);

- Распределять «тенантские» таблицы по `tenant_id` и коллокировать с `tenants`:
  SELECT create_distributed_table('your_table', 'tenant_id', colocate_with => 'tenants');

- Разместить данные тенанта на конкретном воркере:
  1) Узнать shard id: SELECT citus_get_shard_id_for_distribution_column('tenants'::regclass, 10002);
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
- Ключ сообщения Kafka: aggregate_id; рекомендуемые заголовки: tenant_id (numeric, e.g. 10001), version
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

## Observability (Dev/Stage)

- По умолчанию поднимается вместе с `make tilt-up` (Loki, Promtail, Grafana загружаются из infra/Tiltfile).
- Ручная установка/снос (если нужно без Tilt):
  make obs-up
  make obs-down

- Grafana:
  kubectl -n dev-infra port-forward svc/grafana 3000:3000
  Откройте http://localhost:3000 (admin/admin). Datasource Loki уже настроен.

- Promtail собирает stdout всех pod’ов; фильтруйте по labels (namespace=dev-infra, app=<service>).

– Для доступа к UI Grafana при работе через Tilt уже есть port‑forward 3000 → 3000.

## Logging (Loki)

- Default (recommended): микросервисы пишут логи в stdout; Promtail (DaemonSet) подбирает логи контейнеров и отправляет их в Loki.
  - Автолейблы: `namespace`, `pod`, `app`, `container`, `node` (см. promtail relabel_configs).
  - В dev использован мультитенантный Loki; для системных/инфра‑логов Promtail шлёт в tenant 10001.

- Direct push (пер‑запросная мультитенантность, вариант B): микросервисы сами пушат логи в Loki и проставляют tenant из входящего HTTP‑заголовка клиента.
  - Никогда не берите tenant из env — только из входящего запроса.
  - Какой заголовок? Рекомендуем `X-Tenant-Id: <numeric>`; далее используйте это же значение для `X-Scope-OrgID` при пуше в Loki.
  - Эндпоинт в кластере: `http://loki:3100/loki/api/v1/push`.
  - Для локального сервиса вне кластера:
    - Порт‑форвард: `kubectl -n dev-infra port-forward svc/loki 3100:3100`
    - В `.env`: `LOKI_URL=http://localhost:3100`
  - Пример curl:
    ```bash
    ts_ns=$(( $(date +%s) * 1000000000 ))
    json='{"streams":[{"stream":{"service":"my-api","env":"dev"},"values":[["'"$ts_ns"'","hello from my-api"]]}]}'
    curl -s -o /dev/null -w "%{http_code}\n" \
      -H 'Content-Type: application/json' \
      -H "X-Scope-OrgID: ${TENANT_ID_FROM_REQUEST}" \
      -X POST --data "$json" "$LOKI_URL/loki/api/v1/push"
    # Ожидаемый код: 204
    ```
  - Минимальные лейблы в stream: `service`, `env`, `version`.
  - Не логируйте tenant в лейблах/теле, если это нарушает требования безопасности; достаточно заголовка `X-Scope-OrgID`.

- Grafana:
  - Explore → Datasource Loki (настроен с `X-Scope-OrgID: 10001` для dev‑обзора инфра‑логов).
  - Примеры запросов: `{service="my-api"}`, `{namespace="dev-infra"}`.

### Клиентские примеры (Direct push)

- Node.js (Express)
```js
import fetch from 'node-fetch';

const LOKI_URL = process.env.LOKI_URL || 'http://loki:3100';

export async function logToLoki(req, message, labels = {}) {
  const tenant = req.get('X-Tenant-Id'); // numeric, required
  if (!tenant) return; // or 400/skip
  const tsNs = BigInt(Date.now()) * 1000000n;
  const stream = { stream: { service: 'my-api', env: 'dev', ...labels }, values: [[tsNs.toString(), message]] };
  await fetch(`${LOKI_URL}/loki/api/v1/push`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'X-Scope-OrgID': tenant },
    body: JSON.stringify({ streams: [stream] }),
  });
}
```

- Go (net/http)
```go
tenant := r.Header.Get("X-Tenant-Id")
if tenant != "" {
  ts := time.Now().UnixNano()
  body := fmt.Sprintf(`{"streams":[{"stream":{"service":"my-api","env":"dev"},"values":[["%d","%s"]]}]}`,
    ts, "hello from go")
  req, _ := http.NewRequest("POST", os.Getenv("LOKI_URL")+"/loki/api/v1/push", strings.NewReader(body))
  req.Header.Set("Content-Type", "application/json")
  req.Header.Set("X-Scope-OrgID", tenant)
  http.DefaultClient.Do(req)
}
```

- PHP
```php
$tenant = $_SERVER['HTTP_X_TENANT_ID'] ?? null;
if ($tenant) {
  $ts = (int)(microtime(true) * 1e9);
  $json = json_encode([ 'streams' => [[
    'stream' => ['service' => 'my-api', 'env' => 'dev'],
    'values' => [[strval($ts), 'hello from php']]
  ]]]);
  $ch = curl_init(getenv('LOKI_URL').'/loki/api/v1/push');
  curl_setopt_array($ch, [
    CURLOPT_HTTPHEADER => ['Content-Type: application/json', 'X-Scope-OrgID: '.$tenant],
    CURLOPT_POSTFIELDS => $json,
    CURLOPT_RETURNTRANSFER => true,
  ]);
  curl_exec($ch);
  curl_close($ch);
}
```

Validation tips
- Требуйте numeric `X-Tenant-Id`, проверяйте на диапазон/доступ.
- При отсутствии/невалидности — не пушьте в Loki (или используйте служебный tenant для ошибок авторизации).
- Добавляйте лейблы `service`, `env`, `version`, чтобы удобно искать логи.

## Как добавить Git Submodule

```bash
git submodule add git@github.com:ts-ign0re/react-router-shadcn-starter.git packages/tenants-dashboard
```

### Где
1. `git@github.com:ts-ign0re/react-router-shadcn-starter.git` - URL репозитория который требуется подключить к системе
2. `packages/tenants-dashboard` - путь к папке, в которую будет добавлен репозиторий со всей историей
