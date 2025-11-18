[🇷🇺 Русский](README.md) | [🇬🇧 English](README.en.md)

---

# Руководство по инфраструктуре разработки

> Единая инфраструктура разработки для платформы микросервисов

## Требования

- make, bash, curl, jq, kubectl
- Локальный Kubernetes кластер (Docker Desktop Kubernetes, kind, или minikube)
- Docker (для образов и k8s)

## 📚 Документация

### Для новичков (читать по порядку!)
1. **[Настройка инфраструктуры](docs/01-SETUP-INFRASTRUCTURE.md)** - Поднимаем Tilt + Kubernetes (ПЕРВЫЙ ШАГ!)
2. **[Быстрый старт](docs/02-QUICKSTART.md)** - Подключение к сервисам и проверка работоспособности

### Разработка
- **[03. Переменные окружения](docs/03-ENVIRONMENT-VARS.md)** - Конфигурация и доступ к инфраструктуре
- **[04. Руководство по Tiltfile](docs/04-TILTFILE-GUIDE.md)** - Настройка Tilt для ваших сервисов
- **[05. Руководство по сервисам](docs/05-SERVICES-GUIDE.md)** - Создание и разработка микросервисов

### Production
- **[06. Production Deployment](docs/06-PRODUCTION-DEPLOYMENT.md)** - CI/CD и продакшен деплой

### Архитектура
- **[07. Спецификации архитектуры](docs/07-ARCHITECTURE-SPECS.md)** - Event sourcing, Kafka, архитектура БД
- **[08. План инфраструктуры](docs/08-INFRA-PLAN.md)** - План настройки инфраструктуры

## Быстрый старт (для новичков)

⚠️ **Перед началом работы обязательно прочитайте документацию по порядку:**

1. **[01. Настройка инфраструктуры](docs/01-SETUP-INFRASTRUCTURE.md)** - Как поднять Tilt + Kubernetes (читать ПЕРВЫМ!)
2. **[02. Быстрый старт](docs/02-QUICKSTART.md)** - Как подключиться к сервисам после запуска

### Команды для запуска

```bash
# 1. Скопируйте окружение
cp infra/.env.sample infra/.env

# 2. Поднимите инфраструктуру (Tilt установится автоматически)
make tilt-up

# 3. Дождитесь готовности сервисов
make infra-wait

# 4. Проверка работоспособности
make infra-test

# 5. Зарегистрируйте Avro-схемы
make register-schemas
```

**Полезные команды:**
- `make integration` - полный one-shot прогон (поднять и проверить)
- `make tilt-down` - остановка Tilt
- `make infra-down` - полная очистка

💡 **MacOS + OrbStack:** Если у вас установлен OrbStack с активированным K8S, просто выполните `make tilt-up`

## Подключение: Порты и сервисы

- Postgres/Citus (coordinator): localhost:5432
- Schema Registry: http://localhost:8081
- Redis: localhost:6379
- Redpanda (Kafka):
  - Broker: localhost:19092
  - Admin API: localhost:9644

Проброс портов выполняет Tilt (см. infra/Tiltfile). В k8s ресурсы разворачиваются в namespace `dev-infra`.

## Переменные окружения

- Основной файл окружения: `infra/.env` (создайте из `infra/.env.sample`)
- Ключевые переменные:
  - `DATABASE_URL=postgresql://app:app@localhost:5432/app` - подключение к PostgreSQL/Citus
  - `REDIS_URL=redis://localhost:6379` - подключение к Redis
  - `KAFKA_BROKERS=localhost:19092` - Kafka broker
  - `SCHEMA_REGISTRY_URL=http://localhost:8081` - Schema Registry
  - `LOKI_URL=http://localhost:3100` - Loki для логирования
  - `TOPIC_*` - имена Kafka топиков (V1_BETS, V1_PAYMENTS, etc.)
  - `K8S_NAMESPACE=dev-infra` - namespace в Kubernetes

Примечания:
- Для k8s значения берутся из манифестов `infra/k8s/*.yaml` и пробросов Tilt
- Для запуска через Docker Compose: `USE_DOCKER=1 make infra-up`

## База данных (Postgres/Citus)

- **Connection String:** `DATABASE_URL=postgresql://app:app@localhost:5432/app`
- Подключение через psql:
  ```bash
  psql "postgresql://app:app@localhost:5432/app"
  # или с переменной окружения:
  psql $DATABASE_URL
  ```

