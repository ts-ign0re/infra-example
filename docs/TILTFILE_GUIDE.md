# Руководство по Tiltfile для микросервисов

## Архитектура

### Главный Tiltfile (`infra/Tiltfile`)

Универсальный оркестратор:
- ✅ Загружает базовую инфраструктуру (Postgres, Redis, Kafka, Loki, Grafana)
- ✅ Автоматически обнаруживает сервисы в `packages/`
- ✅ Загружает `Tiltfile` из каждого сервиса (если есть)
- ✅ Fallback на generic конфигурацию (если Tiltfile отсутствует)

### Сервисный Tiltfile (`packages/service-name/Tiltfile`)

Специфичная конфигурация для каждого сервиса:
- ✅ Язык-специфичные настройки (pnpm, go mod, pip, composer)
- ✅ Кастомные порты и port-forwards
- ✅ HMR конфигурация (для фронтенда)
- ✅ Dependency ресурсов (какие сервисы нужны)

## Структура

```
ideas/
├── infra/
│   └── Tiltfile                    # 🔧 Главный оркестратор
├── packages/
│   ├── .template/
│   │   └── Tiltfile.example        # 📋 Шаблоны для всех языков
│   ├── tenants-dashboard/
│   │   └── Tiltfile                # 🎨 Node.js/pnpm специфика
│   ├── payment-api/
│   │   └── Tiltfile                # 🐹 Go специфика
│   ├── fraud-detector/
│   │   └── Tiltfile                # 🐍 Python специфика
│   └── legacy-backend/
│       └── Tiltfile                # 🐘 PHP специфика
```

## Примеры для разных языков

### Node.js (pnpm + Turborepo)

```python
# packages/tenants-dashboard/Tiltfile
service_name = 'tenants-dashboard'
dev_mode = os.getenv('DEV_MODE', 'false') == 'true'

if dev_mode:
    # Dev mode с HMR
    docker_build(
        service_name + '-dev',
        '.',
        dockerfile='Dockerfile.dev',
        live_update=[
            sync('apps', '/app/apps'),
            sync('packages', '/app/packages'),
            run('pnpm install', trigger=['**/package.json', 'pnpm-lock.yaml']),
        ],
        ignore=['node_modules', '.git', 'dist', 'build', '.turbo']
    )
    k8s_yaml(kustomize('k8s/overlays/dev-hmr'))
    k8s_resource(
        service_name + '-dev',
        port_forwards=[port_forward(3000, 3000), port_forward(24678, 24678)],
        resource_deps=['redis', 'citus-coordinator'],
        labels=[service_name]
    )
else:
    # Production mode
    docker_build(
        service_name,
        '.',
        dockerfile='Dockerfile',
        live_update=[
            sync('.', '/app'),
            run('pnpm install', trigger=['package.json']),
        ],
        ignore=['node_modules', '.git']
    )
    k8s_yaml(kustomize('k8s/overlays/dev'))
    k8s_resource(
        service_name,
        port_forwards=[port_forward(3000, 3000)],
        resource_deps=['redis', 'citus-coordinator'],
        labels=[service_name]
    )
```

### Go

```python
# packages/payment-api/Tiltfile
service_name = 'payment-api'

docker_build(
    service_name,
    '.',
    dockerfile='Dockerfile',
    live_update=[
        sync('.', '/app'),
        run('go mod download', trigger=['go.mod', 'go.sum']),
        run('go build -o /app/server ./cmd/server', trigger=['**/*.go']),
    ],
    ignore=['.git', 'vendor', 'bin']
)

k8s_yaml(kustomize('k8s/overlays/dev'))

k8s_resource(
    service_name,
    port_forwards=[port_forward(8080, 8080)],
    resource_deps=['citus-coordinator', 'redis', 'redpanda'],
    labels=[service_name]
)
```

### Python (FastAPI)

```python
# packages/fraud-detector/Tiltfile
service_name = 'fraud-detector'

docker_build(
    service_name,
    '.',
    dockerfile='Dockerfile',
    live_update=[
        sync('.', '/app'),
        run('pip install -r requirements.txt', trigger=['requirements.txt']),
    ],
    ignore=['.git', '__pycache__', '.venv', '.pytest_cache']
)

k8s_yaml(kustomize('k8s/overlays/dev'))

k8s_resource(
    service_name,
    port_forwards=[port_forward(8000, 8000)],
    resource_deps=['redis', 'redpanda'],
    labels=[service_name]
)
```

### PHP

```python
# packages/legacy-backend/Tiltfile
service_name = 'legacy-backend'

docker_build(
    service_name,
    '.',
    dockerfile='Dockerfile',
    live_update=[
        sync('.', '/var/www/html'),
        run('composer install', trigger=['composer.json', 'composer.lock']),
    ],
    ignore=['.git', 'vendor']
)

k8s_yaml(kustomize('k8s/overlays/dev'))

k8s_resource(
    service_name,
    port_forwards=[port_forward(80, 80)],
    resource_deps=['citus-coordinator', 'redis'],
    labels=[service_name]
)
```

