# Services Development Guide

> **Цель:** Единый процесс добавления микросервисов в платформу с автоматической интеграцией в dev-окружение

---

## Быстрый старт

> **Важно:** Все сервисы добавляются ТОЛЬКО через Git submodules. Создание сервисов напрямую в packages/* запрещено.

### Добавление сервиса

**Шаг 1:** Добавьте сервис как Git submodule

```bash
git submodule add git@github.com:org/your-repo.git packages/your-service
git submodule update --init --recursive
```

**Шаг 2:** Добавьте инфраструктуру (Dockerfile + K8s)

```bash
# Вариант 1: через make
make add-infra PATH=packages/your-service

# Вариант 2: напрямую
./scripts/service-add-infra.sh packages/your-service
```

Скрипт:
1. 🔍 Автоматически определит язык (Node.js, Go, Python, PHP)
2. 🐳 Создаст оптимизированный Dockerfile
3. ☸️ Сгенерирует Kubernetes манифесты
4. ⚙️ Настроит Kustomize overlays (dev/prod)
5. ✅ Проверит корректность конфигурации

**Интерактивный режим:**
```bash
$ make add-infra PATH=packages/my-existing-app
# или
$ ./scripts/service-add-infra.sh packages/my-existing-app

What do you want to add?
1) Dockerfile (if missing)
2) Kubernetes manifests (k8s/)
3) All of the above
4) Cancel

Select option [1-4]: 3
Detected: Node.js project
Application port [default: 3000]: 8080
```

**Шаг 3:** Деплой

```bash
make tilt-up
```

Tilt автоматически обнаружит новый сервис и добавит его в кластер! 🎉

---

## Важные правила

### ❌ Что НЕЛЬЗЯ делать

- **Создавать сервисы напрямую в packages/**
  ```bash
  mkdir packages/my-service  # ❌ ЗАПРЕЩЕНО
  ```

- **Коммитить код сервисов в этот репозиторий**
  ```bash
  git add packages/my-service/src/  # ❌ ЗАПРЕЩЕНО
  ```

### ✅ Что НУЖНО делать

- **Добавлять сервисы только через Git submodules**
  ```bash
  git submodule add git@github.com:org/service.git packages/service  # ✅ ПРАВИЛЬНО
  ```

- **Коммитить только инфраструктурные файлы**
  ```bash
  git add packages/my-service/Dockerfile          # ✅ OK
  git add packages/my-service/k8s/                # ✅ OK
  git commit -m "Add infrastructure for my-service"
  ```

---

## Работа с Git Submodules

### Добавление submodule

```bash
git submodule add git@github.com:org/repo.git packages/service-name
```

### Клонирование репозитория с submodules

```bash
git clone --recursive git@github.com:your-org/ideas.git
# или
git clone git@github.com:your-org/ideas.git
cd ideas
git submodule update --init --recursive
```

### Обновление submodule

```bash
cd packages/service-name
git pull origin main
cd ../..
git add packages/service-name
git commit -m "Update service-name to latest"
```

### Удаление submodule

```bash
git submodule deinit packages/service-name
git rm packages/service-name
rm -rf .git/modules/packages/service-name
git commit -m "Remove service-name"
```

---

## Вариант 3: Ручная настройка (не рекомендуется)

1. **Создайте структуру сервиса:**
```bash
mkdir -p packages/my-service/{k8s/base,k8s/overlays/dev,k8s/overlays/prod}
```

2. **Скопируйте шаблонные файлы:**
```bash
cp -r packages/.template/* packages/my-service/
```

3. **Отредактируйте файлы:**
   - `Dockerfile` - добавьте инструкции сборки
   - `k8s/base/deployment.yaml` - настройте образ и порты
   - `k8s/base/service.yaml` - настройте Service
   - `.tiltignore` (опционально) - исключите файлы из hot-reload

4. **Замените плейсхолдеры:**
   - `REPLACE_SERVICE_NAME` → ваше имя сервиса

### После настройки

```bash
make tilt-up
```

Tilt автоматически обнаружит новый сервис и добавит его в кластер! 🎉

---

## Структура сервиса

Каждый сервис в `packages/` должен следовать единой структуре:

```
packages/
  my-service/
    ├── Dockerfile              # Сборка образа для dev и prod
    ├── .dockerignore           # Исключения для Docker build
    ├── .tiltignore             # Исключения для Tilt hot-reload (опционально)
    ├── k8s/
    │   ├── base/               # Базовые манифесты K8s
    │   │   ├── deployment.yaml
    │   │   ├── service.yaml
    │   │   └── kustomization.yaml
    │   └── overlays/
    │       ├── dev/            # Dev-специфичная конфигурация
    │       │   └── kustomization.yaml
    │       └── prod/           # Prod-специфичная конфигурация
    │           ├── kustomization.yaml
    │           └── image-tag.yaml  # (генерируется CI/CD)
    └── src/                    # Код сервиса
        └── ...
```

---

## Требования к сервису

### 1. Dockerfile

**Требования:**
- Multi-stage build для оптимизации размера
- Non-root user для безопасности
- Health check endpoint
- Graceful shutdown (SIGTERM)

**Пример (Node.js):**
```dockerfile
# Build stage
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
RUN npm run build

# Production stage
FROM node:20-alpine
RUN addgroup -g 1001 -S nodejs && adduser -S nodejs -u 1001
WORKDIR /app
COPY --from=builder --chown=nodejs:nodejs /app/dist ./dist
COPY --from=builder --chown=nodejs:nodejs /app/node_modules ./node_modules
USER nodejs
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD node healthcheck.js || exit 1
CMD ["node", "dist/index.js"]
```

**Пример (Go):**
```dockerfile
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY go.* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /server

FROM alpine:latest
RUN apk --no-cache add ca-certificates
RUN addgroup -g 1001 -S appuser && adduser -S appuser -u 1001 -G appuser
COPY --from=builder --chown=appuser:appuser /server /server
USER appuser
EXPOSE 8080
HEALTHCHECK --interval=30s CMD wget -qO- http://localhost:8080/health || exit 1
CMD ["/server"]
```

### 2. Kubernetes Manifests

#### `k8s/base/deployment.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-service
  labels:
    app: my-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-service
  template:
    metadata:
      labels:
        app: my-service
    spec:
      containers:
      - name: my-service
        image: my-service:latest  # Tilt/Kustomize заменит это
        ports:
        - containerPort: 3000
          name: http
        env:
        - name: NODE_ENV
          value: "production"
        - name: DATABASE_URL
          value: "postgresql://app:app@citus-coordinator.dev-infra.svc.cluster.local:5432/app"
        - name: REDIS_URL
          value: "redis://redis.dev-infra.svc.cluster.local:6379"
        - name: KAFKA_BROKERS
          value: "redpanda.dev-infra.svc.cluster.local:9092"
        - name: LOKI_URL
          value: "http://loki.dev-infra.svc.cluster.local:3100"
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /ready
            port: 3000
          initialDelaySeconds: 5
          periodSeconds: 10
```

#### `k8s/base/service.yaml`
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  labels:
    app: my-service
spec:
  type: ClusterIP
  ports:
  - port: 3000
    targetPort: http
    protocol: TCP
    name: http
  selector:
    app: my-service
```

#### `k8s/base/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml

# Общие labels для всех ресурсов
commonLabels:
  managed-by: kustomize
  service: my-service
```

#### `k8s/overlays/dev/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: dev-infra

resources:
  - ../../base

# Dev-специфичные патчи
patches:
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: my-service
      spec:
        replicas: 1
        template:
          spec:
            containers:
            - name: my-service
              env:
              - name: NODE_ENV
                value: "development"
              - name: LOG_LEVEL
                value: "debug"

# Dev образ собирается Tilt'ом
images:
  - name: my-service
    newName: my-service
    newTag: tilt-dev
```

#### `k8s/overlays/prod/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: production  # или ваш prod namespace

resources:
  - ../../base

# Prod-специфичные патчи
patches:
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: my-service
      spec:
        replicas: 3  # HA для прода
        template:
          spec:
            containers:
            - name: my-service
              resources:
                requests:
                  memory: "256Mi"
                  cpu: "200m"
                limits:
                  memory: "1Gi"
                  cpu: "1000m"

# Prod образ из registry (устанавливается CI/CD)
images:
  - name: my-service
    newName: registry.example.com/my-service
    newTag: v1.0.0  # Будет заменено в CI/CD
```

---

## Tilt Integration

### Автоматическое обнаружение

Tilt автоматически обнаруживает все сервисы в `packages/` при наличии:
1. `Dockerfile` в корне сервиса
2. `k8s/overlays/dev/kustomization.yaml`

### Hot Reload

Tilt поддерживает hot-reload для быстрой разработки:

**Для Node.js/TypeScript:**
```python
# В infra/Tiltfile (добавляется автоматически)
docker_build(
  'my-service',
  '../packages/my-service',
  live_update=[
    sync('../packages/my-service/src', '/app/src'),
    run('npm install', trigger=['../packages/my-service/package.json']),
    restart_container()
  ]
)
```

**Для Go:**
```python
docker_build(
  'my-service',
  '../packages/my-service',
  live_update=[
    sync('../packages/my-service', '/app'),
    run('go build -o /server', trigger=['../packages/my-service/**/*.go']),
    restart_container()
  ]
)
```

### Port Forwarding

Добавьте в манифест или Tilt настроит автоматически:
```python
k8s_resource('my-service', port_forwards=['8080:3000'])
```

Доступ: `http://localhost:8080`

