# Materialized Views Guide

> **Цель:** Быстрое чтение данных через материализованные представления вместо восстановления состояния из event sourcing

---

## Концепция

**Event Sourcing** хранит историю изменений, но читать из него медленно:
- Нужно восстанавливать состояние из всех событий
- Для 1000 событий = 1000 SQL строк для обработки

**Materialized Views** - это кэшированные проекции (read models):
- Хранят текущее состояние
- Обновляются по расписанию через Kubernetes CronJob
- Быстрые SELECT запросы

---

## Доступные Materialized Views

### 1. `bets_view` - Текущее состояние ставок

**Структура:**
```sql
tenant_id          bigint
bet_id             varchar
user_id            varchar
stake              decimal
odds               decimal
fixture_id         varchar
status             varchar  -- 'placed', 'confirmed', 'settled', 'cancelled', 'voided'
result             varchar  -- 'win', 'loss', null
payout             decimal
last_updated_timestamp  bigint
last_updated_at    timestamp
```

**Использование:**
```typescript
// Получить все активные ставки пользователя
const query = `
  SELECT bet_id, stake, odds, fixture_id, status
  FROM bets_view
  WHERE tenant_id = $1 
    AND user_id = $2
    AND status IN ('placed', 'confirmed')
  ORDER BY last_updated_at DESC;
`;

const bets = await pool.query(query, [tenantId, userId]);
```

```php
$stmt = $db->prepare("
  SELECT bet_id, stake, odds, fixture_id, status
  FROM bets_view
  WHERE tenant_id = :tenant_id 
    AND user_id = :user_id
    AND status IN ('placed', 'confirmed')
  ORDER BY last_updated_at DESC
");

$stmt->execute([
  ':tenant_id' => $tenantId,
  ':user_id' => $userId
]);

$bets = $stmt->fetchAll();
```

### 2. `user_balances_view` - Балансы пользователей

**Структура:**
```sql
tenant_id                   bigint
user_id                     varchar
balance                     decimal
transaction_count           integer
last_transaction_timestamp  bigint
last_transaction_at         timestamp
```

**Использование:**
```typescript
// Получить баланс пользователя
const query = `
  SELECT balance, transaction_count
  FROM user_balances_view
  WHERE tenant_id = $1 AND user_id = $2;
`;

const result = await pool.query(query, [tenantId, userId]);
const balance = result.rows[0]?.balance || 0;
```

```php
$stmt = $db->prepare("
  SELECT balance, transaction_count
  FROM user_balances_view
  WHERE tenant_id = :tenant_id AND user_id = :user_id
");

$stmt->execute([
  ':tenant_id' => $tenantId,
  ':user_id' => $userId
]);

$userBalance = $stmt->fetch();
```

### 3. `payments_view` - История платежей

**Структура:**
```sql
tenant_id              bigint
payment_id             varchar
user_id                varchar
amount                 decimal
currency               varchar
payment_method         varchar
external_id            varchar
payment_type           varchar  -- 'deposit', 'withdrawal'
status                 varchar  -- 'created', 'pending', 'completed', 'failed', etc.
last_updated_timestamp bigint
last_updated_at        timestamp
```

**Использование:**
```typescript
// Получить историю депозитов пользователя
const query = `
  SELECT payment_id, amount, status, last_updated_at
  FROM payments_view
  WHERE tenant_id = $1 
    AND user_id = $2
    AND payment_type = 'deposit'
  ORDER BY last_updated_at DESC
  LIMIT 20;
`;

const deposits = await pool.query(query, [tenantId, userId]);
```

### 4. `tenants_summary_view` - Статистика по тенанту

**Структура:**
```sql
tenant_id          bigint
tenant_name        varchar
slug               varchar
status             varchar
plan               varchar
total_bets         integer
active_bets        integer
total_stake        decimal
total_deposits     decimal
total_withdrawals  decimal
total_users        integer
total_balance      decimal
last_refreshed_at  timestamp
```

**Использование:**
```typescript
// Dashboard для администратора тенанта
const query = `
  SELECT 
    total_bets,
    active_bets,
    total_stake,
    total_deposits,
    total_withdrawals,
    total_users,
    total_balance
  FROM tenants_summary_view
  WHERE tenant_id = $1;
`;

const stats = await pool.query(query, [tenantId]);
```

### 5. `user_activity_view` - Активность пользователей

