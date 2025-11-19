# Database Query Examples with Multi-Tenancy

> **Цель:** Примеры работы с PostgreSQL/Citus для event-sourcing с учетом multi-tenancy через HTTP заголовки

---

## 🚀 TL;DR - Что нужно знать

### Для записи (Write):
```typescript
// 1. Пишем событие в event table
INSERT INTO bet_events (...) VALUES (...);

// 2. Триггер автоматически обновляет materialized view (~150ms)

// 3. Profit! 🎉
```

### Для чтения (Read):
```typescript
// ✅ ВСЕГДА читаем из materialized views
SELECT * FROM bets_view WHERE tenant_id = $1 AND bet_id = $2;

// ❌ НИКОГДА не восстанавливаем из событий вручную
// (это медленно и уже сделано за вас!)
```

### Ключевые правила:
1. 📝 **Пишем** → Event tables (bet_events, payment_events, etc.)
2. 🔄 **Триггеры** → Автоматически обновляют views
3. 📖 **Читаем** → ТОЛЬКО из Materialized Views (bets_view, payments_view, etc.)
4. 🔐 **Idempotency** → Проверяем в views, НЕ в event tables

> ⚠️ **ВАЖНО:** Event tables (`*_events`) - только для INSERT! Для чтения (включая проверку idempotency) используйте materialized views.
3. 📖 **Читаем** → Materialized views (bets_view, user_balances_view, etc.)
4. 🔒 **Всегда** → Фильтруем по `tenant_id` 
5. 🛡️ **Критические операции** → Используем `idempotency_key`

---

## 🎯 Быстрый старт

### Как это работает:

1. **Пишем события** → Event tables (bet_events, payment_events, etc.)
2. **Триггеры автоматически обновляют** → Materialized Views (~100-300ms)
3. **Читаем из views** → Быстро (без восстановления из событий)

```
┌─────────────┐     INSERT      ┌──────────────┐
│   Client    │────────────────>│ bet_events   │
└─────────────┘                 └──────────────┘
                                       │
                                       │ Trigger (~150ms)
                                       ↓
                                ┌──────────────┐
                                │  bets_view   │<─── SELECT (fast!)
                                └──────────────┘
```

---

## 📖 Чтение данных (SELECT)

### ✅ Всегда читайте из Materialized Views

**Правильно:**
```typescript
// Получить текущее состояние ставки
const { rows } = await pool.query(`
  SELECT bet_id, user_id, stake, odds, status, result, payout
  FROM bets_view
  WHERE tenant_id = $1 AND bet_id = $2
`, [tenantId, betId]);
```

**Неправильно:**
```typescript
// ❌ НЕ ДЕЛАЙТЕ ТАК - медленно!
const events = await pool.query(`
  SELECT * FROM bet_events WHERE tenant_id = $1 AND aggregate_id = $2
`, [tenantId, betId]);
// Потом восстанавливать состояние из событий...
```

### Доступные Materialized Views:

| View | Что содержит | Когда использовать |
|------|--------------|-------------------|
| `bets_view` | Текущее состояние ставок | Получить статус ставки, список ставок пользователя |
| `user_balances_view` | Балансы пользователей | Показать баланс, проверить достаточность средств |
| `payments_view` | История платежей | История депозитов/выводов |
| `tenants_summary_view` | Статистика по тенанту | Dashboard, отчёты |
| `user_activity_view` | Активность пользователей | Топ игроков, аналитика |

---

## ✍️ Запись данных (INSERT)

### ✅ Всегда пишите в Event Tables

**ВАЖНО:** Никогда не пишите напрямую в materialized views - они обновляются автоматически!

### Правила записи:

1. **Всегда INSERT**, никогда UPDATE/DELETE (immutability)
2. **Обязательно указывайте `tenant_id`** (multi-tenancy)
3. **Используйте `idempotency_key` в metadata** (для критических операций)
4. **UUID для `id`**, timestamp в миллисекундах для `timestamp`

---

## 💡 Полный пример: Создание ставки

### TypeScript/Node.js