---

## Environment Variables

### Обязательные переменные

Все сервисы имеют доступ к базовой инфраструктуре:

```bash
# PostgreSQL/Citus
DATABASE_URL=postgresql://app:app@citus-coordinator.dev-infra.svc.cluster.local:5432/app

# Redis
REDIS_URL=redis://redis.dev-infra.svc.cluster.local:6379

# Kafka (Redpanda)
KAFKA_BROKERS=redpanda.dev-infra.svc.cluster.local:9092

# Schema Registry
SCHEMA_REGISTRY_URL=http://schema-registry.dev-infra.svc.cluster.local:8081

# Loki (логирование)
LOKI_URL=http://loki.dev-infra.svc.cluster.local:3100
```

### Tenant-aware сервисы

Если сервис работает с мультитенантностью:
```yaml
env:
- name: TENANT_ID_HEADER
  value: "X-Tenant-Id"
- name: DEFAULT_TENANT_ID
  value: "10001"
```

---

## Logging

### Stdout/Stderr (рекомендуется)

Пишите логи в `stdout/stderr` - Promtail автоматически отправит их в Loki:

```javascript
// Node.js
console.log(JSON.stringify({ level: 'info', msg: 'User logged in', user_id: 123 }));
```

```go
// Go
log.Printf(`{"level":"info","msg":"User logged in","user_id":123}`)
```