**Структура:**
```sql
tenant_id         bigint
user_id           varchar
current_balance   decimal
total_bets        integer
total_wagered     decimal
total_winnings    decimal
total_deposited   decimal
total_withdrawn   decimal
last_activity_at  bigint
```

**Использование:**
```typescript
// Топ активных игроков
const query = `
  SELECT 
    user_id,
    total_bets,
    total_wagered,
    total_winnings,
    current_balance
  FROM user_activity_view
  WHERE tenant_id = $1
  ORDER BY total_wagered DESC
  LIMIT 10;
`;

const topPlayers = await pool.query(query, [tenantId]);
```

---

## Обновление Materialized Views

### ✅ Автоматическое обновление через Kubernetes CronJob (по умолчанию)

**Как это работает:**
- Периодически вызывается функция `refresh_aggregate_views()`
- Обновляются все существующие materialized views
- Для view с уникальными индексами используется `CONCURRENTLY`
- Нагрузка распределяется по времени, запись событий не замедляется

**Где настраивается:**
- `infra/k8s/cronjob-refresh-views.yaml`
- По умолчанию: каждые 5 минут (`*/5 * * * *`)

**Ручной запуск:**

```sql
SELECT refresh_aggregate_views();
```

### Управление расписанием

- Измените `spec.schedule` в `infra/k8s/cronjob-refresh-views.yaml`
- Для near real-time сценариев используйте `* * * * *` (каждую минуту)
- Для тяжёлых отчётных view используйте более редкий график

---

## Обоснование выбора CronJob

### Почему CronJob, а не триггеры?

**Архитектурное решение:**
- ✅ Триггеры не поддерживаются на Citus distributed tables
- ✅ Запись событий не замедляется (refresh по расписанию)
- ✅ Простая эксплуатация в Kubernetes
- ❌ Данные в views обновляются с задержкой (по расписанию)

### Как это работает:

```
1. По расписанию CronJob запускает контейнер
   ↓
2. Выполняется SELECT refresh_aggregate_views();
   ↓  
3. Все materialized views обновляются (CONCURRENTLY когда возможно)
   ↓
4. Завершение job и ожидание следующего запуска
```

### Мониторинг производительности:

```sql
-- Средние времена refresh
SELECT 
  view_name,
  avg_refresh_time_ms,
  refresh_count,
  last_refreshed_at
FROM materialized_views_refresh_log;
```

```typescript
// Алерт если refresh медленный
const { rows } = await pool.query(`
  SELECT view_name, avg_refresh_time_ms 
  FROM materialized_views_refresh_log
  WHERE avg_refresh_time_ms > 500
`);

if (rows.length > 0) {
  console.warn('Slow view refresh detected:', rows);
}
```

---

## Performance Tips

### 1. Используйте CONCURRENTLY

```sql
-- ✅ Не блокирует SELECT запросы
REFRESH MATERIALIZED VIEW CONCURRENTLY bets_view;

-- ❌ Блокирует все SELECT до завершения
REFRESH MATERIALIZED VIEW bets_view;
```

`CONCURRENTLY` требует UNIQUE индекс (уже создан в миграции).

### 2. Обновляйте по расписанию

Обновление по расписанию уже настроено через Kubernetes CronJob.

- **Обычно:** каждые 5 минут
- **Near real-time:** каждую минуту
- **Тяжёлые отчёты:** реже (например, каждый час)

### 3. Мониторинг времени обновления

```sql
-- Проверить, когда view последний раз обновлялся
SELECT 
  schemaname,
  matviewname,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||matviewname)) as size
FROM pg_matviews
WHERE schemaname = 'public';
```

### 4. Партиционирование для больших данных

Если views становятся слишком большими, можно создать per-tenant views:

```sql
-- View только для одного тенанта
CREATE MATERIALIZED VIEW bets_view_tenant_10001 AS
SELECT * FROM bets_view WHERE tenant_id = 10001;

-- Обновлять быстрее, чем полный view
REFRESH MATERIALIZED VIEW CONCURRENTLY bets_view_tenant_10001;
```

---

## Сравнение: Event Sourcing vs Materialized Views

