# Environment Variables для микросервисов

## Архитектура

Все переменные окружения для подключения к инфраструктуре хранятся в **централизованном ConfigMap** и автоматически пробрасываются во все микросервисы.

## Где хранятся URLs

### ConfigMap: `common-env`

**Файл:** `infra/k8s/common-env-configmap.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: common-env
  namespace: dev-infra
data:
  # PostgreSQL/Citus
  DATABASE_URL: "postgresql://app:app@citus-coordinator.dev-infra.svc.cluster.local:5432/app"
  POSTGRES_HOST: "citus-coordinator.dev-infra.svc.cluster.local"
  POSTGRES_PORT: "5432"
  POSTGRES_USER: "app"
  POSTGRES_PASSWORD: "app"
  POSTGRES_DB: "app"
  
  # Redis
  REDIS_URL: "redis://redis.dev-infra.svc.cluster.local:6379"
  REDIS_HOST: "redis.dev-infra.svc.cluster.local"
  REDIS_PORT: "6379"
  
  # Kafka (Redpanda)
  KAFKA_BROKERS: "redpanda.dev-infra.svc.cluster.local:9092"
  KAFKA_BOOTSTRAP_SERVERS: "redpanda.dev-infra.svc.cluster.local:9092"
  
  # Schema Registry
  SCHEMA_REGISTRY_URL: "http://schema-registry.dev-infra.svc.cluster.local:8081"
  
  # Observability
  LOKI_URL: "http://loki.dev-infra.svc.cluster.local:3100"
  GRAFANA_URL: "http://grafana.dev-infra.svc.cluster.local:3000"
  
  # Environment
  NODE_ENV: "development"
  GO_ENV: "development"
  PYTHON_ENV: "development"
  PHP_ENV: "development"
```

## Как использовать в микросервисе

### Kubernetes Deployment

Используйте `envFrom` для импорта всех переменных:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-service
spec:
  template:
    spec:
      containers:
      - name: my-service
        image: my-service:latest
        
        # ✅ Импортировать ВСЕ переменные из ConfigMap
        envFrom:
        - configMapRef:
            name: common-env
        
        # Опционально: переопределить или добавить свои
        env:
        - name: PORT
          value: "8080"
        - name: MY_SERVICE_SECRET
          valueFrom:
            secretKeyRef:
              name: my-service-secrets
              key: api-key
```

### Примеры для разных языков

#### Node.js

```javascript
// Все переменные доступны через process.env
const databaseUrl = process.env.DATABASE_URL;
const redisUrl = process.env.REDIS_URL;
const kafkaBrokers = process.env.KAFKA_BROKERS.split(',');

console.log('Connecting to:', {
  database: databaseUrl,
  redis: redisUrl,
  kafka: kafkaBrokers
});
```

#### Go

```go
package main

import "os"

func main() {
    databaseURL := os.Getenv("DATABASE_URL")
    redisURL := os.Getenv("REDIS_URL")
    kafkaBrokers := os.Getenv("KAFKA_BROKERS")
    
    // Use the variables
}
```

#### Python

```python
import os

database_url = os.environ['DATABASE_URL']
redis_url = os.environ['REDIS_URL']
kafka_brokers = os.environ['KAFKA_BROKERS']

print(f"Database: {database_url}")
print(f"Redis: {redis_url}")
print(f"Kafka: {kafka_brokers}")
```

#### PHP

```php
<?php

$databaseUrl = getenv('DATABASE_URL');
$redisUrl = getenv('REDIS_URL');
$kafkaBrokers = getenv('KAFKA_BROKERS');

echo "Database: " . $databaseUrl . "\n";
echo "Redis: " . $redisUrl . "\n";
echo "Kafka: " . $kafkaBrokers . "\n";
```

## Доступные переменные

### PostgreSQL/Citus

```bash
DATABASE_URL=postgresql://app:app@citus-coordinator.dev-infra.svc.cluster.local:5432/app
POSTGRES_HOST=citus-coordinator.dev-infra.svc.cluster.local
POSTGRES_PORT=5432
POSTGRES_USER=app
POSTGRES_PASSWORD=app
POSTGRES_DB=app
```

**Использование:**
```javascript
// Node.js с pg
const { Pool } = require('pg');
const pool = new Pool({ connectionString: process.env.DATABASE_URL });

// TypeORM / Prisma
const dataSource = new DataSource({ url: process.env.DATABASE_URL });
```

### Redis

```bash
REDIS_URL=redis://redis.dev-infra.svc.cluster.local:6379
REDIS_HOST=redis.dev-infra.svc.cluster.local
REDIS_PORT=6379
```

**Использование:**
```javascript
// Node.js с ioredis
const Redis = require('ioredis');
const redis = new Redis(process.env.REDIS_URL);

// Go с go-redis
client := redis.NewClient(&redis.Options{
    Addr: os.Getenv("REDIS_HOST") + ":" + os.Getenv("REDIS_PORT"),
})
```

### Kafka (Redpanda)

```bash
KAFKA_BROKERS=redpanda.dev-infra.svc.cluster.local:9092
KAFKA_BOOTSTRAP_SERVERS=redpanda.dev-infra.svc.cluster.local:9092
```

**Использование:**
```javascript
// Node.js с kafkajs
const { Kafka } = require('kafkajs');
const kafka = new Kafka({
  brokers: process.env.KAFKA_BROKERS.split(',')
});