### C++

```python
# packages/high-perf-service/Tiltfile
service_name = 'high-perf-service'

docker_build(
    service_name,
    '.',
    dockerfile='Dockerfile',
    live_update=[
        sync('.', '/app'),
        run('cmake --build build --target all', trigger=['CMakeLists.txt', '**/*.cpp', '**/*.h']),
    ],
    ignore=['.git', 'build', '.cache']
)

k8s_yaml(kustomize('k8s/overlays/dev'))

k8s_resource(
    service_name,
    port_forwards=[port_forward(9090, 9090)],
    resource_deps=['redis'],
    labels=[service_name]
)
```

## Best Practices

### 1. Имя сервиса

```python
# ✅ Хорошо
service_name = 'payment-api'

# ❌ Плохо - хардкод
docker_build('payment-api', ...)
```

### 2. Игнорирование файлов

```python
# Специфично для каждого языка
ignore=['node_modules', '.git', 'dist']        # Node.js
ignore=['.git', 'vendor', 'bin']               # Go
ignore=['.git', '__pycache__', '.venv']       # Python
ignore=['.git', 'vendor']                      # PHP
ignore=['.git', 'build', '.cache']            # C++
```

### 3. Live Update триггеры

```python
# Перезапуск только при изменении зависимостей
trigger=['package.json']           # Node.js
trigger=['go.mod', 'go.sum']       # Go
trigger=['requirements.txt']       # Python
trigger=['composer.json']          # PHP
trigger=['CMakeLists.txt']         # C++
```

### 4. Resource Dependencies

```python
# Указывайте ТОЛЬКО те сервисы, которые РЕАЛЬНО нужны
resource_deps=['redis']                          # Только Redis
resource_deps=['citus-coordinator', 'redis']     # DB + Cache
resource_deps=['redis', 'redpanda', 'loki']     # Cache + Kafka + Logs
```

### 5. Port Forwards

```python
# Один порт
port_forwards=[port_forward(8080, 8080)]

# Несколько портов
port_forwards=[
    port_forward(3000, 3000),    # HTTP
    port_forward(24678, 24678)   # HMR
]
```

## DEV_MODE (опционально)

Для сервисов с HMR (фронтенд):

```python
dev_mode = os.getenv('DEV_MODE', 'false') == 'true'

if dev_mode:
    # Dev конфигурация с HMR
    dockerfile = 'Dockerfile.dev'
    overlay = 'k8s/overlays/dev-hmr'
else:
    # Production конфигурация
    dockerfile = 'Dockerfile'
    overlay = 'k8s/overlays/dev'
```

Запуск:
```bash
# Dev mode
DEV_MODE=true make tilt-up

# Production mode
make tilt-up
```

## Fallback (без Tiltfile)

Если сервис не имеет `Tiltfile`, главный оркестратор использует generic конфигурацию:

```python
# infra/Tiltfile
docker_build(
    service_name,
    service_path,
    dockerfile=service_path + '/Dockerfile',
    live_update=[sync(service_path, '/app')],
    ignore=['node_modules', '.git', 'vendor', '__pycache__']
)
k8s_yaml(kustomize(service_path + '/k8s/overlays/dev'))
k8s_resource(service_name, resource_deps=['citus-coordinator', 'redis', 'redpanda', 'loki'])
```

**⚠️ Рекомендуется:** Всегда создавать свой `Tiltfile` для оптимальной конфигурации.

## Добавление нового сервиса

### 1. Скопируйте шаблон

```bash
cp packages/.template/Tiltfile.example packages/my-service/Tiltfile
```

### 2. Настройте под свой язык

```python
service_name = 'my-service'  # Измените имя

# Раскомментируйте нужную секцию:
# - OPTION 1: Node.js
# - OPTION 2: Go
# - OPTION 3: Python
# - OPTION 4: PHP
# - OPTION 5: C++
```

### 3. Перезапустите Tilt

```bash
# Tilt автоматически перезагрузит конфигурацию
```

## Troubleshooting

### Tiltfile не загружается

```bash
# Проверьте синтаксис
cd packages/my-service
tilt validate Tiltfile

# Проверьте что файл есть
ls -la Tiltfile
```

### Live update не работает

1. Проверьте `ignore` список
2. Проверьте `trigger` файлы
3. Посмотрите логи в Tilt UI

### Порты конфликтуют

Используйте разные порты для каждого сервиса:

```python
port_forwards=[port_forward(3001, 3000)]  # Локальный 3001 → контейнер 3000
```

## См. также

- [Tilt Documentation](https://docs.tilt.dev/)
- [SERVICES_GUIDE.md](SERVICES_GUIDE.md) - Полное руководство по сервисам
- [packages/.template/Tiltfile.example](../packages/.template/Tiltfile.example) - Шаблоны
