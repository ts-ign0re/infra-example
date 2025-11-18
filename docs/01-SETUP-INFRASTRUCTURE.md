# Разработка микросервисов

## ⚠️ Важно: Только разработка в кластере!

**Легаси не поддерживается. Всё только в Kubernetes с HMR.**

- Разработка **ТОЛЬКО** внутри кластера
- HMR для фронтенда (если поддерживается)
- Автоматический доступ ко всей инфраструктуре
- Изолированное окружение

## Quick Start

```bash
# Поднять кластер с инфраструктурой
make tilt-up

# С HMR (для фронтенда)
DEV_MODE=true make tilt-up

# Открыть Tilt UI
open http://localhost:10350
```

## Как это работает

1. **Tilt запускает кластер** с инфраструктурой (Postgres, Redis, Kafka, Loki)
2. **Каждый сервис получает env vars** автоматически через ConfigMap
3. **Live reload** работает из коробки (Tilt синхронизирует код)
4. **HMR** для фронтенда (если `DEV_MODE=true` и есть `Dockerfile.dev`)

## Environment Variables

### Автоматически доступны во всех сервисах:

```bash
DATABASE_URL=postgresql://app:app@citus-coordinator.dev-infra.svc.cluster.local:5432/app
REDIS_URL=redis://redis.dev-infra.svc.cluster.local:6379
KAFKA_BROKERS=redpanda.dev-infra.svc.cluster.local:9092
SCHEMA_REGISTRY_URL=http://schema-registry.dev-infra.svc.cluster.local:8081
LOKI_URL=http://loki.dev-infra.svc.cluster.local:3100
```

### Использование в коде:

```javascript
// Node.js
const db = connect(process.env.DATABASE_URL);
const redis = new Redis(process.env.REDIS_URL);

// Go
databaseURL := os.Getenv("DATABASE_URL")

// Python
database_url = os.environ['DATABASE_URL']

// PHP
$databaseUrl = getenv('DATABASE_URL');
```

## Два режима

### Production Build (default)

```bash
make tilt-up
```

- Использует `Dockerfile`
- Оптимизированный production build
- Basic live reload (sync файлов)
- Для бэкенда

### Dev Build с HMR

```bash
DEV_MODE=true make tilt-up
```

- Использует `Dockerfile.dev`
- Dev dependencies
- Hot Module Replacement
- Для фронтенда (React, Vue, etc.)

## Workflow

### 1. Поднять кластер

```bash
# Первый раз или после перезагрузки
make tilt-up

# Дождаться готовности
make infra-test
```

### 2. Открыть Tilt UI

```bash
open http://localhost:10350
```

### 3. Разработка

```bash
# Просто редактируй файлы в packages/your-service/
# Tilt автоматически синхронизирует изменения
# HMR обновит браузер (если включен)
```

### 4. Логи и отладка

```bash
# В Tilt UI
- Кликни на сервис
- Смотри логи в реальном времени
- Ошибки видны сразу

# Или через kubectl
kubectl logs -f -n dev-infra deployment/my-service
```

### 5. Port-forwards

```bash
# Автоматически в Tilt UI
# Или вручную
kubectl port-forward -n dev-infra svc/tenants-dashboard 3000:3000
```

### 6. Готово!

```bash
# Остановить когда закончил
make tilt-down
```

## Добавление нового сервиса

### 1. Добавить как submodule

```bash
git submodule add git@github.com:org/my-service.git packages/my-service
```

### 2. Добавить инфраструктуру

```bash
make add-infra PATH=packages/my-service
```

Скрипт спросит:
- Язык (определяется автоматически)
- Порт (default 3000)
- Какие файлы создать

Создаст:
- `Dockerfile` - production
- `Dockerfile.dev` - dev с HMR (опционально)
- `k8s/` - манифесты
- `Tiltfile` - настройки для Tilt

### 3. Перезапустить Tilt

```bash
# Tilt автоматически обнаружит новый сервис
# Просто сохрани изменения в Tiltfile
```

## HMR для фронтенда

### Создание Dockerfile.dev

Скрипт `make add-infra` автоматически создаст `Dockerfile.dev` для Node.js проектов.

Или вручную:
```dockerfile
FROM node:20-alpine
RUN corepack enable && corepack prepare pnpm@9.0.0 --activate
WORKDIR /app
COPY package*.json pnpm-lock.yaml ./
RUN pnpm install
COPY . .
EXPOSE 3000 24678
CMD ["pnpm", "run", "dev"]
```