// Go с sarama
config := sarama.NewConfig()
brokers := strings.Split(os.Getenv("KAFKA_BROKERS"), ",")
client, err := sarama.NewClient(brokers, config)
```

### Schema Registry

```bash
SCHEMA_REGISTRY_URL=http://schema-registry.dev-infra.svc.cluster.local:8081
```

**Использование:**
```javascript
// Node.js с @kafkajs/confluent-schema-registry
const { SchemaRegistry } = require('@kafkajs/confluent-schema-registry');
const registry = new SchemaRegistry({
  host: process.env.SCHEMA_REGISTRY_URL
});
```

### Observability (Loki, Grafana)

```bash
LOKI_URL=http://loki.dev-infra.svc.cluster.local:3100
GRAFANA_URL=http://grafana.dev-infra.svc.cluster.local:3000
```

**Использование:**
```javascript
// Отправка логов в Loki
const winston = require('winston');
const LokiTransport = require('winston-loki');

const logger = winston.createLogger({
  transports: [
    new LokiTransport({
      host: process.env.LOKI_URL,
      labels: { app: 'my-service' }
    })
  ]
});
```

## Переопределение переменных

### Service-specific secrets

Для чувствительных данных используйте Secrets:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-service-secrets
  namespace: dev-infra
type: Opaque
stringData:
  api-key: "super-secret-key"
  jwt-secret: "another-secret"
```

**В Deployment:**
```yaml
envFrom:
- configMapRef:
    name: common-env
env:
- name: API_KEY
  valueFrom:
    secretKeyRef:
      name: my-service-secrets
      key: api-key
```

### Переопределение ConfigMap значений

Если нужно переопределить значение из `common-env`:

```yaml
envFrom:
- configMapRef:
    name: common-env
env:
- name: DATABASE_URL
  value: "postgresql://custom:custom@custom-db:5432/custom"
```

⚠️ **Последняя переменная в `env` имеет приоритет над `envFrom`**

## Локальная разработка (вне кластера)

### Option 1: Port-forward + localhost URLs

```bash
# Port-forward сервисы
kubectl port-forward -n dev-infra svc/citus-coordinator 5432:5432 &
kubectl port-forward -n dev-infra svc/redis 6379:6379 &
kubectl port-forward -n dev-infra svc/redpanda 19092:9092 &

# В .env файле
DATABASE_URL=postgresql://app:app@localhost:5432/app
REDIS_URL=redis://localhost:6379
KAFKA_BROKERS=localhost:19092
```

### Option 2: Экспорт из кластера

```bash
# Получить все переменные из ConfigMap
kubectl get configmap common-env -n dev-infra -o jsonpath='{.data}' | jq -r 'to_entries[] | "\(.key)=\(.value)"' > .env

# Заменить cluster URLs на localhost
sed -i '' 's/dev-infra.svc.cluster.local/localhost/g' .env
sed -i '' 's/:9092/:19092/g' .env  # Redpanda external port
```

### Option 3: Makefile команда

```bash
# Добавьте в Makefile
export-env:
kubectl get configmap common-env -n dev-infra -o jsonpath='{.data}' | \
jq -r 'to_entries[] | "\(.key)=\(.value)"' | \
sed 's/dev-infra.svc.cluster.local/localhost/g' | \
sed 's/:9092/:19092/g' > .env.local
@echo "✓ Environment exported to .env.local"
```

## Обновление переменных

### 1. Отредактировать ConfigMap

```bash
vim infra/k8s/common-env-configmap.yaml
```

### 2. Применить изменения

```bash
kubectl apply -f infra/k8s/common-env-configmap.yaml
```

### 3. Перезапустить поды (если нужно)

```bash
kubectl rollout restart deployment/my-service -n dev-infra
```

Или через Tilt - изменения применятся автоматически.

## Best Practices

### ✅ DO

- Используйте `envFrom` для импорта всех общих переменных
- Храните секреты в `Secret`, а не в `ConfigMap`
- Используйте разные ConfigMap для разных окружений (dev, staging, prod)
- Документируйте дополнительные переменные в README сервиса

### ❌ DON'T

- Не хардкодите URLs в коде
- Не коммитьте секреты в Git
- Не дублируйте переменные в каждом Deployment
- Не используйте production credentials в dev окружении

## Production окружение

Для production создайте отдельный ConfigMap:

```yaml
# infra/k8s/prod-env-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: common-env
  namespace: production
data:
  DATABASE_URL: "postgresql://prod_user:${DB_PASSWORD}@prod-db.internal:5432/prod_db"
  REDIS_URL: "redis://prod-redis.internal:6379"
  # ... production values
```

## Проверка переменных в поде

```bash
# Посмотреть все переменные
kubectl exec -it deployment/my-service -n dev-infra -- env | sort

# Проверить конкретную переменную
kubectl exec -it deployment/my-service -n dev-infra -- env | grep DATABASE_URL

# Интерактивная сессия
kubectl exec -it deployment/my-service -n dev-infra -- sh
$ echo $DATABASE_URL
$ echo $REDIS_URL
```

## Troubleshooting

### Переменные не видны в контейнере

1. Проверьте что ConfigMap создан:
   ```bash
   kubectl get configmap common-env -n dev-infra
   ```

2. Проверьте что в Deployment есть `envFrom`:
   ```bash
   kubectl get deployment my-service -n dev-infra -o yaml | grep -A 5 envFrom
   ```

3. Перезапустите под:
   ```bash
   kubectl delete pod -l app=my-service -n dev-infra
   ```

### Неправильные значения

ConfigMap не обновляется автоматически в запущенных подах. После изменения ConfigMap нужно:

```bash
kubectl rollout restart deployment/my-service -n dev-infra
```

## См. также

- [Kubernetes ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/)
- [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)
- [12 Factor App - Config](https://12factor.net/config)
