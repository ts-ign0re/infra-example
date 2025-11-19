# Архитектура хранения

### TIER 1: Критические события (отдельные таблицы)

**1. bet_events** - События ставок

**2. payment_events** - Финансовые транзакции

**3. balance_events** - Перемещение средств балансов клиентов

**4. compliance_events** - Регуляторные события

### TIER 2: Некритические события (единая таблица)

**5. system_events** - Все остальные события

---

## 1. bet_events

**Назначение:** Основная бизнес-логика платформы

**Характеристики:**

- Высокая частота записи (10,000 bets/sec)
- Специальные индексы по odds, fixtures
- Retention: 1-2 года, затем архив в S3
- Партиционирование по timestamp (месячные партиции)

**События (event_type, UPPER_SNAKE_CASE):**

- `V1_BETS_BET_PLACED` - пользователь делает ставку
- `V1_BETS_BET_RESERVED` - баланс зарезервирован для ставки
- `V1_BETS_BET_CONFIRMED` - ставка подтверждена системой
- `V1_BETS_BET_REJECTED` - ставка отклонена (compliance, risk, odds changed)
- `V1_BETS_BET_SETTLED` - ставка рассчитана (win/loss)
- `V1_BETS_BET_CANCELLED` - ставка отменена (fixture cancelled)
- `V1_BETS_BET_VOIDED` - ставка аннулирована (возврат средств)

**Avro Schema:** `schemas/BetEvent.avsc`

**Структура:**

- `id` (string) - уникальный ID события
- `tenant_id` (string) - ID тенанта
- `aggregate_id` (string) - ID ставки
- `event_type` (enum BetEventType) - тип события (UPPER_SNAKE_CASE, без точек)
- `event_name` (string) - полное дот‑имя события `v1.bets.bet.placed`
- `event_data` (map) - данные события (bet_id, user_id, stake, odds, fixture_id, etc.)
- `timestamp` (long) - Unix timestamp в миллисекундах
- `version` (int) - версия схемы

**Проекции:**

- bets (текущее состояние ставок)
- user_betting_stats (аналитика)
- active_bets_view (для операторов)
- betting_patterns (для fraud detection)

---

## 2. payment_events

**Назначение:** Реальные финансовые транзакции с внешним миром

**Характеристики:**

- Внешние провайдеры (Stripe, PayPal, TrueLayer, Ecommpay)
- Retention: 7-10 лет (законодательное требование)
- Immutable (запрет UPDATE/DELETE)
- Encryption at rest обязательно

**События (event_type, UPPER_SNAKE_CASE):**

**Депозиты:**

- `V1_PAYMENTS_DEPOSIT_CREATED` - пользователь начал депозит
- `V1_PAYMENTS_DEPOSIT_PENDING` - ожидание подтверждения от провайдера
- `V1_PAYMENTS_DEPOSIT_COMPLETED` - деньги успешно зачислены
- `V1_PAYMENTS_DEPOSIT_FAILED` - депозит не прошел
- `V1_PAYMENTS_DEPOSIT_REFUNDED` - возврат депозита

**Выводы:**

- `V1_PAYMENTS_WITHDRAWAL_REQUESTED` - запрос на вывод средств
- `V1_PAYMENTS_WITHDRAWAL_PENDING` - на проверке (KYC, AML)
- `V1_PAYMENTS_WITHDRAWAL_APPROVED` - одобрен для обработки
- `V1_PAYMENTS_WITHDRAWAL_COMPLETED` - деньги отправлены
- `V1_PAYMENTS_WITHDRAWAL_REJECTED` - вывод отклонен
- `V1_PAYMENTS_WITHDRAWAL_CANCELLED` - пользователь отменил (а должна ли быть такая опция?)

**Споры:**

- `V1_PAYMENTS_CHARGEBACK_RECEIVED` - банк вернул деньги (dispute)
- `V1_PAYMENTS_CHARGEBACK_DISPUTED` - оспариваем chargeback
- `V1_PAYMENTS_CHARGEBACK_WON` - спор выигран
- `V1_PAYMENTS_CHARGEBACK_LOST` - спор проигран

**Avro Schema:** `schemas/PaymentEvent.avsc`

**Структура:**

- `id` (string) - уникальный ID события
- `tenant_id` (string) - ID тенанта
- `aggregate_id` (string) - ID платежа
- `event_type` (enum PaymentEventType) - тип события (UPPER_SNAKE_CASE, без точек)
- `event_name` (string) - полное дот‑имя события `v1.payments.deposit.completed`
- `event_data` (map) - данные события (user_id, amount, currency, payment_method, provider, etc.)
- `timestamp` (long) - Unix timestamp в миллисекундах
- `version` (int) - версия схемы

**Проекции:**

- payment_transactions (текущие транзакции)
- user_payment_history (история платежей)
- financial_reports (для finance team)
- daily_reconciliation (ежедневная сверка)

---