```typescript
import { Pool } from 'pg';
import { randomUUID } from 'crypto';

const pool = new Pool({
  host: 'citus-coordinator.dev-infra.svc.cluster.local',
  port: 5432,
  database: 'app',
  user: 'app',
  password: 'app'
});

// Middleware для извлечения tenant_id
export function extractTenantId(req: Request, res: Response, next: NextFunction) {
  const tenantId = parseInt(req.headers['x-tenant-id'] as string, 10);
  if (!tenantId) {
    return res.status(400).json({ error: 'Missing X-Tenant-Id header' });
  }
  (req as any).tenantId = tenantId;
  next();
}

// API endpoint для создания ставки
app.post('/bets', extractTenantId, async (req: any, res) => {
  const { user_id, stake, odds, fixture_id } = req.body;
  const tenantId = req.tenantId;
  const idempotencyKey = req.headers['idempotency-key'] as string;
  
  if (!idempotencyKey) {
    return res.status(400).json({ error: 'Missing Idempotency-Key header' });
  }
  
  const client = await pool.connect();
  
  try {
    await client.query('BEGIN');
    
    // 1. Проверить idempotency key в materialized view
    // Views автоматически содержат idempotency_key из метаданных
    const existing = await client.query(`
      SELECT bet_id, idempotency_key FROM bets_view 
      WHERE tenant_id = $1 
        AND idempotency_key = $2
      LIMIT 1
    `, [tenantId, idempotencyKey]);
    
    if (existing.rows.length > 0) {
      // Запрос уже обработан - вернуть из view
      const bet = await client.query(`
        SELECT * FROM bets_view 
        WHERE tenant_id = $1 AND bet_id = $2
      `, [tenantId, existing.rows[0].bet_id]);
      
      await client.query('COMMIT');
      return res.status(200).json({ 
        ...bet.rows[0], 
        duplicate: true 
      });
    }
    
    const betId = `bet-${randomUUID()}`;
    
    // 2. Вставить событие
    await client.query(`
      INSERT INTO bet_events (
        id, tenant_id, aggregate_id, event_type, event_data, timestamp, version, metadata
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    `, [
      randomUUID(),
      tenantId,
      betId,
      'V1_BETS_BET_PLACED',
      JSON.stringify({ user_id, stake, odds, fixture_id }),
      Date.now(),
      1,
      JSON.stringify({ idempotency_key: idempotencyKey })
    ]);
    
    await client.query('COMMIT');
    
    // 3. Подождать 200ms пока триггер обновит view
    await new Promise(resolve => setTimeout(resolve, 200));
    
    // 4. Прочитать из materialized view
    const result = await pool.query(`
      SELECT * FROM bets_view 
      WHERE tenant_id = $1 AND bet_id = $2
    `, [tenantId, betId]);
    
    res.status(201).json(result.rows[0]);
    
  } catch (error) {
    await client.query('ROLLBACK');
    console.error('Failed to create bet:', error);
    res.status(500).json({ error: 'Failed to create bet' });
  } finally {
    client.release();
  }
});

// API endpoint для получения ставки
app.get('/bets/:betId', extractTenantId, async (req: any, res) => {
  const { betId } = req.params;
  const tenantId = req.tenantId;
  
  try {
    // Читаем из materialized view - БЫСТРО!
    const result = await pool.query(`
      SELECT 
        bet_id,
        user_id,
        stake,
        odds,
        fixture_id,
        status,
        result,
        payout,
        last_updated_at
      FROM bets_view
      WHERE tenant_id = $1 AND bet_id = $2
    `, [tenantId, betId]);
    
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Bet not found' });
    }
    
    res.json(result.rows[0]);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch bet' });
  }
});

// API endpoint для получения списка ставок пользователя
app.get('/users/:userId/bets', extractTenantId, async (req: any, res) => {
  const { userId } = req.params;
  const tenantId = req.tenantId;
  const status = req.query.status; // 'placed', 'confirmed', 'settled'
  
  try {
    let query = `
      SELECT 
        bet_id,
        stake,
        odds,
        fixture_id,
        status,
        result,
        payout,
        last_updated_at
      FROM bets_view
      WHERE tenant_id = $1 AND user_id = $2
    `;
    
    const params = [tenantId, userId];
    
    if (status) {
      query += ` AND status = $3`;
      params.push(status);
    }
    
    query += ` ORDER BY last_updated_at DESC LIMIT 50`;
    
    const result = await pool.query(query, params);
    
    res.json({
      bets: result.rows,
      total: result.rows.length
    });
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch bets' });
  }
});

// API endpoint для получения баланса
app.get('/users/:userId/balance', extractTenantId, async (req: any, res) => {
  const { userId } = req.params;
  const tenantId = req.tenantId;
  
  try {
    const result = await pool.query(`
      SELECT 
        balance,
        transaction_count,
        last_transaction_at
      FROM user_balances_view
      WHERE tenant_id = $1 AND user_id = $2
    `, [tenantId, userId]);
    
    if (result.rows.length === 0) {
      return res.json({ balance: 0, transaction_count: 0 });
    }
    
    res.json(result.rows[0]);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch balance' });
  }
});
```

### PHP

```php
<?php

class BettingAPI {
    private $db;
    
    public function __construct() {
        $dsn = "pgsql:host=citus-coordinator.dev-infra.svc.cluster.local;port=5432;dbname=app";
        $this->db = new PDO($dsn, 'app', 'app', [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        ]);
    }
    
    private function getTenantId(): int {
        $headers = getallheaders();
        if (!isset($headers['X-Tenant-Id'])) {
            http_response_code(400);
            echo json_encode(['error' => 'Missing X-Tenant-Id header']);
            exit;
        }
        return (int) $headers['X-Tenant-Id'];
    }
    
    // Создать ставку
    public function createBet() {
        $tenantId = $this->getTenantId();
        $input = json_decode(file_get_contents('php://input'), true);
        
        $headers = getallheaders();
        $idempotencyKey = $headers['Idempotency-Key'] ?? null;
        
        if (!$idempotencyKey) {
            http_response_code(400);
            echo json_encode(['error' => 'Missing Idempotency-Key header']);
            return;
        }
        
        $this->db->beginTransaction();
        
        try {
            // 1. Проверить idempotency key в materialized view
            // (триггеры автоматически обновляют view после INSERT)
            $stmt = $this->db->prepare("
                SELECT bet_id FROM bets_view 
                WHERE tenant_id = :tenant_id 
                  AND idempotency_key = :idempotency_key
                LIMIT 1
            ");
            $stmt->execute([
                ':tenant_id' => $tenantId,
                ':idempotency_key' => $idempotencyKey
            ]);
            
            if ($existing = $stmt->fetch()) {
                // Вернуть из view
                $stmt = $this->db->prepare("
                    SELECT * FROM bets_view 
                    WHERE tenant_id = :tenant_id AND bet_id = :bet_id
                ");
                $stmt->execute([
                    ':tenant_id' => $tenantId,
                    ':bet_id' => $existing['bet_id']
                ]);
                
                $this->db->commit();
                http_response_code(200);
                echo json_encode(array_merge($stmt->fetch(), ['duplicate' => true]));
                return;
            }
            
            $betId = 'bet-' . bin2hex(random_bytes(16));
            
            // 2. Вставить событие
            $stmt = $this->db->prepare("
                INSERT INTO bet_events (
                    id, tenant_id, aggregate_id, event_type, event_data, timestamp, version, metadata
                ) VALUES (:id, :tenant_id, :aggregate_id, :event_type, :event_data, :timestamp, :version, :metadata)
            ");
            
            $stmt->execute([
                ':id' => bin2hex(random_bytes(16)),
                ':tenant_id' => $tenantId,
                ':aggregate_id' => $betId,
                ':event_type' => 'V1_BETS_BET_PLACED',
                ':event_data' => json_encode([
                    'user_id' => $input['user_id'],
                    'stake' => $input['stake'],
                    'odds' => $input['odds'],
                    'fixture_id' => $input['fixture_id']
                ]),
                ':timestamp' => round(microtime(true) * 1000),
                ':version' => 1,
                ':metadata' => json_encode(['idempotency_key' => $idempotencyKey])
            ]);
            
            $this->db->commit();
            
            // 3. Подождать пока триггер обновит view
            usleep(200000); // 200ms
            
            // 4. Прочитать из view
            $stmt = $this->db->prepare("
                SELECT * FROM bets_view 
                WHERE tenant_id = :tenant_id AND bet_id = :bet_id
            ");
            $stmt->execute([
                ':tenant_id' => $tenantId,
                ':bet_id' => $betId
            ]);
            
            http_response_code(201);
            echo json_encode($stmt->fetch());
            
        } catch (Exception $e) {
            $this->db->rollBack();
            http_response_code(500);
            echo json_encode(['error' => 'Failed to create bet']);
        }
    }
    
    // Получить ставку
    public function getBet($betId) {
        $tenantId = $this->getTenantId();
        
        $stmt = $this->db->prepare("
            SELECT 
                bet_id,
                user_id,
                stake,
                odds,
                fixture_id,
                status,
                result,
                payout,
                last_updated_at
            FROM bets_view
            WHERE tenant_id = :tenant_id AND bet_id = :bet_id
        ");
        
        $stmt->execute([
            ':tenant_id' => $tenantId,
            ':bet_id' => $betId
        ]);
        
        if ($bet = $stmt->fetch()) {
            echo json_encode($bet);
        } else {
            http_response_code(404);
            echo json_encode(['error' => 'Bet not found']);
        }
    }
    
    // Получить список ставок пользователя
    public function getUserBets($userId) {
        $tenantId = $this->getTenantId();
        $status = $_GET['status'] ?? null;
        
        $query = "
            SELECT 
                bet_id,
                stake,
                odds,
                fixture_id,
                status,
                result,
                payout,
                last_updated_at
            FROM bets_view
            WHERE tenant_id = :tenant_id AND user_id = :user_id
        ";
        
        $params = [
            ':tenant_id' => $tenantId,
            ':user_id' => $userId
        ];
        
        if ($status) {
            $query .= " AND status = :status";
            $params[':status'] = $status;
        }
        
        $query .= " ORDER BY last_updated_at DESC LIMIT 50";
        
        $stmt = $this->db->prepare($query);
        $stmt->execute($params);
        
        echo json_encode([
            'bets' => $stmt->fetchAll(),
            'total' => $stmt->rowCount()
        ]);
    }
    
    // Получить баланс
    public function getUserBalance($userId) {
        $tenantId = $this->getTenantId();
        
        $stmt = $this->db->prepare("
            SELECT 
                balance,
                transaction_count,
                last_transaction_at
            FROM user_balances_view
            WHERE tenant_id = :tenant_id AND user_id = :user_id
        ");
        
        $stmt->execute([
            ':tenant_id' => $tenantId,
            ':user_id' => $userId
        ]);
        
        if ($result = $stmt->fetch()) {
            echo json_encode($result);
        } else {
            echo json_encode([
                'balance' => 0,
                'transaction_count' => 0
            ]);
        }
    }
}

// Роутинг
$api = new BettingAPI();
$method = $_SERVER['REQUEST_METHOD'];
$path = $_SERVER['PATH_INFO'] ?? '/';

if ($method === 'POST' && $path === '/bets') {
    $api->createBet();
} elseif ($method === 'GET' && preg_match('#^/bets/([^/]+)$#', $path, $matches)) {
    $api->getBet($matches[1]);
} elseif ($method === 'GET' && preg_match('#^/users/([^/]+)/bets$#', $path, $matches)) {
    $api->getUserBets($matches[1]);
} elseif ($method === 'GET' && preg_match('#^/users/([^/]+)/balance$#', $path, $matches)) {
    $api->getUserBalance($matches[1]);
} else {
    http_response_code(404);
    echo json_encode(['error' => 'Not found']);
}
```

---

## 🔧 Принципы работы

### 1. Tenant ID из HTTP заголовков

Каждый запрос должен содержать заголовок:
```
X-Tenant-Id: 10001
```

### 2. Все запросы фильтруются по tenant_id

**Критически важно:** Всегда добавляйте `WHERE tenant_id = $tenantId` к каждому запросу для изоляции данных тенантов.

### 3. Event Sourcing + Materialized Views

- **Пишем** → Event tables (immutable, append-only)
- **Триггеры** → Автоматически обновляют views (~100-300ms)
- **Читаем** → Из materialized views (быстро!)

---

```typescript
import pool from './db';
import { TenantRequest } from './middleware';
import { randomUUID } from 'crypto';

interface BetEvent {
  aggregate_id: string;
  event_type: string;
  event_data: Record<string, any>;
}

export async function createBetEvent(
  req: TenantRequest,
  event: BetEvent
) {
  const { tenantId } = req;
  const { aggregate_id, event_type, event_data } = event;
  
  const query = `
    INSERT INTO bet_events (
      id, 
      tenant_id, 
      aggregate_id, 
      event_type, 
      event_data, 
      timestamp, 
      version
    )
    VALUES ($1, $2, $3, $4, $5, $6, $7)
    RETURNING *;
  `;
  
  const values = [
    randomUUID(),
    tenantId,
    aggregate_id,
    event_type,
    JSON.stringify(event_data),
    Date.now(),
    1
  ];
  
  try {
    const result = await pool.query(query, values);
    return result.rows[0];
  } catch (error) {
    console.error('Failed to create bet event:', error);
    throw error;
  }
}

// Использование в Express route
app.post('/bets', extractTenantId, async (req: TenantRequest, res) => {
  try {
    const event = await createBetEvent(req, {
      aggregate_id: `bet-${randomUUID()}`,
      event_type: 'V1_BETS_BET_PLACED',
      event_data: {
        user_id: req.body.user_id,
        stake: req.body.stake,
        odds: req.body.odds,
        fixture_id: req.body.fixture_id
      }
    });
    
    res.status(201).json(event);
  } catch (error) {
    res.status(500).json({ error: 'Failed to place bet' });
  }
});
```

### 2. Чтение событий (SELECT)

> ⚠️ **ВАЖНО:** Этот раздел для **audit/debugging** целей. Для бизнес-логики **ВСЕГДА используйте materialized views** (см. раздел выше).

```typescript
// ⚠️ Только для audit log, time travel, debugging!
// ❌ НЕ используйте для проверки idempotency или бизнес-логики!
export async function getBetEvents(
  tenantId: number,
  aggregateId: string
) {
  const query = `
    SELECT 
      id,
      aggregate_id,
      event_type,
      event_data,
      timestamp,
      version,
      created_at
    FROM bet_events
    WHERE tenant_id = $1 
      AND aggregate_id = $2
    ORDER BY timestamp ASC;
  `;
  
  const result = await pool.query(query, [tenantId, aggregateId]);
  return result.rows;
}

// Получить события за период
export async function getBetEventsByTimeRange(
  tenantId: number,
  startTime: number,
  endTime: number
) {
  const query = `
    SELECT 
      id,
      aggregate_id,
      event_type,
      event_data,
      timestamp,
      version
    FROM bet_events
    WHERE tenant_id = $1 
      AND timestamp >= $2 
      AND timestamp <= $3
    ORDER BY timestamp ASC
    LIMIT 1000;
  `;
  
  const result = await pool.query(query, [tenantId, startTime, endTime]);
  return result.rows;
}

// Использование в route
app.get('/bets/:betId/events', extractTenantId, async (req: TenantRequest, res) => {
  try {
    const events = await getBetEvents(
      req.tenantId,
      req.params.betId
    );
    
    res.json(events);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch events' });
  }
});
```

### 3. Построение проекции (текущее состояние)

> ⚠️ **УСТАРЕВШИЙ ПАТТЕРН!** Не используйте ручное построение проекций - они уже готовы в materialized views!
> 
> Этот раздел оставлен только для понимания концепции Event Sourcing.

```typescript
// ❌ НЕ ДЕЛАЙТЕ ТАК - используйте bets_view вместо этого!
interface BetProjection {
  bet_id: string;
  user_id: string;
  stake: number;
  odds: number;
  status: 'placed' | 'confirmed' | 'settled' | 'cancelled';
  result?: 'win' | 'loss';
  payout?: number;
}

// ❌ МЕДЛЕННО! Восстановление из событий вручную
export async function buildBetProjection(
  tenantId: number,
  betId: string
): Promise<BetProjection | null> {
  const events = await getBetEvents(tenantId, betId);
  
  if (events.length === 0) {
    return null;
  }
  
  // Восстанавливаем состояние из событий
  let projection: Partial<BetProjection> = {
    bet_id: betId,
    status: 'placed'
  };
  
  for (const event of events) {
    const data = event.event_data;
    
    switch (event.event_type) {
      case 'V1_BETS_BET_PLACED':
        projection.user_id = data.user_id;
        projection.stake = data.stake;
        projection.odds = data.odds;
        projection.status = 'placed';
        break;
        
      case 'V1_BETS_BET_CONFIRMED':
        projection.status = 'confirmed';
        break;
        
      case 'V1_BETS_BET_SETTLED':
        projection.status = 'settled';
        projection.result = data.result;
        projection.payout = data.payout;
        break;
        
      case 'V1_BETS_BET_CANCELLED':
        projection.status = 'cancelled';
        break;
    }
  }
  
  return projection as BetProjection;
}

// ❌ НЕПРАВИЛЬНО - медленное восстановление из событий
app.get('/bets/:betId', extractTenantId, async (req: TenantRequest, res) => {
  try {
    const bet = await buildBetProjection(
      req.tenantId,
      req.params.betId
    );
    
    if (!bet) {
      return res.status(404).json({ error: 'Bet not found' });
    }
    
    res.json(bet);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch bet' });
  }
});
```

**✅ ПРАВИЛЬНЫЙ СПОСОБ - читать из materialized view:**

```typescript
// ✅ БЫСТРО! Используем готовую проекцию
app.get('/bets/:betId', extractTenantId, async (req: TenantRequest, res) => {
  try {
    const result = await pool.query(`
      SELECT * FROM bets_view 
      WHERE tenant_id = $1 AND bet_id = $2
    `, [req.tenantId, req.params.betId]);
    
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Bet not found' });
    }
    
    res.json(result.rows[0]);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch bet' });
  }
});
```

### 4. Транзакции с Idempotency Key

**⚠️ ВАЖНО:** Для критических операций (платежи, ставки) используйте idempotency key для защиты от дублирования.

```typescript
export async function processPayment(
  tenantId: number,
  userId: string,
  amount: number,
  idempotencyKey: string // Клиент генерирует и отправляет
) {
  const client = await pool.connect();
  
  try {
    await client.query('BEGIN');
    
    // 1. Проверяем idempotency в materialized view (БЫСТРО!)
    const checkQuery = `
      SELECT payment_id 
      FROM payments_view 
      WHERE tenant_id = $1 
        AND idempotency_key = $2
      LIMIT 1
    `;
    
    const existing = await client.query(checkQuery, [tenantId, idempotencyKey]);
    
    if (existing.rows.length > 0) {
      // Запрос уже обработан - возвращаем из view
      await client.query('COMMIT');
      return { 
        success: true, 
        payment_id: existing.rows[0].payment_id,
        duplicate: true 
      };
    }
    
    // 2. Создаем событие платежа с idempotency key в metadata
    const paymentId = randomUUID();
    await client.query(`
      INSERT INTO payment_events (
        id, tenant_id, aggregate_id, event_type, event_data, timestamp, version, metadata
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    `, [
      randomUUID(),
      tenantId,
      paymentId,
      'V1_PAYMENTS_DEPOSIT_CREATED',
      JSON.stringify({ 
        user_id: userId, 
        amount,
        payment_id: paymentId 
      }),
      Date.now(),
      1,
      JSON.stringify({ 
        idempotency_key: idempotencyKey,
        created_at: new Date().toISOString()
      })
    ]);
    
    // 3. Создаем событие баланса
    await client.query(`
      INSERT INTO balance_events (
        id, tenant_id, aggregate_id, event_type, event_data, timestamp, version, metadata
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    `, [
      randomUUID(),
      tenantId,
      `balance-${userId}`,
      'V1_BALANCES_BALANCE_INCREASED',
      JSON.stringify({ user_id: userId, amount, payment_id: paymentId }),
      Date.now(),
      1,
      JSON.stringify({ 
        idempotency_key: idempotencyKey,
        related_to: paymentId
      })
    ]);
    
    await client.query('COMMIT');
    return { success: true, payment_id: paymentId, duplicate: false };
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

// Использование в Express route
app.post('/payments', extractTenantId, async (req: TenantRequest, res) => {
  const { user_id, amount } = req.body;
  
  // Idempotency Key из заголовка или генерируем
  const idempotencyKey = req.headers['idempotency-key'] as string || 
                         `${req.tenantId}-${user_id}-${Date.now()}-${randomUUID()}`;
  
  if (!req.headers['idempotency-key']) {
    return res.status(400).json({ 
      error: 'Missing Idempotency-Key header' 
    });
  }
  
  try {
    const result = await processPayment(
      req.tenantId,
      user_id,
      amount,
      idempotencyKey
    );
    
    const statusCode = result.duplicate ? 200 : 201;
    res.status(statusCode).json(result);
  } catch (error) {
    res.status(500).json({ error: 'Payment processing failed' });
  }
});
```

#### Генерация Idempotency Key на клиенте:

```typescript
// Frontend/Client example
async function createPayment(userId: string, amount: number) {
  // Генерируем стабильный idempotency key на основе параметров запроса
  const idempotencyKey = `payment-${userId}-${amount}-${Date.now()}`;
  
  const response = await fetch('/payments', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Tenant-Id': '10001',
      'Idempotency-Key': idempotencyKey
    },
    body: JSON.stringify({ user_id: userId, amount })
  });
  
  return response.json();
}

// При retry используем тот же idempotency key
async function createPaymentWithRetry(userId: string, amount: number) {
  const idempotencyKey = `payment-${userId}-${amount}-${Date.now()}`;
  
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      return await fetch('/payments', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Tenant-Id': '10001',
          'Idempotency-Key': idempotencyKey // ТОТ ЖЕ KEY
        },
        body: JSON.stringify({ user_id: userId, amount })
      });
    } catch (error) {
      if (attempt === 2) throw error;
      await new Promise(resolve => setTimeout(resolve, 1000 * (attempt + 1)));
    }
  }
}
```

---

## PHP Examples

### Подключение к базе данных

```php
<?php

class Database {
    private static $instance = null;
    private $connection;
    
    private function __construct() {
        $host = getenv('DATABASE_HOST') ?: 'citus-coordinator.dev-infra.svc.cluster.local';
        $port = getenv('DATABASE_PORT') ?: '5432';
        $dbname = getenv('DATABASE_NAME') ?: 'app';
        $user = getenv('DATABASE_USER') ?: 'app';
        $password = getenv('DATABASE_PASSWORD') ?: 'app';
        
        $dsn = "pgsql:host=$host;port=$port;dbname=$dbname";
        
        $this->connection = new PDO($dsn, $user, $password, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ]);
    }
    
    public static function getInstance(): self {
        if (self::$instance === null) {
            self::$instance = new self();
        }
        return self::$instance;
    }
    
    public function getConnection(): PDO {
        return $this->connection;
    }
}
```

### Middleware для извлечения Tenant ID

```php
<?php

class TenantMiddleware {
    public static function extractTenantId(): int {
        $headers = getallheaders();
        
        if (!isset($headers['X-Tenant-Id'])) {
            http_response_code(400);
            echo json_encode(['error' => 'Missing X-Tenant-Id header']);
            exit;
        }
        
        $tenantId = (int) $headers['X-Tenant-Id'];
        
        if ($tenantId <= 0) {
            http_response_code(400);
            echo json_encode(['error' => 'Invalid X-Tenant-Id format']);
            exit;
        }
        
        return $tenantId;
    }
}
```

## 📝 Примеры работы с разными типами событий

### 1. Запись события ставки (INSERT)

```php
<?php

class BetEventRepository {
    private $db;
    
    public function __construct() {
        $this->db = Database::getInstance()->getConnection();
    }
    
    public function createBetEvent(
        int $tenantId,
        string $aggregateId,
        string $eventType,
        array $eventData
    ): array {
        $query = "
            INSERT INTO bet_events (
                id, 
                tenant_id, 
                aggregate_id, 
                event_type, 
                event_data, 
                timestamp, 
                version
            )
            VALUES (:id, :tenant_id, :aggregate_id, :event_type, :event_data, :timestamp, :version)
            RETURNING *
        ";
        
        $stmt = $this->db->prepare($query);
        $stmt->execute([
            ':id' => $this->generateUUID(),
            ':tenant_id' => $tenantId,
            ':aggregate_id' => $aggregateId,
            ':event_type' => $eventType,
            ':event_data' => json_encode($eventData),
            ':timestamp' => round(microtime(true) * 1000),
            ':version' => 1
        ]);
        
        return $stmt->fetch();
    }
    
    private function generateUUID(): string {
        return sprintf('%04x%04x-%04x-%04x-%04x-%04x%04x%04x',
            mt_rand(0, 0xffff), mt_rand(0, 0xffff),
            mt_rand(0, 0xffff),
            mt_rand(0, 0x0fff) | 0x4000,
            mt_rand(0, 0x3fff) | 0x8000,
            mt_rand(0, 0xffff), mt_rand(0, 0xffff), mt_rand(0, 0xffff)
        );
    }
}

// Использование в API endpoint
$tenantId = TenantMiddleware::extractTenantId();
$repo = new BetEventRepository();

$input = json_decode(file_get_contents('php://input'), true);

try {
    $event = $repo->createBetEvent(
        $tenantId,
        'bet-' . uniqid(),
        'V1_BETS_BET_PLACED',
        [
            'user_id' => $input['user_id'],
            'stake' => $input['stake'],
            'odds' => $input['odds'],
            'fixture_id' => $input['fixture_id']
        ]
    );
    
    http_response_code(201);
    echo json_encode($event);
} catch (Exception $e) {
    http_response_code(500);
    echo json_encode(['error' => 'Failed to place bet']);
}
```

### 2. Чтение событий (SELECT)

```php
<?php

class BetEventRepository {
    // ... (previous code)
    
    public function getBetEvents(int $tenantId, string $aggregateId): array {
        $query = "
            SELECT 
                id,
                aggregate_id,
                event_type,
                event_data,
                timestamp,
                version,
                created_at
            FROM bet_events
            WHERE tenant_id = :tenant_id 
              AND aggregate_id = :aggregate_id
            ORDER BY timestamp ASC
        ";
        
        $stmt = $this->db->prepare($query);
        $stmt->execute([
            ':tenant_id' => $tenantId,
            ':aggregate_id' => $aggregateId
        ]);
        
        $events = $stmt->fetchAll();
        
        // Декодируем JSON в event_data
        foreach ($events as &$event) {
            $event['event_data'] = json_decode($event['event_data'], true);
        }
        
        return $events;
    }
    
    public function getBetEventsByTimeRange(
        int $tenantId,
        int $startTime,
        int $endTime
    ): array {
        $query = "
            SELECT 
                id,
                aggregate_id,
                event_type,
                event_data,
                timestamp,
                version
            FROM bet_events
            WHERE tenant_id = :tenant_id 
              AND timestamp >= :start_time 
              AND timestamp <= :end_time
            ORDER BY timestamp ASC
            LIMIT 1000
        ";
        
        $stmt = $this->db->prepare($query);
        $stmt->execute([
            ':tenant_id' => $tenantId,
            ':start_time' => $startTime,
            ':end_time' => $endTime
        ]);
        
        $events = $stmt->fetchAll();
        
        foreach ($events as &$event) {
            $event['event_data'] = json_decode($event['event_data'], true);
        }
        
        return $events;
    }
}

// Использование
$tenantId = TenantMiddleware::extractTenantId();
$repo = new BetEventRepository();
$betId = $_GET['bet_id'] ?? null;

if (!$betId) {
    http_response_code(400);
    echo json_encode(['error' => 'Missing bet_id parameter']);
    exit;
}

try {
    $events = $repo->getBetEvents($tenantId, $betId);
    echo json_encode($events);
} catch (Exception $e) {
    http_response_code(500);
    echo json_encode(['error' => 'Failed to fetch events']);
}
```

### 3. Построение проекции

```php
<?php

class BetProjectionService {
    private $repo;
    
    public function __construct(BetEventRepository $repo) {
        $this->repo = $repo;
    }
    
    public function buildBetProjection(int $tenantId, string $betId): ?array {
        $events = $this->repo->getBetEvents($tenantId, $betId);
        
        if (empty($events)) {
            return null;
        }
        
        $projection = [
            'bet_id' => $betId,
            'status' => 'placed'
        ];
        
        foreach ($events as $event) {
            $data = $event['event_data'];
            
            switch ($event['event_type']) {
                case 'V1_BETS_BET_PLACED':
                    $projection['user_id'] = $data['user_id'];
                    $projection['stake'] = $data['stake'];
                    $projection['odds'] = $data['odds'];
                    $projection['status'] = 'placed';
                    break;
                    
                case 'V1_BETS_BET_CONFIRMED':
                    $projection['status'] = 'confirmed';
                    break;
                    
                case 'V1_BETS_BET_SETTLED':
                    $projection['status'] = 'settled';
                    $projection['result'] = $data['result'];
                    $projection['payout'] = $data['payout'];
                    break;
                    
                case 'V1_BETS_BET_CANCELLED':
                    $projection['status'] = 'cancelled';
                    break;
            }
        }
        
        return $projection;
    }
}

// Использование
$tenantId = TenantMiddleware::extractTenantId();
$repo = new BetEventRepository();
$service = new BetProjectionService($repo);
$betId = $_GET['bet_id'] ?? null;

try {
    $bet = $service->buildBetProjection($tenantId, $betId);
    
    if ($bet === null) {
        http_response_code(404);
        echo json_encode(['error' => 'Bet not found']);
        exit;
    }
    
    echo json_encode($bet);
} catch (Exception $e) {
    http_response_code(500);
    echo json_encode(['error' => 'Failed to fetch bet']);
}
```

### 4. Транзакции с Idempotency Key

**⚠️ ВАЖНО:** Для критических операций (платежи, ставки) используйте idempotency key для защиты от дублирования.

```php
<?php

class PaymentService {
    private $db;
    
    public function __construct() {
        $this->db = Database::getInstance()->getConnection();
    }
    
    public function processPayment(
        int $tenantId,
        string $userId,
        float $amount,
        string $idempotencyKey
    ): array {
        $this->db->beginTransaction();
        
        try {
            // 1. Проверяем idempotency в materialized view (БЫСТРО!)
            $checkStmt = $this->db->prepare("
                SELECT payment_id 
                FROM payments_view 
                WHERE tenant_id = :tenant_id 
                  AND idempotency_key = :idempotency_key
                LIMIT 1
            ");
            
            $checkStmt->execute([
                ':tenant_id' => $tenantId,
                ':idempotency_key' => $idempotencyKey
            ]);
            
            $existing = $checkStmt->fetch();
            
            if ($existing) {
                // Запрос уже обработан - возвращаем из view
                $this->db->commit();
                return [
                    'success' => true,
                    'payment_id' => $existing['payment_id'],
                    'duplicate' => true
                ];
            }
            
            // 2. Создаем событие платежа с idempotency key в metadata
            $paymentId = $this->generateUUID();
            $timestamp = round(microtime(true) * 1000);
            
            $stmt = $this->db->prepare("
                INSERT INTO payment_events (
                    id, tenant_id, aggregate_id, event_type, event_data, timestamp, version, metadata
                ) VALUES (:id, :tenant_id, :aggregate_id, :event_type, :event_data, :timestamp, :version, :metadata)
            ");
            
            $stmt->execute([
                ':id' => $this->generateUUID(),
                ':tenant_id' => $tenantId,
                ':aggregate_id' => $paymentId,
                ':event_type' => 'V1_PAYMENTS_DEPOSIT_CREATED',
                ':event_data' => json_encode([
                    'user_id' => $userId, 
                    'amount' => $amount,
                    'payment_id' => $paymentId
                ]),
                ':timestamp' => $timestamp,
                ':version' => 1,
                ':metadata' => json_encode([
                    'idempotency_key' => $idempotencyKey,
                    'created_at' => date('c')
                ])
            ]);
            
            // 3. Создаем событие баланса
            $stmt = $this->db->prepare("
                INSERT INTO balance_events (
                    id, tenant_id, aggregate_id, event_type, event_data, timestamp, version, metadata
                ) VALUES (:id, :tenant_id, :aggregate_id, :event_type, :event_data, :timestamp, :version, :metadata)
            ");
            
            $stmt->execute([
                ':id' => $this->generateUUID(),
                ':tenant_id' => $tenantId,
                ':aggregate_id' => "balance-$userId",
                ':event_type' => 'V1_BALANCES_BALANCE_INCREASED',
                ':event_data' => json_encode([
                    'user_id' => $userId,
                    'amount' => $amount,
                    'payment_id' => $paymentId
                ]),
                ':timestamp' => $timestamp,
                ':version' => 1,
                ':metadata' => json_encode([
                    'idempotency_key' => $idempotencyKey,
                    'related_to' => $paymentId
                ])
            ]);
            
            $this->db->commit();
            
            return [
                'success' => true, 
                'payment_id' => $paymentId,
                'duplicate' => false
            ];
        } catch (Exception $e) {
            $this->db->rollBack();
            throw $e;
        }
    }
    
    private function generateUUID(): string {
        return sprintf('%04x%04x-%04x-%04x-%04x-%04x%04x%04x',
            mt_rand(0, 0xffff), mt_rand(0, 0xffff),
            mt_rand(0, 0xffff),
            mt_rand(0, 0x0fff) | 0x4000,
            mt_rand(0, 0x3fff) | 0x8000,
            mt_rand(0, 0xffff), mt_rand(0, 0xffff), mt_rand(0, 0xffff)
        );
    }
}

// Использование в API endpoint
$tenantId = TenantMiddleware::extractTenantId();
$service = new PaymentService();

$input = json_decode(file_get_contents('php://input'), true);

// Idempotency Key из заголовка
$headers = getallheaders();
$idempotencyKey = $headers['Idempotency-Key'] ?? null;

if (!$idempotencyKey) {
    http_response_code(400);
    echo json_encode(['error' => 'Missing Idempotency-Key header']);
    exit;
}

try {
    $result = $service->processPayment(
        $tenantId,
        $input['user_id'],
        $input['amount'],
        $idempotencyKey
    );
    
    $statusCode = $result['duplicate'] ? 200 : 201;
    http_response_code($statusCode);
    echo json_encode($result);
} catch (Exception $e) {
    http_response_code(500);
    echo json_encode(['error' => 'Payment processing failed']);
}
```

#### Создание индекса для быстрой проверки:

```sql
-- Добавить индекс на idempotency_key в metadata для быстрой проверки
CREATE INDEX IF NOT EXISTS idx_payment_events_idempotency 
ON payment_events(tenant_id, ((metadata->>'idempotency_key')));

CREATE INDEX IF NOT EXISTS idx_balance_events_idempotency 
ON balance_events(tenant_id, ((metadata->>'idempotency_key')));

CREATE INDEX IF NOT EXISTS idx_bet_events_idempotency 
ON bet_events(tenant_id, ((metadata->>'idempotency_key')));
```

---

## Idempotency Key Best Practices

### 1. Генерация на клиенте

**Правильно:**
```typescript
// Клиент генерирует UUID один раз
const idempotencyKey = crypto.randomUUID();

// Используется для всех retry
for (let i = 0; i < 3; i++) {
  await fetch('/payments', {
    headers: { 'Idempotency-Key': idempotencyKey }
  });
}
```

**Неправильно:**
```typescript
// ❌ Каждый retry создает новый ключ - приведет к дубликатам!
for (let i = 0; i < 3; i++) {
  await fetch('/payments', {
    headers: { 'Idempotency-Key': crypto.randomUUID() }
  });
}
```

### 2. Формат ключа

Рекомендуется:
```
{resource}-{tenant_id}-{user_id}-{timestamp}-{random}
payment-10001-user123-1700000000000-a3f2c1b0
```

### 3. TTL для idempotency keys

Храните ключи 24-48 часов, затем удаляйте. Создайте cron job или scheduled task:

**TypeScript/Node.js (можно добавить в микросервис):**
```typescript
import { CronJob } from 'cron';

// Запускать каждые 6 часов
new CronJob('0 */6 * * *', async () => {
  const cutoffTime = Date.now() - (48 * 60 * 60 * 1000); // 48 hours ago
  
  await pool.query(`
    UPDATE payment_events 
    SET metadata = metadata - 'idempotency_key'
    WHERE created_at < to_timestamp($1 / 1000.0)
      AND metadata->>'idempotency_key' IS NOT NULL
  `, [cutoffTime]);
  
  console.log('Cleaned up old idempotency keys');
}).start();
```

**SQL (можно запускать через Kubernetes CronJob):**
```sql
-- Удаляем idempotency_key из metadata старше 48 часов
UPDATE payment_events 
SET metadata = metadata - 'idempotency_key'
WHERE created_at < NOW() - INTERVAL '48 hours'
  AND metadata->>'idempotency_key' IS NOT NULL;

UPDATE bet_events 
SET metadata = metadata - 'idempotency_key'
WHERE created_at < NOW() - INTERVAL '48 hours'
  AND metadata->>'idempotency_key' IS NOT NULL;

UPDATE balance_events 
SET metadata = metadata - 'idempotency_key'
WHERE created_at < NOW() - INTERVAL '48 hours'
  AND metadata->>'idempotency_key' IS NOT NULL;
```

**Kubernetes CronJob пример:**
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cleanup-idempotency-keys
spec:
  schedule: "0 */6 * * *"  # Every 6 hours
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: cleanup
            image: postgres:15
            command:
            - /bin/sh
            - -c
            - |
              psql $DATABASE_URL -c "
                UPDATE payment_events 
                SET metadata = metadata - 'idempotency_key'
                WHERE created_at < NOW() - INTERVAL '48 hours'
                  AND metadata->>'idempotency_key' IS NOT NULL;
              "
            env:
            - name: DATABASE_URL
              value: "postgresql://app:app@citus-coordinator:5432/app"
          restartPolicy: OnFailure
```

### 4. Индексы для производительности

```sql
-- Миграция V3: Индексы для idempotency
CREATE INDEX IF NOT EXISTS idx_payment_events_idempotency 
ON payment_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_bet_events_idempotency 
ON bet_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_balance_events_idempotency 
ON balance_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;
```

---

## Важные правила безопасности

### ✅ Всегда делать:

1. **Фильтровать по tenant_id:**
```sql
WHERE tenant_id = $tenantId
```

2. **Использовать prepared statements:**
```typescript
await pool.query('SELECT * FROM events WHERE tenant_id = $1', [tenantId]);
```

3. **Валидировать tenant_id из заголовков:**
```typescript
if (!tenantId || tenantId <= 0) {
  throw new Error('Invalid tenant ID');
}
```

### ❌ Никогда не делать:

1. **Не использовать строковую конкатенацию:**
```typescript
// ❌ ОПАСНО - SQL injection
const query = `SELECT * FROM events WHERE tenant_id = ${tenantId}`;
```

2. **Не пропускать фильтрацию по tenant_id:**
```typescript
// ❌ ОПАСНО - утечка данных между тенантами
const query = 'SELECT * FROM events';
```

3. **Не UPDATE/DELETE событий:**
```typescript
// ❌ Нарушает immutability event sourcing
await pool.query('DELETE FROM bet_events WHERE id = $1', [eventId]);
```

---

## Connection Strings

### Development (Kubernetes)
```bash
# TypeScript/Node.js
DATABASE_URL=postgresql://app:app@citus-coordinator.dev-infra.svc.cluster.local:5432/app

# PHP
DB_HOST=citus-coordinator.dev-infra.svc.cluster.local
DB_PORT=5432
DB_NAME=app
DB_USER=app
DB_PASSWORD=app
```

### Local (port-forward)
```bash
kubectl port-forward -n dev-infra svc/citus-coordinator 5432:5432

# Then use:
DATABASE_URL=postgresql://app:app@localhost:5432/app
```

---

## Тестирование

### Проверка multi-tenancy изоляции

```typescript
// Создаем событие для tenant 10001
await createBetEvent({ tenantId: 10001 }, event);

// Пытаемся прочитать из tenant 10002 - должно быть пусто
const events = await getBetEvents(10002, aggregateId);
assert(events.length === 0, 'Tenant isolation violated!');
```

```php
// Создаем событие для tenant 10001
$repo->createBetEvent(10001, $aggregateId, $eventType, $data);

// Пытаемся прочитать из tenant 10002 - должно быть пусто
$events = $repo->getBetEvents(10002, $aggregateId);
assert(count($events) === 0, 'Tenant isolation violated!');
```
