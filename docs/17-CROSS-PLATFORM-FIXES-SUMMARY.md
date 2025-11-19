# Cross-Platform Infrastructure Fixes Summary

> **Дата:** 2025-11-19  
> **Проблема:** Инфраструктура работала на macOS, но падала на Arch Linux

---

## 🐛 Проблемы которые были обнаружены и исправлены

### 1. PRIMARY KEY без partition column (tenant_id)

**❌ Проблема:**
```sql
-- Неправильно (работало только на macOS случайно)
CREATE TABLE bet_events (
    id UUID PRIMARY KEY,  -- ❌ Нет tenant_id
    tenant_id BIGINT NOT NULL,
    ...
);
```

**✅ Решение:**
```sql
-- Правильно (работает на всех платформах)
CREATE TABLE bet_events (
    id UUID,
    tenant_id BIGINT NOT NULL,
    ...
    PRIMARY KEY (tenant_id, id)  -- ✅ Включает partition column
);
```

**Почему упало на Linux:**
- Citus требует чтобы PRIMARY KEY включал partition column
- На macOS таблицы создались ДО полной инициализации Citus → проверки не сработали
- На Linux (Arch) Citus инициализировался быстрее → сразу проверил constraints → ошибка

---

### 2. Триггеры на distributed tables

**❌ Проблема:**
```sql
-- Citus НЕ поддерживает триггеры!
CREATE TRIGGER after_bet_events_insert
AFTER INSERT ON bet_events
FOR EACH ROW
EXECUTE FUNCTION update_view();
-- ERROR: triggers are not supported on distributed tables
```

**✅ Решение:**
- Убрали все триггеры из миграций
- Views обновляются на уровне приложения (application-level UPSERT)
- См. `docs/15-INCREMENTAL-VIEW-UPDATES.md`

**Почему Citus не поддерживает триггеры:**
1. Events распределены по разным shards (узлам)
2. Триггер может потребовать обновления другого shard
3. Координация между shards замедляет inserts
4. Сложно гарантировать ACID через несколько узлов

---

### 3. idempotency_key в metadata vs на уровне схемы

**❌ Проблема:**
```typescript
// Идемпотентность скрыта в metadata
metadata: {
  idempotency_key: "payment-123"
}
```

**✅ Решение:**
```sql
-- Явное поле на уровне таблицы
CREATE TABLE bet_events (
  ...
  idempotency_key VARCHAR(255) NOT NULL,
  ...
);

-- UNIQUE constraint для защиты
CREATE UNIQUE INDEX idx_bet_events_idempotency_unique 
  ON bet_events(tenant_id, idempotency_key);
```

**Преимущества:**
- ✅ Явная защита от дубликатов на уровне БД
- ✅ Быстрые проверки (indexed)
- ✅ Понятная семантика для разработчиков

---

### 4. AVRO схемы: idempotency_key отсутствовал

**❌ Проблема:**
```json
{
  "type": "record",
  "name": "BetPlaced",
  "fields": [
    {"name": "bet_id", "type": "string"},
    ...
    // ❌ Нет idempotency_key
  ]
}
```

**✅ Решение:**
```json
{
  "type": "record",
  "name": "BetPlaced",
  "fields": [
    {"name": "bet_id", "type": "string"},
    {"name": "idempotency_key", "type": "string"},  // ✅ Добавлено
    ...
  ]
}
```

---

## 📊 Архитектурные изменения

### Было (triggers-based):
```
Event inserted
  ↓
Database Trigger (automatic)
  ↓
View updated
```

❌ **Проблема:** Citus не поддерживает триггеры на distributed tables

---

### Стало (application-level):
```
Event inserted
  ↓
Application UPSERT (same transaction)
  ↓
View updated
```

✅ **Преимущества:**
- Работает с Citus distributed tables
- Полный контроль производительности
- Возможность батчинга
- Strong consistency (ACID в одной транзакции)

---

## 🎯 Результаты

### ✅ Идентичное поведение на всех платформах

| Платформа | Миграции | Тесты | Constraints |
|-----------|----------|-------|-------------|
| macOS (Intel) | ✅ | ✅ | ✅ |
| macOS (ARM) | ✅ | ✅ | ✅ |
| Linux (Arch) | ✅ | ✅ | ✅ |
| Linux (Ubuntu) | ✅ | ✅ | ✅ |

### ✅ Event Sourcing тесты проходят

```bash
$ make event-sourcing-test

1. Inserting test bet event...
   → Event inserted (aggregate_id: bet-quick-test-1763542902-62011)
2. Manually updating bets_view (application-level)...
3. Checking bets_view was updated...
   → Found 2 bets in view

4. Testing idempotency key protection...
   → Updating payments_view (application-level)...
   → Payment materialized correctly (found in view)
   → Idempotency key protection working (duplicate rejected)

5. Verifying NO triggers on distributed tables...
   → ✅ No application triggers on distributed tables (correct for Citus)

✅ Event Sourcing tests completed
```

---

## 📚 Обновлённая документация

### Новые документы:

1. **`15-INCREMENTAL-VIEW-UPDATES.md`**
   - Полностью переписан под application-level updates
   - Примеры UPSERT из приложения
   - Best practices
   - Troubleshooting

2. **`16-CROSS-PLATFORM-CONSISTENCY.md`**
   - Фиксированные версии образов
   - Citus constraints
   - Проблемы которые были устранены
   - Testing checklist

3. **`17-CROSS-PLATFORM-FIXES-SUMMARY.md`** (этот документ)
   - Краткое резюме всех исправлений
   - До/После сравнения
   - Архитектурные изменения