## 3. balance_events

**Назначение:** Перемещение средств балансов клиентов (виртуальные балансы внутри платформы, блокировка средств для ставок, начисление выигрыша, коррекция и тп)

**Характеристики:**

- Высокая частота (тысячи операций в секунду)
- Виртуальный баланс внутри платформы
- Retention: 7 лет (audit requirement)
- Optimistic locking (version control)
- Balance reconciliation critical
- Шардирование Citus по tenant_id

**События (event_type, UPPER_SNAKE_CASE):**

**Резервирование:**

- `V1_BALANCES_BALANCE_RESERVED` - зарезервировали деньги для ставки
- `V1_BALANCES_BALANCE_RELEASED` - ставка отменена, вернули резерв

**Списание/Зачисление:**

- `V1_BALANCES_BALANCE_DEBITED` - списали деньги (проигранная ставка, вывод)
- `V1_BALANCES_BALANCE_CREDITED` - зачислили деньги (выигранная ставка, депозит)

**Бонусы:**

- `V1_BALANCES_BONUS_ADDED` - начислили бонусный баланс
- `V1_BALANCES_BONUS_DEBITED` - использовали бонус для ставки
- `V1_BALANCES_BONUS_CONVERTED` - бонус отыгран, стал реальным балансом
- `V1_BALANCES_BONUS_EXPIRED` - бонус истек
- `V1_BALANCES_BONUS_CANCELLED` - бонус отменен

**Avro Schema:** `schemas/BalanceEvent.avsc`

**Структура:**

- `id` (string) - уникальный ID события
- `tenant_id` (string) - ID тенанта
- `aggregate_id` (string) - ID баланса клиента
- `event_type` (enum BalanceEventType) - тип события (UPPER_SNAKE_CASE, без точек)
- `event_name` (string) - полное дот‑имя события `v1.balances.balance.reserved`
- `event_data` (map) - данные события (user_id, amount, balance, bet_id, payment_id, etc.)
- `timestamp` (long) - Unix timestamp в миллисекундах
- `version` (int) - версия схемы

**Проекции:**

- balances (текущие балансы клиентов)
- transaction_ledger (полная история)
- balance_reconciliation_view (проверка целостности)
- user_balance_history (история по клиенту)

---

## 4. compliance_events

**Назначение:** Регуляторные события для аудита

**Характеристики:**

- Regulatory audit trail для complience отдела
- Может быть запрошен регулятором
- Retention: 5-10 лет (в зависимости от страны регулятора)
- Immutable + signed (tamper-proof)
- Нельзя удалять (GDPR exception)

**События (event_type, UPPER_SNAKE_CASE):**

**KYC/Верификация:**

- `V1_COMPLIANCE_KYC_STARTED` - начата проверка документов
- `V1_COMPLIANCE_KYC_COMPLETED` - верификация успешна
- `V1_COMPLIANCE_KYC_FAILED` - верификация провалена
- `V1_COMPLIANCE_DOCUMENT_UPLOADED` - загружен документ
- `V1_COMPLIANCE_ADDRESS_VERIFIED` - адрес подтвержден
- `V1_COMPLIANCE_AML_SCREENED` - AML проверка выполнена

**Responsible Gaming:**

- `V1_COMPLIANCE_EXCLUSION_ACTIVATED` - пользователь включил self-exclusion
- `V1_COMPLIANCE_EXCLUSION_EXPIRED` - период self-exclusion истек
- `V1_COMPLIANCE_COOLING_OFF_ACTIVATED` - cooling-off период включен
- `V1_COMPLIANCE_LIMIT_LOSS_EXCEEDED` - превышен дневной лимит проигрыша
- `V1_COMPLIANCE_LIMIT_DEPOSIT_SET` - установлен лимит депозита
- `V1_COMPLIANCE_LIMIT_DEPOSIT_EXCEEDED` - превышен лимит депозита
- `V1_COMPLIANCE_RG_ALERT_TRIGGERED` - сработал RG алерт

**Риски:**

- `V1_COMPLIANCE_RISK_CALCULATED` - рассчитан риск-скор пользователя/ставки
- `V1_COMPLIANCE_RISK_DETECTED` - обнаружено рискованное поведение
- `V1_COMPLIANCE_FRAUD_DETECTED` - сработал алерт о мошенничестве
- `V1_COMPLIANCE_MULTI_ACCOUNTING_SUSPECTED` - подозрение на multi-accounting

**Блокировки:**

- `V1_COMPLIANCE_USER_BLOCKED` - оператор заблокировал пользователя
- `V1_COMPLIANCE_USER_UNBLOCKED` - разблокирован оператором
- `V1_COMPLIANCE_IP_BLOCKED` - IP адрес заблокирован
- `V1_COMPLIANCE_JURISDICTION_DENIED` - доступ из юрисдикции запрещен

**Нарушения:**