### Создание k8s/overlays/dev-hmr/

```bash
cd packages/my-service
cp -r k8s/overlays/dev k8s/overlays/dev-hmr

# Отредактируй deployment.yaml
vim k8s/overlays/dev-hmr/deployment.yaml
```

Добавь HMR порт:
```yaml
ports:
- containerPort: 3000
  name: http
- containerPort: 24678  # HMR WebSocket
  name: hmr
```

### Настройка Tiltfile

```python
# packages/my-service/Tiltfile
dev_mode = os.getenv('DEV_MODE', 'false') == 'true'

if dev_mode:
    docker_build('my-service-dev', '.', dockerfile='Dockerfile.dev', ...)
    k8s_yaml(kustomize('k8s/overlays/dev-hmr'))
    k8s_resource('my-service-dev', 
        port_forwards=[
            port_forward(3000, 3000),
            port_forward(24678, 24678)
        ])
```

## Отладка

### Логи сервиса

```bash
# В Tilt UI - кликни на сервис

# Или
kubectl logs -f -n dev-infra deployment/my-service
```

### Exec в контейнер

```bash
kubectl exec -it -n dev-infra deployment/my-service -- sh

# Проверить env vars
env | grep DATABASE_URL

# Проверить подключения
curl http://redis:6379
psql $DATABASE_URL -c "SELECT 1"
```

### Restart сервиса

```bash
# В Tilt UI - нажми кнопку Restart

# Или
kubectl rollout restart deployment/my-service -n dev-infra
```

### Rebuild образа

```bash
# В Tilt UI - нажми кнопку Rebuild

# Или force rebuild
tilt trigger my-service
```

## Troubleshooting

### Сервис не запускается

1. Проверь логи в Tilt UI
2. Проверь что инфраструктура готова: `make infra-test`
3. Проверь Dockerfile синтаксис
4. Проверь k8s манифесты: `kubectl get pods -n dev-infra`

### HMR не работает

1. Проверь что `DEV_MODE=true`
2. Проверь что `Dockerfile.dev` существует
3. Проверь что порт 24678 открыт в deployment
4. Проверь логи dev server в Tilt UI

### Изменения не применяются

1. Проверь что файл не в `.dockerignore`
2. Проверь live_update в Tiltfile
3. Force rebuild в Tilt UI
4. Restart Tilt: `make tilt-down && make tilt-up`

### Нет доступа к БД/Redis/Kafka

1. Проверь что инфраструктура запущена: `kubectl get pods -n dev-infra`
2. Проверь ConfigMap: `kubectl get configmap common-env -n dev-infra -o yaml`
3. Проверь env vars в поде: `kubectl exec deployment/my-service -- env`
4. Проверь что в deployment есть `envFrom`

## Best Practices

### ✅ DO

- Разрабатывай в кластере с Tilt
- Используй HMR для фронтенда
- Смотри логи в Tilt UI
- Коммить `Dockerfile`, `Dockerfile.dev`, `k8s/`, `Tiltfile`
- Используй `common-env` ConfigMap для URLs

### ❌ DON'T

- ❌ **НЕ разрабатывай на хосте вне кластера**
- ❌ Не хардкодь URLs в коде
- ❌ Не коммить `.env` файлы
- ❌ Не дублируй env vars в каждом deployment
- ❌ Не забывай останавливать Tilt

## Команды

```bash
# Основные
make tilt-up              # Запустить кластер
make tilt-down            # Остановить
make infra-test          # Проверить инфраструктуру

# HMR режим
DEV_MODE=true make tilt-up

# Добавить инфру в сервис
make add-infra PATH=packages/my-service

# Логи
kubectl logs -f -n dev-infra deployment/my-service

# Exec
kubectl exec -it -n dev-infra deployment/my-service -- sh

# Restart
kubectl rollout restart deployment/my-service -n dev-infra
```

## См. также

- **Следующий шаг:** [02. Быстрый старт](02-QUICKSTART.md) - Как подключиться к сервисам
- [03. Переменные окружения](03-ENVIRONMENT-VARS.md) - Environment variables
- [04. Руководство по Tiltfile](04-TILTFILE-GUIDE.md) - Настройка Tilt
- [05. Руководство по сервисам](05-SERVICES-GUIDE.md) - Гайд по сервисам
- [README.md](../README.md) - Главная документация
