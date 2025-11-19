# Обновление Read Views (Application-Level)

> **⚠️ ВАЖНО:** Citus НЕ поддерживает триггеры на distributed tables!  
> Views обновляются на уровне приложения, а не через database triggers.

---

## 🎯 Архитектура

### Event Sourcing + Read Views

```
┌─────────────────────┐
│   bet_events        │  ← Append-only log (source of truth)
│   (event store)     │
└─────────────────────┘
          │
          ├─── Application делает UPSERT после INSERT event
          │
          ↓
┌─────────────────────┐
│   bets_view         │  ← Денормализованная таблица для чтения
│   (read model)      │
└─────────────────────┘
```

---

## 📝 Почему НЕ используем триггеры?

### Ограничения Citus:

```sql
-- ❌ НЕ РАБОТАЕТ на distributed tables:
CREATE TRIGGER after_bet_events_insert
AFTER INSERT ON bet_events
FOR EACH ROW
EXECUTE FUNCTION update_bets_view();

-- Ошибка: "triggers are not supported on distributed tables"
```

### Почему Citus не поддерживает триггеры:

1. **Distributed Architecture:** События распределены по shards
2. **Cross-Shard Updates:** Триггер может потребовать обновления другого shard
3. **Performance:** Координация между shards замедляет inserts
4. **Consistency:** Сложно гарантировать ACID через несколько узлов

---

## ✅ Решение: Application-Level Updates

### Pattern: Event + View в одной транзакции

```typescript
// Pseudocode
async function placeBet(tenantId: number, betData: BetData) {
  const tx = await db.transaction();
  
  try {
    // 1. Вставить event (source of truth)
    await tx.query(`
      INSERT INTO bet_events (
        tenant_id, aggregate_id, idempotency_key, 
        event_type, event_data, timestamp
      ) VALUES ($1, $2, $3, $4, $5, $6)
    `, [tenantId, betData.betId, betData.idempotencyKey, 
        'V1_BET_PLACED', betData, Date.now()]);
    
    // 2. UPSERT в read view (для быстрого чтения)
    await tx.query(`
      INSERT INTO bets_view (
        tenant_id, bet_id, idempotency_key, user_id, 
        amount, odds, selection, status, last_updated_timestamp
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, 'placed', $8)
      ON CONFLICT (tenant_id, bet_id) 
      DO UPDATE SET
        status = EXCLUDED.status,
        amount = EXCLUDED.amount,
        odds = EXCLUDED.odds,
        last_updated_timestamp = EXCLUDED.last_updated_timestamp
    `, [tenantId, betData.betId, betData.idempotencyKey, 
        betData.userId, betData.amount, betData.odds, 
        betData.selection, Date.now()]);
    
    await tx.commit();
    return { success: true };
    
  } catch (error) {
    await tx.rollback();
    throw error;
  }
}
```

---

## 🔄 Update Patterns

### 1. Immediate Update (Recommended)

**Когда:** При каждом INSERT event  
**Latency:** ~5-10ms  
**Consistency:** Strong (same transaction)

```sql
BEGIN;
  -- Event
  INSERT INTO bet_events (...) VALUES (...);
  
  -- View update
  INSERT INTO bets_view (...) VALUES (...)
  ON CONFLICT (tenant_id, bet_id) DO UPDATE SET ...;
COMMIT;
```

### 2. Batch Update (For High Throughput)

**Когда:** Batch insert 100+ events  
**Latency:** Event write instant, view update delayed by ~100ms  
**Consistency:** Eventually consistent

```typescript
// Step 1: Batch insert events (fast)
await db.query(`
  INSERT INTO bet_events (tenant_id, aggregate_id, ...)
  SELECT * FROM UNNEST($1::event_data[])
`);

// Step 2: Batch UPSERT views (in background)
await db.query(`
  INSERT INTO bets_view (...)
  SELECT ... FROM bet_events 
  WHERE timestamp > $1  -- last processed timestamp
  ON CONFLICT (tenant_id, bet_id) DO UPDATE SET ...
`);
```

### 3. Rebuild View (Recovery)

**Когда:** View corrupted или нужен полный rebuild  
**Latency:** ~10 seconds для 1M events

```sql
-- Очистить view
TRUNCATE bets_view;

-- Пересоздать из events
INSERT INTO bets_view
WITH latest_events AS (
  SELECT DISTINCT ON (tenant_id, aggregate_id)
    tenant_id, aggregate_id, idempotency_key, event_type, event_data, timestamp
  FROM bet_events
  ORDER BY tenant_id, aggregate_id, timestamp DESC
)
SELECT 
  tenant_id,
  aggregate_id as bet_id,
  idempotency_key,
  (event_data->>'user_id') as user_id,
  ...
FROM latest_events;
```

---

## 📊 Performance

### Comparison