- `V1_COMPLIANCE_VIOLATION_DETECTED` - обнаружено нарушение compliance
- `V1_COMPLIANCE_UNDERAGE_ATTEMPTED` - попытка игры несовершеннолетним
- `V1_COMPLIANCE_JURISDICTION_UNAUTHORIZED` - доступ из запрещенной юрисдикции
- `V1_COMPLIANCE_TRANSACTION_SUSPICIOUS` - подозрительная транзакция

**Avro Schema:** `schemas/ComplianceEvent.avsc`

**Структура:**

- `id` (string) - уникальный ID события
- `tenant_id` (string) - ID тенанта
- `aggregate_id` (string) - ID пользователя или сущности
- `event_type` (enum ComplianceEventType) - тип события (UPPER_SNAKE_CASE, без точек)
- `event_name` (string) - полное дот‑имя события `v1.compliance.kyc.started`
- `event_data` (map) - данные события (user_id, reason, risk_score, jurisdiction, etc.)
- `timestamp` (long) - Unix timestamp в миллисекундах
- `version` (int) - версия схемы

**Проекции:**

- compliance_audit_log (для регуляторов)
- user_risk_profile (профиль риска пользователя)
- regulatory_reports (отчеты для регуляторов)
- violation_alerts (алерты о нарушениях)
- и так далее все здесь описывать не будем, список может быть огромным

---

## 5. system_events

**Назначение:** Все некритические события системы

**Характеристики:**

- Разнородные события
- Можно удалять (GDPR compliant)
- Retention: 90 дней
- Используется для analytics, debugging

**События:**

**Пользователи (event_type, UPPER_SNAKE_CASE):**

- `V1_SYSTEM_USER_REGISTERED` - новый пользователь зарегистрирован
- `V1_SYSTEM_USER_LOGGED_IN` - пользователь вошел в систему
- `V1_SYSTEM_USER_LOGGED_OUT` - пользователь вышел
- `V1_SYSTEM_USER_PROFILE_UPDATED` - обновлен профиль
- `V1_SYSTEM_USER_PASSWORD_CHANGED` - изменен пароль
- `V1_SYSTEM_USER_EMAIL_VERIFIED` - email подтвержден
- `V1_SYSTEM_USER_2FA_ENABLED` - включена двухфакторная аутентификация
- `V1_SYSTEM_USER_SESSION_EXPIRED` - сессия истекла

**Уведомления (event_type, UPPER_SNAKE_CASE):**

- `V1_SYSTEM_NOTIFICATION_SENT` - уведомление отправлено
- `v1.system.email.sent` - email отправлен
- `v1.system.email.delivered` - email доставлен
- `v1.system.email.bounced` - email не доставлен
- `V1_SYSTEM_SMS_SENT` - SMS отправлено
- `V1_SYSTEM_PUSH_SENT` - push уведомление отправлено

**Матчи/Коэффициенты (event_type, UPPER_SNAKE_CASE):**

- `V1_SYSTEM_FIXTURE_BOOKED` - матч забронирован у провайдера
- `V1_SYSTEM_FIXTURE_STARTED` - матч начался
- `V1_SYSTEM_FIXTURE_ENDED` - матч закончился
- `V1_SYSTEM_FIXTURE_CANCELLED` - матч отменен
- `V1_SYSTEM_FIXTURE_POSTPONED` - матч перенесен
- `V1_SYSTEM_ODDS_UPDATED` - обновлены коэффициенты
- `v1.system.market.opened` - рынок открыт для ставок
- `v1.system.market.closed` - рынок закрыт
- `v1.system.market.suspended` - рынок приостановлен

**Бонусные кампании (event_type, UPPER_SNAKE_CASE):**

- `V1_SYSTEM_CAMPAIGN_CREATED` - создана кампания
- `V1_SYSTEM_CAMPAIGN_ACTIVATED` - кампания активирована
- `V1_SYSTEM_CAMPAIGN_PAUSED` - кампания приостановлена
- `V1_SYSTEM_CAMPAIGN_ENDED` - кампания завершена
- `V1_SYSTEM_BONUS_AWARDED` - бонус присужден пользователю
- `V1_SYSTEM_TOURNAMENT_CREATED` - турнир создан
- `V1_SYSTEM_TOURNAMENT_STARTED` - турнир начался
- `V1_SYSTEM_TOURNAMENT_ENDED` - турнир завершен

**Административные (event_type, UPPER_SNAKE_CASE):**

- `V1_SYSTEM_ADMIN_ACTION_PERFORMED` - выполнено действие администратора
- `V1_SYSTEM_CONFIG_CHANGED` - изменена конфигурация
- `V1_SYSTEM_FEATURE_FLAG_TOGGLED` - переключен feature flag
- `V1_SYSTEM_MAINTENANCE_ENABLED` - включен режим обслуживания
- `V1_SYSTEM_MAINTENANCE_DISABLED` - выключен режим обслуживания
- `V1_SYSTEM_TENANT_CREATED` - создан новый tenant
- `V1_SYSTEM_TENANT_UPDATED` - обновлен tenant
- `V1_SYSTEM_TENANT_DEACTIVATED` - tenant деактивирован