- Примеры использования в коде:
  ```javascript
  // Node.js
  const { Pool } = require('pg');
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  ```
  ```php
  // PHP
  $dsn = getenv('DATABASE_URL');
  $pdo = new PDO($dsn);
  ```
  ```python
  # Python
  import os
  import psycopg2
  conn = psycopg2.connect(os.environ['DATABASE_URL'])
  ```

### Тенанты в Citus

- Сид создаёт тенанта 10001. Таблица `tenants(id bigint primary key, created_at timestamptz)` распределена по `id` и инициализируется через Job.
- Создать нового тенанта:
  ```sql
  INSERT INTO tenants(id) VALUES (10002);
  ```

- Распределять «тенантские» таблицы по `tenant_id` и коллокировать с `tenants`:
  ```sql
  SELECT create_distributed_table('your_table', 'tenant_id', colocate_with => 'tenants');
  ```

- Разместить данные тенанта на конкретном воркере:
  1) Узнать shard id: 
     ```sql
     SELECT citus_get_shard_id_for_distribution_column('tenants'::regclass, 10002);
     ```
  2) Переместить шард: 
     ```sql
     SELECT citus_move_shard_placement(<shard_id>, old_node, old_port, 
       'citus-worker-0.citus-worker.dev-infra.svc.cluster.local', 5432);
     ```
  
  В dev среде единственный воркер, поэтому перемещение обычно не требуется.

## Redis

- **Connection String:** `REDIS_URL=redis://localhost:6379`
- Примеры использования:
  ```javascript
  // Node.js (ioredis)
  const Redis = require('ioredis');
  const redis = new Redis(process.env.REDIS_URL);
  ```
  ```python
  # Python
  import os
  import redis
  r = redis.from_url(os.environ['REDIS_URL'])
  ```
  ```php
  // PHP
  $redis = new Redis();
  $redis->connect(parse_url(getenv('REDIS_URL'), PHP_URL_HOST), 6379);
  ```

## Redpanda (Kafka)

- **Brokers:** `KAFKA_BROKERS=localhost:19092`
- Примеры использования:
  ```javascript
  // Node.js (KafkaJS)
  const { Kafka } = require('kafkajs');
  const kafka = new Kafka({
    brokers: process.env.KAFKA_BROKERS.split(',')
  });
  ```
  ```python
  # Python (kafka-python)
  from kafka import KafkaProducer
  import os
  producer = KafkaProducer(bootstrap_servers=os.environ['KAFKA_BROKERS'].split(','))
  ```
  ```go
  // Go (sarama)
  brokers := strings.Split(os.Getenv("KAFKA_BROKERS"), ",")
  config := sarama.NewConfig()
  producer, _ := sarama.NewSyncProducer(brokers, config)
  ```

- CLI утилита rpk:
  ```bash
  rpk cluster info --brokers $KAFKA_BROKERS
  rpk topic create V1_SYSTEM -p 1 -r 1 --brokers $KAFKA_BROKERS
  echo 'hello' | rpk topic produce V1_SYSTEM --brokers $KAFKA_BROKERS
  rpk topic consume V1_SYSTEM -n 1 --brokers $KAFKA_BROKERS
  ```

## Schema Registry

- **URL:** `SCHEMA_REGISTRY_URL=http://localhost:8081`
- Проверка:
  ```bash
  curl -fsS $SCHEMA_REGISTRY_URL/subjects
  ```
- Регистрация схем: `make register-schemas` (использует TopicNameStrategy и ставит BACKWARD_TRANSITIVE на Subject)
- Примеры использования:
  ```javascript
  // Node.js (@kafkajs/confluent-schema-registry)
  const { SchemaRegistry } = require('@kafkajs/confluent-schema-registry');
  const registry = new SchemaRegistry({ 
    host: process.env.SCHEMA_REGISTRY_URL 
  });
  ```
  ```python
  # Python (confluent-kafka)
  from confluent_kafka.schema_registry import SchemaRegistryClient
  import os
  sr = SchemaRegistryClient({'url': os.environ['SCHEMA_REGISTRY_URL']})
  ```

## Kafka топики и именование

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

- `make tilt-up`: запустить инфраструктуру через Tilt (авто‑установка Tilt)
- `make infra-wait`: дождаться готовности всех сервисов (k8s‑aware)
- `make infra-test`: интеграционные тесты (авто-регистрирует схемы перед запуском)
- `make register-schemas`: зарегистрировать Avro схемы и задать совместимость (идемпотентно)
- `make integration`: поднять через Tilt (CI‑режим) и выполнить тесты
- `make tilt-down`: остановить Tilt
- `make infra-down`: удалить ресурсы и namespace

