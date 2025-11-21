# Cross-Platform Infrastructure Consistency

> **Цель:** Гарантировать идентичное поведение на macOS и Linux

---

## 🎯 Принцип: Infrastructure as Code

**Все различия устранены через:**
1. ✅ Фиксированные версии Docker образов
2. ✅ Citus constraints одинаковы везде
3. ✅ Kubernetes манифесты идентичны
4. ✅ Миграции проверены на обеих платформах

---

## 🐳 Docker Images - Зафиксированные версии

### Postgres/Citus

```yaml
# infra/k8s/citus-coordinator.yaml
image: citusdata/citus:13.0  # ✅ Точная версия

# ❌ Не используем:
# image: citusdata/citus:latest
# image: postgres:latest
```

**Почему важно:**
- Разные версии = разные constraints
- `latest` на macOS может быть старше чем на Linux
- Citus 12.x строже чем 11.x

### Другие сервисы

```yaml
# Redis
image: redis:8.2.2

# Redpanda (Kafka)
image: redpandadata/redpanda:v25.2.11

# Grafana
image: grafana/grafana:10.4.3

# Loki
image: grafana/loki:2.9.4
```

---

## 🗄️ Database Constraints

### PRIMARY KEY Requirements (Citus)

**Правило:** PRIMARY KEY ДОЛЖЕН включать partition column

```sql
-- ✅ Правильно (работает везде)
CREATE TABLE bet_events (
    id UUID DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL,
    ...
    PRIMARY KEY (tenant_id, id)  -- ✅ Включает tenant_id
);
SELECT create_distributed_table('bet_events', 'tenant_id');

-- ❌ Неправильно (может работать на старых версиях)
CREATE TABLE bet_events (
    id UUID PRIMARY KEY,  -- ❌ Нет tenant_id
    tenant_id BIGINT NOT NULL,
    ...
);
SELECT create_distributed_table('bet_events', 'tenant_id');
-- ERROR: PRIMARY KEY must include partition column
```

### Triggers NOT Supported (Citus)

**Правило:** Нельзя использовать триггеры на distributed tables

```sql
-- ❌ НЕ РАБОТАЕТ на Citus (обе платформы)
CREATE TRIGGER after_bet_insert
AFTER INSERT ON bet_events
FOR EACH ROW
EXECUTE FUNCTION update_view();
-- ERROR: triggers are not supported on distributed tables

-- ✅ Решение: application-level updates
-- См. docs/15-INCREMENTAL-VIEW-UPDATES.md
```

---

## 🔍 Проблемы которые были устранены

### 1. ❌ PRIMARY KEY без tenant_id

**Симптомы:**
- ✅ macOS: Работало (legacy state)
- ❌ Linux: Падало с ошибкой

**Причина:**
- На macOS таблицы создались до полной инициализации Citus
- На Linux Citus сразу проверял constraints

**Решение:**
```sql
-- Все event tables теперь:
PRIMARY KEY (tenant_id, id)  -- ✅
```

---

### 2. ❌ Триггеры на distributed tables

**Симптомы:**
- ❌ Обе платформы: "triggers are not supported"

**Причина:**
- Citus архитектура не поддерживает триггеры
- Events распределены по shards

**Решение:**
- Убрали все триггеры из миграций
- Views обновляются из приложения

---

### 3. ❌ .old файлы в миграциях

**Симптомы:**
- Bash скрипт пытался применить V2.sql.old

**Причина:**
- `V*.sql` включал `V2__*.sql.old`

**Решение:**
```bash
# infra/scripts/migrate.sh
files=("$INFRA_DIR"/migrations/V[0-9]*.sql)  # ✅ Только цифры

# Пропускаем .old
if [[ "$migration_name" == *.old ]]; then
  continue
fi
```

---

## ✅ Как гарантировать идентичность

### 1. Версии зафиксированы

```bash
# Проверить версии
kubectl -n dev-infra get pods -o yaml | grep "image:"

# Должно быть одинаково на macOS и Linux:
# citusdata/citus:13.0
# redis:8.2.2
# redpandadata/redpanda:v25.2.11
```

### 2. Миграции тестируются на обеих платформах

```bash
# На macOS
kubectl delete namespace dev-infra
make tilt-up
# Проверить что миграции прошли ✅

# На Linux
kubectl delete namespace dev-infra
make tilt-up
# Проверить что миграции прошли ✅
```

### 3. CI/CD проверяет на Linux

```yaml
# .github/workflows/test.yml (будущее)
jobs:
  test-migrations:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Setup k3s
        run: curl -sfL https://get.k3s.io | sh -
      - name: Run migrations
        run: make tilt-up
      - name: Verify
        run: kubectl -n dev-infra exec deploy/citus-coordinator -- psql -U app -d app -c '\dt'
```

---

## 🧪 Testing Checklist

### После изменений в infra/:

- [ ] Удалить namespace: `kubectl delete namespace dev-infra`
- [ ] Запустить на **macOS**: `make tilt-up`
- [ ] Проверить миграции прошли
- [ ] Запустить на **Linux** (Arch/Ubuntu): `make tilt-up`
- [ ] Проверить миграции прошли
- [ ] Сравнить структуру БД:

```bash
# macOS
kubectl -n dev-infra exec deploy/citus-coordinator -- \
  psql -U app -d app -c '\d bet_events'

# Linux
kubectl -n dev-infra exec deploy/citus-coordinator -- \
  psql -U app -d app -c '\d bet_events'

# Должно быть идентично!
```

---

## 🐛 Troubleshooting

### Разное поведение на macOS vs Linux?

1. **Проверить версии Docker images:**
```bash
kubectl -n dev-infra get pods -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n'
```

2. **Проверить PRIMARY KEY constraints:**
```sql
-- Должно включать tenant_id
\d bet_events
-- "bet_events_pkey" PRIMARY KEY, btree (tenant_id, id)  ✅
```

3. **Проверить нет триггеров:**
```sql
SELECT * FROM pg_trigger WHERE tgrelid = 'bet_events'::regclass;
-- Должно быть пусто или только system triggers
```

4. **Пересоздать с нуля:**
```bash
# Полная очистка
kubectl delete namespace dev-infra
kubectl wait --for=delete namespace/dev-infra --timeout=60s

# Чистый старт
make tilt-up
```

---

## 📊 Версии компонентов

| Компонент | Версия | Фиксирована |
|-----------|--------|-------------|
| Citus | 13.0 | ✅ Yes |
| PostgreSQL | 18 (в составе Citus) | ✅ Yes |
| Redis | 8.2.2 | ✅ Yes |
| Redpanda | v25.2.11 | ✅ Yes |
| Grafana | 10.4.3 | ✅ Yes |
| Loki | 2.9.4 | ✅ Yes |
| Kubernetes | kind 1.29+ / k3s 1.28+ | ⚠️ Зависит от установки |

---

## 🎯 Результат

✅ **Одинаковое поведение на всех платформах:**
- macOS (Intel/ARM)
- Linux (Arch, Ubuntu, Fedora, etc.)
- CI/CD (GitHub Actions, GitLab CI)

✅ **Предсказуемые миграции:**
- Одинаковые constraints
- Одинаковые ошибки (если есть)
- Одинаковая производительность

✅ **Легкий onboarding:**
- Новый разработчик на любой платформе
- `make tilt-up` → всё работает
- Нет сюрпризов