### Direct Push в Loki (опционально)

Для tenant-aware логирования:

```javascript
// Node.js
async function logToLoki(req, message, labels = {}) {
  const tenant = req.get('X-Tenant-Id');
  if (!tenant) return;
  
  const ts = BigInt(Date.now()) * 1000000n;
  const stream = {
    stream: { service: 'my-service', env: 'dev', ...labels },
    values: [[ts.toString(), message]]
  };
  
  await fetch(`${process.env.LOKI_URL}/loki/api/v1/push`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Scope-OrgID': tenant
    },
    body: JSON.stringify({ streams: [stream] })
  });
}
```

---

## Health Checks

### Обязательные endpoints:

1. **`/health`** - liveness probe
   - Возвращает 200 если сервис жив
   - Проверяет критические зависимости (DB, Redis)

2. **`/ready`** - readiness probe
   - Возвращает 200 если сервис готов принимать трафик
   - Может быть не готов при старте (миграции, прогрев кеша)

**Пример (Express.js):**
```javascript
app.get('/health', async (req, res) => {
  try {
    await db.query('SELECT 1');
    res.status(200).json({ status: 'healthy' });
  } catch (err) {
    res.status(503).json({ status: 'unhealthy', error: err.message });
  }
});

app.get('/ready', (req, res) => {
  if (isReady) {
    res.status(200).json({ status: 'ready' });
  } else {
    res.status(503).json({ status: 'not ready' });
  }
});
```

---

## Database Access

### Citus (PostgreSQL)

**Connection String:**
```
postgresql://app:app@citus-coordinator.dev-infra.svc.cluster.local:5432/app
```

**Tenant Isolation:**
```sql
-- Все запросы должны фильтроваться по tenant_id
SELECT * FROM users WHERE tenant_id = $1 AND id = $2;
```

**Distributed Tables:**
```javascript
// Создание tenant-aware таблицы (миграция)
await db.query(`
  CREATE TABLE users (
    id BIGSERIAL,
    tenant_id BIGINT NOT NULL,
    email TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (tenant_id, id)
  );
  
  SELECT create_distributed_table('users', 'tenant_id', colocate_with => 'tenants');
`);
```

---

## Kafka Integration

### Producing Events

```javascript
// Node.js (KafkaJS)
const { Kafka } = require('kafkajs');
const avro = require('avsc');

const kafka = new Kafka({
  brokers: process.env.KAFKA_BROKERS.split(',')
});

const producer = kafka.producer();
const schema = avro.Type.forSchema(require('./schemas/SystemEvent.avsc'));

await producer.send({
  topic: 'V1_SYSTEM',
  messages: [{
    key: 'user-123',
    value: schema.toBuffer({
      id: crypto.randomUUID(),
      tenant_id: tenantId,
      aggregate_id: 'user-123',
      event_type: 'V1_SYSTEM_USER_LOGGED_IN',
      event_data: { user_id: 'user-123', ip: req.ip },
      timestamp: Date.now(),
      version: 1
    }),
    headers: {
      'tenant_id': tenantId,
      'version': '1'
    }
  }]
});
```

### Consuming Events

```javascript
const consumer = kafka.consumer({ groupId: 'my-service' });
await consumer.subscribe({ topic: 'V1_PAYMENTS' });

await consumer.run({
  eachMessage: async ({ topic, partition, message }) => {
    const event = schema.fromBuffer(message.value);
    console.log('Received:', event.event_type);
    
    // Обработка по tenant_id
    if (event.tenant_id === myTenantId) {
      await handleEvent(event);
    }
  }
});
```