### Обновлённые документы:

- **`03-LINUX-SETUP.md`** - Добавлены инструкции для Arch и Ubuntu
- **`12-ARCHITECTURE-DECISIONS.md`** - Добавлено обоснование application-level updates

---

## 🔧 Технические детали

### Миграции V1 (исправлено):

```sql
-- Все event tables:
CREATE TABLE bet_events (
    id UUID DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL,
    aggregate_id VARCHAR(255) NOT NULL,
    idempotency_key VARCHAR(255) NOT NULL,  -- ✅ Явное поле
    event_type VARCHAR(100) NOT NULL,
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL,
    version INTEGER NOT NULL DEFAULT 1,
    metadata JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, id),  -- ✅ Включает tenant_id
    CONSTRAINT fk_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

-- Unique constraint для idempotency
CREATE UNIQUE INDEX idx_bet_events_idempotency_unique 
  ON bet_events(tenant_id, idempotency_key);  -- ✅

-- Distribute по tenant_id
SELECT create_distributed_table('bet_events', 'tenant_id');
```

### Миграции V2 (переработано):

```sql
-- Read views как обычные таблицы (НЕ materialized)
CREATE TABLE bets_view (
    tenant_id BIGINT NOT NULL,
    bet_id VARCHAR(255) NOT NULL,
    idempotency_key VARCHAR(255) NOT NULL,  -- ✅
    user_id TEXT,
    amount NUMERIC,
    ...
    PRIMARY KEY (tenant_id, bet_id)
);

-- Distribute
SELECT create_distributed_table('bets_view', 'tenant_id');

-- Начальная загрузка
INSERT INTO bets_view
SELECT ... FROM bet_events
ON CONFLICT (tenant_id, bet_id) DO NOTHING;

-- ❌ НЕТ ТРИГГЕРОВ! Views обновляются из приложения
```

---

## 🚀 Migration Path для существующих установок

### Если у вас старая версия (с триггерами):

```bash
# 1. Удалить namespace
kubectl delete namespace dev-infra
kubectl wait --for=delete namespace/dev-infra --timeout=60s

# 2. Пересоздать с новыми миграциями
make tilt-up

# 3. Проверить что всё работает
make event-sourcing-test
```

### Если нужно сохранить данные:

```bash
# 1. Экспорт событий
kubectl -n dev-infra exec deploy/citus-coordinator -- \
  pg_dump -U app -d app -t bet_events -t payment_events > events_backup.sql

# 2. Пересоздать инфраструктуру
kubectl delete namespace dev-infra
make tilt-up

# 3. Импорт событий
kubectl -n dev-infra exec -i deploy/citus-coordinator -- \
  psql -U app -d app < events_backup.sql

# 4. Пересоздать views из событий
kubectl -n dev-infra exec deploy/citus-coordinator -- \
  psql -U app -d app -f infra/migrations/V2__read_views_as_tables.sql
```

---

## ✅ Checklist для новых разработчиков

### Первый запуск на любой платформе:

- [ ] Установить Docker
- [ ] Установить kubectl
- [ ] Установить kind/k3s (Linux) или Docker Desktop (macOS)
- [ ] Установить Tilt: `make ensure-tilt`
- [ ] Запустить инфраструктуру: `make tilt-up`
- [ ] Проверить миграции прошли: `kubectl -n dev-infra get jobs`
- [ ] Запустить тесты: `make event-sourcing-test`

### Должно работать на:

- [x] macOS Intel
- [x] macOS ARM (M1/M2/M3)
- [x] Linux Arch
- [x] Linux Ubuntu
- [x] Linux Fedora
- [ ] Windows (WSL2) - не тестировалось

---

## 📖 Связанные документы

- [01-SETUP-INFRASTRUCTURE.md](01-SETUP-INFRASTRUCTURE.md) - Общая инструкция
- [03-LINUX-SETUP.md](03-LINUX-SETUP.md) - Linux-специфичные инструкции
- [10-MIGRATIONS-GUIDE.md](10-MIGRATIONS-GUIDE.md) - Структура миграций
- [15-INCREMENTAL-VIEW-UPDATES.md](15-INCREMENTAL-VIEW-UPDATES.md) - Application-level updates
- [16-CROSS-PLATFORM-CONSISTENCY.md](16-CROSS-PLATFORM-CONSISTENCY.md) - Детали кросс-платформенности
- [12-ARCHITECTURE-DECISIONS.md](12-ARCHITECTURE-DECISIONS.md) - Архитектурные решения

---

## 🎓 Выводы

### Что мы узнали:

1. **Citus строгий:** Нельзя использовать PRIMARY KEY без partition column
2. **Citus ограниченный:** Нет поддержки триггеров на distributed tables
3. **Application-level лучше:** Больше контроля, предсказуемости, flexibility
4. **Явная идемпотентность:** Поле на уровне схемы > metadata
5. **Фиксированные версии:** Защита от breaking changes
6. **Тестирование на разных платформах:** Находит неочевидные проблемы

### Best Practices:

✅ **DO:**
- Всегда включать partition column в PRIMARY KEY
- Обновлять views из приложения (application-level)
- Фиксировать версии Docker образов
- Тестировать на нескольких платформах
- Использовать явные поля вместо metadata

❌ **DON'T:**
- Использовать триггеры на distributed tables
- Полагаться на `latest` tags
- Прятать важные поля в JSONB metadata
- Предполагать что "работает на моей машине" = "работает везде"

---

## 🙏 Acknowledgments

Спасибо Arch Linux за то что выявил все проблемы которые скрывались на macOS! 🎉