## Observability (Dev/Stage)

- По умолчанию поднимается вместе с `make tilt-up` (Loki, Promtail, Grafana загружаются из infra/Tiltfile).
- Ручная установка/снос (если нужно без Tilt):
  ```bash
  make obs-up
  make obs-down
  ```

- Grafana:
  ```bash
  kubectl -n dev-infra port-forward svc/grafana 3000:3000
  ```
  Откройте http://localhost:3000 (admin/admin). Datasource Loki уже настроен.

- Promtail собирает stdout всех pod'ов; фильтруйте по labels (namespace=dev-infra, app=<service>).

- Для доступа к UI Grafana при работе через Tilt уже есть port‑forward 3000 → 3000.

## Логирование (Loki)

- **По умолчанию (рекомендуется)**: микросервисы пишут логи в stdout; Promtail (DaemonSet) подбирает логи контейнеров и отправляет их в Loki.
  - Автолейблы: `namespace`, `pod`, `app`, `container`, `node` (см. promtail relabel_configs).
  - В dev использован мультитенантный Loki; для системных/инфра‑логов Promtail шлёт в tenant 10001.

- **Direct push (пер‑запросная мультитенантность, вариант B)**: микросервисы сами пушат логи в Loki и проставляют tenant из входящего HTTP‑заголовка клиента.
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

**Node.js (Express)**
```js
import fetch from 'node-fetch';

const LOKI_URL = process.env.LOKI_URL || 'http://loki:3100';

export async function logToLoki(req, message, labels = {}) {
  const tenant = req.get('X-Tenant-Id'); // numeric, required
  if (!tenant) return; // or 400/skip
  const tsNs = BigInt(Date.now()) * 1000000n;
  const stream = { 
    stream: { service: 'my-api', env: 'dev', ...labels }, 
    values: [[tsNs.toString(), message]] 
  };
  await fetch(`${LOKI_URL}/loki/api/v1/push`, {
    method: 'POST',
    headers: { 
      'content-type': 'application/json', 
      'X-Scope-OrgID': tenant 
    },
    body: JSON.stringify({ streams: [stream] }),
  });
}
```

**Go (net/http)**
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

**PHP**
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

**Советы по валидации:**
- Требуйте numeric `X-Tenant-Id`, проверяйте на диапазон/доступ.
- При отсутствии/невалидности — не пушьте в Loki (или используйте служебный tenant для ошибок авторизации).
- Добавляйте лейблы `service`, `env`, `version`, чтобы удобно искать логи.

## 🚀 Добавление микросервисов (только Git Submodules)

> **Важно:** Все сервисы ДОЛЖНЫ добавляться как Git submodules. Создание сервисов напрямую в packages/* запрещено.

### Шаг 1: Добавьте сервис как Git submodule

```bash
git submodule add git@github.com:org/your-service.git packages/your-service
git submodule update --init --recursive
```

### Шаг 2: Добавьте инфраструктуру

```bash
# Через make
make add-infra PATH=packages/your-service

# Или напрямую скриптом
./scripts/service-add-infra.sh packages/your-service
```

**Что делает скрипт:**
1. 🔍 Автоопределяет язык (Node.js, Go, Python, PHP)
2. 🐳 Генерирует оптимизированный Dockerfile
3. ☸️ Создает Kubernetes манифесты (base + overlays)
4. ⚙️ Интерактивная настройка
5. ✅ Проверяет корректность настройки

**Интерактивные подсказки:**
```
Что вы хотите добавить?
1) Dockerfile (если отсутствует)
2) Kubernetes манифесты (k8s/)
3) Всё вышеперечисленное
4) Отмена

Выберите опцию [1-4]: 3
Обнаружено: Node.js проект
Порт приложения [по умолчанию: 3000]: 8080
```

### Шаг 3: Деплой

```bash
make tilt-up
```

Tilt автоматически обнаружит сервисы, содержащие:
- `Dockerfile` в корне
- `k8s/overlays/dev/kustomization.yaml`

### Внешние репозитории

Вы также можете добавить инфраструктуру к внешним репо (вне packages/):

```bash
./scripts/service-add-infra.sh /path/to/external/repo
```