**Аналитика (event_type, UPPER_SNAKE_CASE):**

- `v1.system.page.viewed` - просмотр страницы
- `V1_SYSTEM_BUTTON_CLICKED` - клик по кнопке
- `V1_SYSTEM_FEATURE_USED` - использована функция
- `V1_SYSTEM_ERROR_OCCURRED` - произошла ошибка
- `V1_SYSTEM_PERFORMANCE_RECORDED` - записана метрика производительности

**Avro Schema:** `schemas/SystemEvent.avsc`

**Структура:**

- `id` (string) - уникальный ID события
- `tenant_id` (string) - ID тенанта
- `aggregate_id` (string) - ID связанной сущности
- `event_type` (string) - тип события (строка, UPPER_SNAKE_CASE, например `V1_SYSTEM_USER_REGISTERED`)
- `event_data` (map) - данные события
- `timestamp` (long) - Unix timestamp в миллисекундах
- `version` (int) - версия схемы

> **Примечание:** SystemEvent использует `string` для event_type (не enum), т.к. эти события часто меняются и некритичны для бизнеса.
>

**Проекции:**

- analytics_dashboard (операционная аналитика)
- operational_metrics (метрики системы)
- user_activity_log (активность пользователей)
- error_tracking (отслеживание ошибок)
- feature_usage_stats (статистика использования функций)

---

## Retention Policies

**bet_events:**

- Active: 2 года (hot storage)
- Archive: после 2 лет → S3 Glacier
- Deletion: никогда

**payment_events:**

- Active: 10 лет (regulatory requirement)
- Archive: никогда не удаляется
- Deletion: никогда

**balance_events:**

- Active: уточнить audit requrements и установить срок хранения (+ S3 cold storage по истечению 30-60 дней после события)
- Archive: после N лет → S3 (где N - задано в конфигурации региона)
- Deletion: через N лет (только после архива) - (где N - задано в конфигурации региона)

**compliance_events:**

- Active: N лет (regulatory requirement)
- Archive: никогда не удаляется
- Deletion: никогда (GDPR exception)

**system_events:**

- Active: 30-90 дней в зависимости от важности, возможно хранить логи доступов к пользовательским аккаунтам от саппортов и тп
- Deletion: автоматическое удаление старых партиций
- Archive: не требуется

---

## Bounded Contexts

Это разные bounded contexts в DDD:

- **bet_events** = Betting Context
- **payment_events** = Payment Context (внешние операции с клиентскими средствами)
- **balance_events** = Balance Context (внутренние операции с клиентскими средствами)
- **compliance_events** = Compliance Context
- **user_event -** действия пользователя, например изменение никнейм, аватара, пароля и тп, логирование входа выхода
- **system_events** = System Context (все вспомогательные события системы, внутренние нужды)

Каждый context может эволюционировать независимо.

---

## Преимущества гибридного подхода

**Compliance-friendly:**

- Финансовые события изолированы
- Разные retention policies
- Четкое разделение для регуляторов

**Performance:**

- Меньшие таблицы = быстрее queries
- Специализированные индексы
- Оптимальное партиционирование

**Clear bounded contexts:**

- DDD alignment
- Изолированные схемы
- Независимая эволюция

**Flexible retention:**

- Разные сроки хранения
- Разные политики архивирования
- Оптимизация storage costs

**Easier audit:**

- Регулятор видит четкое разделение
- Простой экспорт для compliance
- Immutable где необходимо

---

## Event Naming Convention

Все события имеют полное имя: **`event_name = v1.{context}.{entity}.{action}`**

### Структура имени события:

- **v1** - версия API (для schema evolution)
- **{context}** - bounded context (payments, bets, balances, compliance, system)
- **{entity}** - сущность (deposit, withdrawal, bet, balance, kyc)
-- **{action}** - действие (created, pending, completed, failed, rejected)

Для TIER1 дополнительно вводится enum **`event_type`** (UPPER_SNAKE_CASE, без точек), который маппится 1:1 к `event_name`.

### Kafka Topics

Kafka топики соответствуют контексту:

```
v1.payments     → все события payments (deposit, withdrawal, chargeback)
v1.bets         → все события ставок
v1.balances     → все события балансов
v1.compliance   → все compliance события
v1.system       → все системные события
```

---

## Хранение денежных сумм

**ВАЖНО: Все денежные суммы хранятся в центах как BigInt (long в Avro).**

**АБСОЛЮТНО ЗАПРЕЩЕНО использовать `double` или `float` для денег**

**Причины:**

- Избегание проблем с точностью floating point
- Точные финансовые расчёты без округлений
- Совместимость с финансовыми стандартами
- Regulatory compliance (регуляторы требуют точность)
- Форматирование на стороне клиента в любую валюту по любым правилам клиента (регион, юрисдикция, смотри Intl модуль)