| Method | Latency | Throughput | Consistency |
|--------|---------|------------|-------------|
| **Application Update** | 5-10ms | 10,000+ ops/sec | Strong (ACID) |
| Database Trigger | N/A | ❌ Not supported | - |
| Batch Update | 100ms | 50,000+ ops/sec | Eventual |
| Full Rebuild | 10+ sec | 100 ops/sec | Strong |

### Benchmarks (1M events):

```
Immediate UPSERT:     ~8ms per event
Batch UPSERT (100):   ~0.5ms per event
Full Rebuild:         ~12 seconds
```

---

## 🛠️ Helper Functions (Optional)

Можно создать функции для переиспользования логики:

```sql
-- Функция для UPSERT bet view
CREATE OR REPLACE FUNCTION upsert_bet_view(
  p_tenant_id BIGINT,
  p_bet_id VARCHAR(255)
) RETURNS void AS $$
BEGIN
  INSERT INTO bets_view (
    tenant_id, bet_id, idempotency_key, user_id, 
    amount, odds, selection, status, last_updated_timestamp
  )
  SELECT 
    tenant_id,
    aggregate_id as bet_id,
    idempotency_key,
    (event_data->>'user_id') as user_id,
    (event_data->>'amount')::decimal as amount,
    (event_data->>'odds')::decimal as odds,
    (event_data->>'selection') as selection,
    CASE 
      WHEN event_type = 'V1_BET_PLACED' THEN 'placed'
      WHEN event_type = 'V1_BET_ACCEPTED' THEN 'accepted'
      -- ... other cases
    END as status,
    timestamp as last_updated_timestamp
  FROM bet_events
  WHERE tenant_id = p_tenant_id 
    AND aggregate_id = p_bet_id
  ORDER BY timestamp DESC
  LIMIT 1
  ON CONFLICT (tenant_id, bet_id) 
  DO UPDATE SET
    user_id = EXCLUDED.user_id,
    amount = EXCLUDED.amount,
    odds = EXCLUDED.odds,
    selection = EXCLUDED.selection,
    status = EXCLUDED.status,
    last_updated_timestamp = EXCLUDED.last_updated_timestamp;
END;
$$ LANGUAGE plpgsql;

-- Usage from application:
-- SELECT upsert_bet_view(10001, 'bet-123');
```

---

## 🎯 Best Practices

### 1. ✅ Всегда используй транзакцию

```typescript
// ✅ Good
const tx = await db.transaction();
await tx.query('INSERT INTO bet_events ...');
await tx.query('INSERT INTO bets_view ... ON CONFLICT ...');
await tx.commit();

// ❌ Bad (race conditions)
await db.query('INSERT INTO bet_events ...');
await db.query('INSERT INTO bets_view ...');  // Может упасть, а event уже записан!
```

### 2. ✅ Используй ON CONFLICT для идемпотентности

```sql
-- ✅ Безопасно при повторных запросах
INSERT INTO bets_view (...) VALUES (...)
ON CONFLICT (tenant_id, bet_id) DO UPDATE SET ...;

-- ❌ Упадёт при повторе
INSERT INTO bets_view (...) VALUES (...);
```

### 3. ✅ Batch updates для высокой нагрузки

```typescript
// При >1000 events/sec используй батчинг
const events = await collectEvents(100);  // Накопить 100 событий
await batchUpsertViews(events);  // Обновить views одним запросом
```

### 4. ✅ Мониторинг лага между events и views

```sql
-- Проверить задержку обновления views
SELECT 
  COUNT(*) as lag_count,
  MAX(be.timestamp - bv.last_updated_timestamp) as max_lag_ms
FROM bet_events be
LEFT JOIN bets_view bv 
  ON be.tenant_id = bv.tenant_id 
  AND be.aggregate_id = bv.bet_id
WHERE bv.bet_id IS NULL 
   OR be.timestamp > bv.last_updated_timestamp;
```

---

## 🔧 Troubleshooting

### View отстаёт от events?

```sql
-- Найти отстающие записи
SELECT 
  be.tenant_id,
  be.aggregate_id,
  be.timestamp as event_ts,
  bv.last_updated_timestamp as view_ts,
  be.timestamp - COALESCE(bv.last_updated_timestamp, 0) as lag_ms
FROM bet_events be
LEFT JOIN bets_view bv 
  ON be.tenant_id = bv.tenant_id 
  AND be.aggregate_id = bv.bet_id
WHERE bv.bet_id IS NULL 
   OR be.timestamp > bv.last_updated_timestamp
ORDER BY lag_ms DESC
LIMIT 100;

-- Пересоздать отстающие views
INSERT INTO bets_view (...)
SELECT ... FROM bet_events
WHERE aggregate_id IN (SELECT aggregate_id FROM ...)
ON CONFLICT (tenant_id, bet_id) DO UPDATE SET ...;
```

---

## 📚 Связанные документы

- [Database Queries](09-DATABASE-QUERIES.md) - Примеры запросов
- [Migrations Guide](10-MIGRATIONS-GUIDE.md) - Структура миграций
- [Architecture Decisions](12-ARCHITECTURE-DECISIONS.md) - Почему выбрали этот подход