---

## Testing

### Local Testing

```bash
# Запустить инфраструктуру
make tilt-up

# Дождаться готовности
make infra-wait

# Запустить тесты
cd packages/my-service
npm test
```

### Integration Tests for Infrastructure (запускаются в пайплайнах или локально руками)

```bash
make integration
```

---

## Common Patterns

### 1. Graceful Shutdown

```javascript
// Node.js
process.on('SIGTERM', async () => {
  console.log('SIGTERM received, shutting down gracefully...');
  
  // Остановить прием новых запросов
  server.close(async () => {
    // Закрыть соединения
    await producer.disconnect();
    await consumer.disconnect();
    await db.end();
    
    console.log('Shutdown complete');
    process.exit(0);
  });
  
  // Force shutdown после 30 секунд
  setTimeout(() => {
    console.error('Forced shutdown');
    process.exit(1);
  }, 30000);
});
```

### 2. Tenant Extraction Middleware

```javascript
// Express middleware
function extractTenant(req, res, next) {
  const tenantId = req.get('X-Tenant-Id');
  
  if (!tenantId || !/^\d+$/.test(tenantId)) {
    return res.status(400).json({ error: 'Invalid or missing X-Tenant-Id header' });
  }
  
  req.tenantId = tenantId;
  next();
}

app.use(extractTenant);
```

### 3. Tenant-scoped Database Queries

```javascript
class TenantRepository {
  constructor(db, tenantId) {
    this.db = db;
    this.tenantId = tenantId;
  }
  
  async findUser(userId) {
    const result = await this.db.query(
      'SELECT * FROM users WHERE tenant_id = $1 AND id = $2',
      [this.tenantId, userId]
    );
    return result.rows[0];
  }
}

// Usage
app.get('/users/:id', async (req, res) => {
  const repo = new TenantRepository(db, req.tenantId);
  const user = await repo.findUser(req.params.id);
  res.json(user);
});
```

---

## Troubleshooting

### Сервис не появляется в Tilt

1. Проверьте структуру:
```bash
ls packages/my-service/Dockerfile
ls packages/my-service/k8s/overlays/dev/kustomization.yaml
```

2. Проверьте логи Tilt:
```bash
# В Tilt UI (http://localhost:10350)
# Или в терминале где запущен make tilt-up
```

3. Проверьте namespace:
```bash
kubectl get pods -n dev-infra
```

### Pod не стартует

```bash
# Проверить статус
kubectl get pods -n dev-infra -l app=my-service

# Посмотреть логи
kubectl logs -n dev-infra -l app=my-service --tail=100

# Посмотреть события
kubectl describe pod -n dev-infra -l app=my-service
```

### Hot reload не работает

1. Проверьте `.tiltignore`:
```bash
cat packages/my-service/.tiltignore
```

2. Добавьте исключения для node_modules, vendor и т.д.

### Database connection failed

Проверьте что инфраструктура запущена:
```bash
kubectl get pods -n dev-infra | grep citus-coordinator
```

---

## Best Practices

### ✅ DO:

- Используйте structured logging (JSON)
- Добавляйте корреляционные ID в логи
- Всегда проверяйте `X-Tenant-Id` header
- Используйте prepared statements для SQL
- Добавляйте metrics endpoints (`/metrics`)
- Документируйте API (OpenAPI/Swagger)
- Пишите integration tests

### ❌ DON'T:

- Не храните состояние в памяти (stateless!)
- Не используйте floating point для денег (только integers в центах)
- Не логируйте sensitive данные (passwords, tokens, PII)
- Не делайте cross-tenant queries без явной проверки прав
- Не игнорируйте SIGTERM (graceful shutdown обязателен)
- Не используйте `SELECT *` в продакшене
- Не коммитьте secrets в Git

---

## Checklist перед деплоем в prod

- [ ] Dockerfile использует multi-stage build
- [ ] Non-root user в контейнере
- [ ] Health checks настроены
- [ ] Graceful shutdown реализован
- [ ] Resource limits установлены
- [ ] Логирование в JSON формате
- [ ] Tenant isolation протестирован
- [ ] Secrets через K8s Secrets (не в коде)
- [ ] Integration tests проходят
- [ ] README.md с описанием сервиса

---

## Дальнейшие шаги

- 📖 Прочитайте [Production Deployment Guide](./PRODUCTION_DEPLOYMENT.md)
- 🏗️ Изучите примеры в `packages/.template/`
- 🔍 Посмотрите существующие сервисы в `packages/`
- 💬 Вопросы? Спросите в #dev-infra канале

---

**Документ обновлен:** 2025-11-18