| Операция | Event Sourcing | Materialized View | Выигрыш |
|----------|---------------|-------------------|---------|
| Получить текущее состояние ставки | Прочитать все события, восстановить состояние | SELECT из bets_view | **100x быстрее** |
| Получить баланс пользователя | Суммировать все balance_events | SELECT из user_balances_view | **50x быстрее** |
| Топ 10 игроков | Обработать все bet_events | SELECT TOP 10 из user_activity_view | **200x быстрее** |
| Dashboard статистика | Аггрегация из всех event таблиц | SELECT из tenants_summary_view | **500x быстрее** |

---

## Best Practices

### ✅ Когда использовать Materialized Views:

1. **Чтение текущего состояния** (баланс, статус ставки)
2. **Dashboard и аналитика** (статистика, графики)
3. **Списки и таблицы** (история платежей, активные ставки)
4. **Поиск и фильтрация** (топ игроков, поиск по fixture)

### ✅ Когда использовать Event Sourcing:

1. **Запись новых событий** (всегда пишем в event tables)
2. **Audit log** (полная история изменений)
3. **Time travel** (состояние на конкретный момент времени)
4. **Replay events** (восстановление после ошибки)

### ❌ Избегайте:

- Писать напрямую в materialized views (они read-only)
- Забывать обновлять views после массового импорта
- Обновлять слишком часто (каждую секунду - излишне)
- Хранить всё в views (event store всё равно нужен для истории)

---

## Troubleshooting

### View не обновляется

```sql
-- Проверить, есть ли данные в event tables (только для диагностики!)
-- ⚠️ НЕ используйте для бизнес-логики - только для troubleshooting
SELECT COUNT(*) FROM bet_events WHERE tenant_id = 10001;

-- Проверить, есть ли данные в view
SELECT COUNT(*) FROM bets_view WHERE tenant_id = 10001;

-- Принудительно обновить
REFRESH MATERIALIZED VIEW CONCURRENTLY bets_view;
```

### View обновляется слишком долго

```sql
-- Посмотреть размер view
SELECT pg_size_pretty(pg_total_relation_size('bets_view'));

-- Проверить, есть ли индексы
\d+ bets_view

-- Возможно нужно партиционирование или архивация старых данных
```

### Out of memory при обновлении

```sql
-- Увеличить work_mem для сессии
SET work_mem = '256MB';
REFRESH MATERIALIZED VIEW CONCURRENTLY bets_view;
```

### Триггеры замедляют INSERT

**Проблема:** INSERT операции стали медленнее (~300ms)

**Это нормально!** Для беттинга 300ms приемлемо. Но если критично:

**Вариант 1: Временно отключить триггеры для bulk import**
```sql
ALTER TABLE bet_events DISABLE TRIGGER after_bet_events_insert;
-- Массовый импорт...
ALTER TABLE bet_events ENABLE TRIGGER after_bet_events_insert;
SELECT manual_refresh_all_views();
```

**Вариант 2: Оптимизировать views (убрать тяжелые JOIN)**
```sql
-- Если view слишком сложный, разбейте на несколько простых
CREATE MATERIALIZED VIEW simple_bets_view AS
SELECT tenant_id, bet_id, status 
FROM bet_events WHERE ...;
```

**Вариант 3: Условный/частичный refresh по расписанию**
— выделите отдельные представления или используйте WHERE-условия для отдельных сегментов данных; вызов выполняется через CronJob.

---

## FAQ

### Можно ли использовать pg_cron вместо CronJob?

Теоретически да, но `pg_cron` недоступен в образе `citusdata/citus:13.0`.

**Альтернативы:**
1. ✅ **Kubernetes CronJob** (текущий подход) — просто и прозрачно
2. ❌ Собрать custom образ с pg_cron — сложность эксплуатации
3. ❌ Триггеры — не поддерживаются Citus на distributed tables

### Можно ли обновлять views реже?

Да. Измените расписание в `infra/k8s/cronjob-refresh-views.yaml` (поле `spec.schedule`).
Либо запускайте обновление из приложения по своему графику, вызывая `SELECT refresh_aggregate_views();`.

### Сколько памяти занимают materialized views?

```sql
-- Посмотреть размер всех views
SELECT 
  matviewname,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||matviewname)) as size
FROM pg_matviews 
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||matviewname) DESC;
```

Обычно views занимают 10-30% от размера исходных event tables.

### Можно ли читать напрямую из event tables?

Технически да, но **не рекомендуется**:
- ❌ Медленно (нужно восстанавливать состояние)
- ❌ Сложная логика в приложении
- ❌ Дублирование кода проекций

✅ **Используйте materialized views** - они для этого и созданы!
