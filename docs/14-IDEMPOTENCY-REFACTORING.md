# 🎯 Рефакторинг idempotency_key архитектуры

## ✅ Что изменилось:

### Было (через metadata JSONB):
```typescript
{
  tenant_id: 10001,
  aggregate_id: "payment-123",
  event_type: "V1_PAYMENTS_DEPOSIT_COMPLETED",
  metadata: {
    idempotency_key: "unique-key-123"  // ❌ Спрятано в JSONB
  }
}
```

**Проблемы:**
- Неявно - нужно знать где искать
- Сложная проверка через `metadata->>'idempotency_key'`
- Неочевидно для разработчиков
- Avro схемы не отражают idempotency_key явно

### Стало (прямое поле):
```typescript
{
  tenant_id: 10001,
  aggregate_id: "payment-123",
  idempotency_key: "unique-key-123",  // ✅ Явное обязательное поле!
  event_type: "V1_PAYMENTS_DEPOSIT_COMPLETED",
  metadata: {
    correlation_id: "trace-456",  // Только вспомогательные данные
    user_agent: "..."
  }
}
```

**Преимущества:**
- ✅ Явное обязательное поле на уровне схемы
- ✅ Простая проверка: `WHERE idempotency_key = $1`
- ✅ Видно в Avro схемах
- ✅ Невозможно забыть добавить

---

## 📋 Обновлённая архитектура:

### 1. Avro Schemas (все события TIER1)
```json
{
  "fields": [
    { "name": "id", "type": "string" },
    { "name": "tenant_id", "type": "long" },
    { "name": "aggregate_id", "type": "string" },
    { "name": "idempotency_key", "type": "string", "doc": "Обязательный!" },
    { "name": "event_type", "type": { "type": "enum", ... } },
    { "name": "event_data", ... },
    { "name": "metadata", "type": ["null", ...], "default": null }
  ]
}
```

### 2. Database Schema
```sql
CREATE TABLE payment_events (
    id UUID PRIMARY KEY,
    tenant_id BIGINT NOT NULL,
    aggregate_id VARCHAR(255) NOT NULL,
    idempotency_key VARCHAR(255) NOT NULL,  -- ✅ Обязательное поле!
    event_type VARCHAR(100) NOT NULL,
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB,  -- Только для correlation_id, user_agent, etc.
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Unique constraint на прямое поле (проще!)
CREATE UNIQUE INDEX idx_payment_events_idempotency_unique 
ON payment_events(tenant_id, idempotency_key);
```

### 3. Materialized Views
```sql
CREATE MATERIALIZED VIEW payments_view AS
SELECT 
  tenant_id,
  payment_id,
  idempotency_key,  -- ✅ Прямое поле из event table!
  (event_data->>'user_id') as user_id,
  (event_data->>'amount')::decimal as amount,
  ...
FROM latest_payment_events;

-- Unique index для быстрой проверки
CREATE UNIQUE INDEX idx_payments_view_idempotency 
ON payments_view(tenant_id, idempotency_key);
```

### 4. Проверка Idempotency (TypeScript)
```typescript
// ✅ Простая проверка из view
const existing = await pool.query(`
  SELECT payment_id FROM payments_view 
  WHERE tenant_id = $1 AND idempotency_key = $2
`, [tenantId, idempotencyKey]);

if (existing.rows.length > 0) {
  return { duplicate: true, payment_id: existing.rows[0].payment_id };
}

// ✅ Вставка события с прямым полем
await pool.query(`
  INSERT INTO payment_events (
    id, tenant_id, aggregate_id, idempotency_key, 
    event_type, event_data, timestamp, version
  ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
`, [
  randomUUID(),
  tenantId,
  paymentId,
  idempotencyKey,  // ✅ Прямой параметр!
  'V1_PAYMENTS_DEPOSIT_CREATED',
  JSON.stringify({ user_id, amount }),
  Date.now(),
  1
]);
```

---

## 🗂️ Изменённые файлы:

### Avro Schemas (все обновлены):
- ✅ `infra/schemas/PaymentEvent.avsc` - добавлено `idempotency_key`
- ✅ `infra/schemas/BetEvent.avsc` - добавлено `idempotency_key`
- ✅ `infra/schemas/BalanceEvent.avsc` - добавлено `idempotency_key`
- ✅ `infra/schemas/ComplianceEvent.avsc` - добавлено `idempotency_key`
- ✅ `infra/schemas/TenantEvent.avsc` - уже использует string event_type

### Миграции:
- ✅ `V1__initial_schema.sql` - добавлен столбец `idempotency_key` во все TIER1 tables
- ✅ `V3__update_views_with_idempotency.sql` - переделан для прямого поля

### Тесты:
- ✅ `infra/tests/test-event-sourcing.sh` - обновлён для прямого поля

---

## 🎯 Ключевые правила (финальная версия):

### Для TIER1 Events (bet, payment, balance, compliance):
1. **idempotency_key - ОБЯЗАТЕЛЬНОЕ поле**
   - Генерируется клиентом
   - Должно быть стабильным при retry
   - Формат: `{resource}-{tenant_id}-{user_id}-{timestamp}-{random}`

2. **metadata - ОПЦИОНАЛЬНОЕ поле**
   - Только для вспомогательных данных
   - correlation_id, user_agent, ip_address, etc.
   - НЕ для idempotency_key!

3. **Проверка дубликатов:**
   - Проверяем через materialized views (БЫСТРО!)
   - Защита на уровне БД через unique constraint
   - При дубликате возвращаем существующий результат

### Для System Events:
- idempotency_key опциональный (некритичные события)
- Используйте если нужно, иначе можно пропустить

---

## 🚀 Миграция существующих данных:

Если у вас уже есть данные с idempotency_key в metadata:

```sql
-- Миграция данных из metadata в прямое поле
UPDATE payment_events 
SET idempotency_key = metadata->>'idempotency_key'
WHERE metadata->>'idempotency_key' IS NOT NULL;

-- То же для остальных таблиц
UPDATE bet_events SET idempotency_key = metadata->>'idempotency_key'
WHERE metadata->>'idempotency_key' IS NOT NULL;
```

---

**Дата рефакторинга:** 2025-11-19  
**Версия:** 2.0  
**Статус:** ✅ Production-ready