**Конвертация:**

- $100.00 → `10000` (центов)
- $10.50 → `1050` (центов)
- $0.01 → `1` (цент)
- €50.99 → `5099` (евроцентов)

**Пример в коде:**

```jsx
// Node.js - отправка события
const event = {
  event_type: "V1_PAYMENTS_DEPOSIT_COMPLETED",  // UPPER_SNAKE_CASE в enum
  event_name: "v1.payments.deposit.completed",  // dot-notation для людей
  event_data: {
    amount: 10000,  // рендерим как $100.00
    currency: "USD"
  }
};

// Конвертация для отображения пользователю
const dollars = event.event_data.amount / 100;  // 100.00
```

```php
// PHP - получение события
$amount = $event['event_data']['amount'];  // 10000 (в центах)
$dollars = $amount / 100;  // 100.00
```

**Для валют без центов (JPY, KRW):**

- Храним сумму как есть: ¥100 → `100`
- Важно учитывать в логике конвертации

---

## Namespace в Avro

**Namespace** — это механизм логической организации схем, аналогичный пакетам в Java или namespace в C#.

**За что отвечает namespace:**

1. **Предотвращение конфликтов имён**
    - Если у вас есть `BetEvent` в разных контекстах
    - Namespace делает их уникальными: `io.sportify.bets.BetEvent` vs [`io.analytics.events](http://io.analytics.events).BetEvent`
2. **Полное имя типа (Fully Qualified Name)**
    - `"namespace": "io.sportify.payments"`
    - `"name": "PaymentEvent"`
    - Полное имя: `io.sportify.payments.PaymentEvent`
3. **Организация в Schema Registry**
    - Confluent Schema Registry использует namespace для группировки
    - Схемы можно искать и фильтровать по namespace
4. **Генерация кода**
    - В Java: класс будет в пакете `io.sportify.payments`
    - В Python: модуль `io.sportify.payments`
    - В C#: namespace `Io.Sportify.Payments`

**Наши namespace:**

- `io.sportify.bets` - события ставок
- `io.sportify.payments` - платежные события
- `io.sportify.balances` - события балансов
- `io.sportify.compliance` - compliance события
- `io.sportify.system` - системные события

---

## Avro Schema Registry

Все схемы событий сохраняются в отдельные `.avsc` файлы в директории `schemas/`:

- `schemas/BetEvent.avsc` - События ставок
- `schemas/PaymentEvent.avsc` - Платежные события
- `schemas/BalanceEvent.avsc` - События балансов
- `schemas/ComplianceEvent.avsc` - Compliance события
- `schemas/SystemEvent.avsc` - Системные события

### Примечания по схемам событий

- Для TIER1 (bets, payments, balances, compliance):
  - `event_type`: enum с UPPER_SNAKE_CASE символами, валидными для Avro.
  - `event_name`: строка с точками для человеко‑читаемого канонического имени.
- Для `system_events`: `event_type` — строка, без enum (частые изменения).
- Subject naming: TopicNameStrategy → `{topic}-value`.
- Совместимость: BACKWARD_TRANSITIVE на subject.

### Преимущества Avro для кроссплатформенности:

**Компактность:**

- Бинарный формат → меньше размер сообщений в Kafka
- Нет overhead от имен полей в каждом сообщении
- Enum вместо строк → экономия 80-90% места, системные сообщения строкой для гибкости

**Эволюция схемы:**

- Schema evolution из коробки (backwards/forwards compatibility)
- Добавление новых полей с default values не ломает старых consumers
- Добавление новых enum symbols в конец списка безопасно

**Типо безопасность:**

- Строгая типизация на уровне схемы
- Автоматическая валидация при сериализации/десериализации
- Enum защищает от опечаток и неправильных значений

**Кроссплатформенность:**

- Единая схема для Node.js, PHP, Python, Java и др.
- Совместимость гарантирована на уровне Avro спецификации

**Контроль эволюции:**

- Централизованный список всех событий в symbols
- Git history показывает когда и кем добавлены события
- Code review для каждого нового события
- Compliance-friendly для регуляторов

---

## Использование в Node.js и PHP

### Node.js (avsc)

```jsx
const avro = require('avsc');
const { Kafka } = require('kafkajs');

// Загрузка схемы
const paymentEventSchema = require('./schemas/PaymentEvent.avsc');
const paymentEventType = avro.Type.forSchema(paymentEventSchema);

// Producer
const producer = kafka.producer();

await producer.send({
  topic: 'V1_PAYMENTS',
  messages: [{
    key: 'payment-123',
    value: paymentEventType.toBuffer({
      id: "evt-001",
      tenant_id: 10001,  // long, не string
      aggregate_id: "payment-123",
      event_type: "V1_PAYMENTS_DEPOSIT_COMPLETED",
      event_name: "v1.payments.deposit.completed",
      event_data: {
        user_id: "user-456",
        amount: 10000,  // $100.00 в центах
        currency: "USD",
        payment_method: "credit_card",
        provider: "stripe"
      },
      timestamp: Date.now(),
      version: 1
    })
  }]
});

// Consumer
const consumer = kafka.consumer({ groupId: 'payment-processor' });
await consumer.subscribe({ topic: 'v1.payments' });

await [consumer.run](http://consumer.run)({
  eachMessage: async ({ message }) => {
    const event = paymentEventType.fromBuffer(message.value);
    console.log('Received event:', event.event_type);

    // Обработка события
    switch(event.event_type) {
      case 'V1_PAYMENTS_DEPOSIT_COMPLETED':
        await handleDepositCompleted(event);
        break;
      // ...
    }
  }
});
```

### PHP (avro-php)

```php
use Apache\Avro\Schema;
use Apache\Avro\Datum\IODatumReader;
use Apache\Avro\Datum\IODatumWriter;
use Apache\Avro\IO\StringIO;
use Apache\Avro\IO\BinaryEncoder;
use Apache\Avro\IO\BinaryDecoder;

// Загрузка схемы
$schemaJson = file_get_contents('schemas/PaymentEvent.avsc');
$schema = Schema::parse($schemaJson);

// Producer
$writer = new IODatumWriter($schema);
$io = new StringIO();
$encoder = new BinaryEncoder($io);

$event = [
    'id' => 'evt-001',
    'tenant_id' => 10001,  // long, не string
    'aggregate_id' => 'payment-123',
    'event_type' => 'V1_PAYMENTS_DEPOSIT_COMPLETED',
    'event_name' => 'v1.payments.deposit.completed',
    'event_data' => [
        'user_id' => 'user-456',
        'amount' => 10000,  // $100.00 в центах
        'currency' => 'USD'
    ],
    'timestamp' => time() * 1000,
    'version' => 1
];

$writer->write($event, $encoder);
$avroData = $io->string();

// Отправка в Kafka
$producer->produce(RD_KAFKA_PARTITION_UA, 0, $avroData, 'payment-123');

// Consumer
$reader = new IODatumReader($schema);
$io = new StringIO($message->payload);
$decoder = new BinaryDecoder($io);
$event = $reader->read($decoder);

// Обработка события
switch ($event['event_type']) {
    case 'V1_PAYMENTS_DEPOSIT_COMPLETED':
        handleDepositCompleted($event);
        break;
    // ...
}
```

---

## Полные примеры Avro схем

### schemas/PaymentEvent.avsc

```json
{
  "type": "record",
  "name": "PaymentEvent",
  "namespace": "io.sportify.payments",
  "doc": "События платежей (депозиты, выводы, chargebacks)",
  "fields": [
    {
      "name": "id",
      "type": "string",
      "doc": "Уникальный ID события (UUID)"
    },
    {
      "name": "tenant_id",
      "type": "long",
      "doc": "ID тенанта (white-label оператора)"
    },
    {
      "name": "aggregate_id",
      "type": "string",
      "doc": "ID платежа (aggregate root)"
    },
    {
      "name": "event_type",
      "type": {
        "type": "enum",
        "name": "PaymentEventType",
        "doc": "Типы событий платежей. ВАЖНО: добавлять новые события только В КОНЕЦ списка!",
        "symbols": [
          "V1_PAYMENTS_DEPOSIT_CREATED",
          "V1_PAYMENTS_DEPOSIT_PENDING",
          "V1_PAYMENTS_DEPOSIT_COMPLETED",
          "V1_PAYMENTS_DEPOSIT_FAILED",
          "V1_PAYMENTS_DEPOSIT_REFUNDED",
          "V1_PAYMENTS_WITHDRAWAL_REQUESTED",
          "V1_PAYMENTS_WITHDRAWAL_PENDING",
          "V1_PAYMENTS_WITHDRAWAL_APPROVED",
          "V1_PAYMENTS_WITHDRAWAL_COMPLETED",
          "V1_PAYMENTS_WITHDRAWAL_REJECTED",
          "V1_PAYMENTS_WITHDRAWAL_CANCELLED",
          "V1_PAYMENTS_CHARGEBACK_RECEIVED",
          "V1_PAYMENTS_CHARGEBACK_DISPUTED",
          "V1_PAYMENTS_CHARGEBACK_WON",
          "V1_PAYMENTS_CHARGEBACK_LOST"
        ]
      },
      "doc": "Тип события из списка symbols"
    },
    {
      "name": "event_data",
      "type": {
        "type": "map",
        "values": ["null", "string", "long", "double", "boolean"]
      },
      "doc": "Данные события в формате key-value. Денежные суммы ВСЕГДА в центах (long)!"
    },
    {
      "name": "timestamp",
      "type": "long",
      "doc": "Unix timestamp в миллисекундах"
    },
    {
      "name": "version",
      "type": "int",
      "default": 1,
      "doc": "Версия схемы события"
    },
    {
      "name": "metadata",
      "type": [
        "null",
        {
          "type": "map",
          "values": "string"
        }
      ],
      "default": null,
      "doc": "Опциональные метаданные (correlation_id, user_agent, ip_address, etc.)"
    }
  ]
}
```

### schemas/BetEvent.avsc

```json
{
  "type": "record",
  "name": "BetEvent",
  "namespace": "io.sportify.bets",
  "doc": "События ставок",
  "fields": [
    {
      "name": "id",
      "type": "string",
      "doc": "Уникальный ID события (UUID)"
    },
    {
      "name": "tenant_id",
      "type": "long",
      "doc": "ID тенанта (white-label оператора)"
    },
    {
      "name": "aggregate_id",
      "type": "string",
      "doc": "ID ставки (aggregate root)"
    },
    {
      "name": "event_type",
      "type": {
        "type": "enum",
        "name": "BetEventType",
        "doc": "Типы событий ставок. ВАЖНО: добавлять новые события только В КОНЕЦ списка!",
        "symbols": [
          "V1_BETS_BET_PLACED",
          "V1_BETS_BET_RESERVED",
          "V1_BETS_BET_CONFIRMED",
          "V1_BETS_BET_REJECTED",
          "V1_BETS_BET_SETTLED",
          "V1_BETS_BET_CANCELLED",
          "V1_BETS_BET_VOIDED"
        ]
      },
      "doc": "Тип события из списка symbols"
    },
    {
      "name": "event_data",
      "type": {
        "type": "map",
        "values": ["null", "string", "long", "double", "boolean"]
      },
      "doc": "Данные события (bet_id, user_id, stake, odds, fixture_id, etc.). Stake и payout в центах (long)!"
    },
    {
      "name": "timestamp",
      "type": "long",
      "doc": "Unix timestamp в миллисекундах"
    },
    {
      "name": "version",
      "type": "int",
      "default": 1,
      "doc": "Версия схемы события"
    },
    {
      "name": "metadata",
      "type": [
        "null",
        {
          "type": "map",
          "values": "string"
        }
      ],
      "default": null,
      "doc": "Опциональные метаданные"
    }
  ]
}
```

### schemas/BalanceEvent.avsc

```json
{
  "type": "record",
  "name": "BalanceEvent",
  "namespace": "io.sportify.balances",
  "doc": "События перемещения средств балансов клиентов",
  "fields": [
    {
      "name": "id",
      "type": "string",
      "doc": "Уникальный ID события (UUID)"
    },
    {
      "name": "tenant_id",
      "type": "long",
      "doc": "ID тенанта"
    },
    {
      "name": "aggregate_id",
      "type": "string",
      "doc": "ID баланса клиента"
    },
    {
      "name": "event_type",
      "type": {
        "type": "enum",
        "name": "BalanceEventType",
        "doc": "Типы событий балансов. ВАЖНО: добавлять новые события только В КОНЕЦ списка!",
        "symbols": [
          "V1_BALANCES_BALANCE_RESERVED",
          "V1_BALANCES_BALANCE_RELEASED",
          "V1_BALANCES_BALANCE_DEBITED",
          "V1_BALANCES_BALANCE_CREDITED",
          "V1_BALANCES_BONUS_ADDED",
          "V1_BALANCES_BONUS_DEBITED",
          "V1_BALANCES_BONUS_CONVERTED",
          "V1_BALANCES_BONUS_EXPIRED",
          "V1_BALANCES_BONUS_CANCELLED"
        ]
      }
    },
    {
      "name": "event_data",
      "type": {
        "type": "map",
        "values": ["null", "string", "long", "double", "boolean"]
      },
      "doc": "Данные события (user_id, amount, balance, bet_id, payment_id, etc.). Все суммы в центах (long)!"
    },
    {
      "name": "timestamp",
      "type": "long"
    },
    {
      "name": "version",
      "type": "int",
      "default": 1
    },
    {
      "name": "metadata",
      "type": ["null", {"type": "map", "values": "string"}],
      "default": null
    }
  ]
}
```

### schemas/ComplianceEvent.avsc

```json
{
  "type": "record",
  "name": "ComplianceEvent",
  "namespace": "io.sportify.compliance",
  "doc": "Регуляторные события для аудита",
  "fields": [
    {
      "name": "id",
      "type": "string"
    },
    {
      "name": "tenant_id",
      "type": "long"
    },
    {
      "name": "aggregate_id",
      "type": "string",
      "doc": "ID пользователя или сущности"
    },
    {
      "name": "event_type",
      "type": {
        "type": "enum",
        "name": "ComplianceEventType",
        "doc": "Типы compliance событий. ВАЖНО: добавлять новые события только В КОНЕЦ списка!",
        "symbols": [
          "V1_COMPLIANCE_KYC_STARTED",
          "V1_COMPLIANCE_KYC_COMPLETED",
          "V1_COMPLIANCE_KYC_FAILED",
          "V1_COMPLIANCE_DOCUMENT_UPLOADED",
          "V1_COMPLIANCE_ADDRESS_VERIFIED",
          "V1_COMPLIANCE_AML_SCREENED",
          "V1_COMPLIANCE_EXCLUSION_ACTIVATED",
          "V1_COMPLIANCE_EXCLUSION_EXPIRED",
          "V1_COMPLIANCE_COOLING_OFF_ACTIVATED",
          "V1_COMPLIANCE_LIMIT_LOSS_EXCEEDED",
          "V1_COMPLIANCE_LIMIT_DEPOSIT_SET",
          "V1_COMPLIANCE_LIMIT_DEPOSIT_EXCEEDED",
          "V1_COMPLIANCE_RG_ALERT_TRIGGERED",
          "V1_COMPLIANCE_RISK_CALCULATED",
          "V1_COMPLIANCE_RISK_DETECTED",
          "V1_COMPLIANCE_FRAUD_DETECTED",
          "V1_COMPLIANCE_MULTI_ACCOUNTING_SUSPECTED",
          "V1_COMPLIANCE_USER_BLOCKED",
          "V1_COMPLIANCE_USER_UNBLOCKED",
          "V1_COMPLIANCE_IP_BLOCKED",
          "V1_COMPLIANCE_JURISDICTION_DENIED",
          "V1_COMPLIANCE_VIOLATION_DETECTED",
          "V1_COMPLIANCE_UNDERAGE_ATTEMPTED",
          "V1_COMPLIANCE_JURISDICTION_UNAUTHORIZED",
          "V1_COMPLIANCE_TRANSACTION_SUSPICIOUS"
        ]
      }
    },
    {
      "name": "event_data",
      "type": {
        "type": "map",
        "values": ["null", "string", "long", "double", "boolean"]
      },
      "doc": "Данные события (user_id, reason, risk_score, jurisdiction, etc.)"
    },
    {
      "name": "timestamp",
      "type": "long"
    },
    {
      "name": "version",
      "type": "int",
      "default": 1
    },
    {
      "name": "metadata",
      "type": ["null", {"type": "map", "values": "string"}],
      "default": null
    }
  ]
}
```

### schemas/SystemEvent.avsc

```json
{
  "type": "record",
  "name": "SystemEvent",
  "namespace": "io.sportify.system",
  "doc": "Некритические системные события (аналитика, debug)",
  "fields": [
    {
      "name": "id",
      "type": "string"
    },
    {
      "name": "tenant_id",
      "type": "string"
    },
    {
      "name": "aggregate_id",
      "type": "string",
      "doc": "ID связанной сущности"
    },
    {
      "name": "event_type",
      "type": "string",
      "doc": "Тип события в формате v1.system.entity.action. STRING, не enum, так как системе и разработчикам нужна предоставить гибкость. Потенциально проблема, следите за тем, чтобы системные события не забивали очереди"
    },
    {
      "name": "event_data",
      "type": {
        "type": "map",
        "values": ["null", "string", "long", "double", "boolean"]
      },
      "doc": "Данные события"
    },
    {
      "name": "timestamp",
      "type": "long"
    },
    {
      "name": "version",
      "type": "int",
      "default": 1
    },
    {
      "name": "metadata",
      "type": ["null", {"type": "map", "values": "string"}],
      "default": null
    }
  ]
}
```

---

## Процесс добавления нового события

### Для критических контекстов (с enum):

1. **Открыть соответствующий `.avsc` файл** (например, `PaymentEvent.avsc`)
2. **Добавить новый symbol В КОНЕЦ списка** symbols в enum
3. **Создать Pull Request** с описанием нового события
4. **Code Review** - команда видит и обсуждает новое событие
5. **Merge PR** - схема автоматически регистрируется в Schema Registry
6. **Все консьюмеры** получают обновленную схему автоматически

**Пример добавления события:**

```json
"symbols": [
  "V1_PAYMENTS_DEPOSIT_CREATED",
  "V1_PAYMENTS_DEPOSIT_PENDING",
  // ... существующие события
  "V1_PAYMENTS_DEPOSIT_EXPIRED"  // ← НОВОЕ событие В КОНЦЕ!
]
```

### Для некритичных контекстов (system):

Новые события можно добавлять без изменения схемы - просто используйте новое значение в `event_type` (string).

---

## Ключевые правила

**ЧТО МОЖНО:**

- Добавлять новые symbols В КОНЕЦ enum
- Добавлять новые поля с default values
- Менять doc strings

**ЧТО НЕЛЬЗЯ:**

- Удалять symbols из enum
- Менять порядок symbols
- Удалять поля без default values
- Менять типы полей (string → long, etc.)

---

**Документ финализирован:** 13 ноября 2025
