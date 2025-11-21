# Архитектурные решения инфраструктуры

> Ключевые технические решения и их обоснование

---

## 1. Materialized Views: CronJob vs Triggers

### ✅ Выбрано: Kubernetes CronJob

**Обоснование:**
- Citus не поддерживает триггеры на distributed tables
- Не нужен custom образ PostgreSQL (pg_cron недоступен в `citusdata/citus:13.0`)
- Предсказуемая нагрузка: обновления по расписанию

**Альтернативы рассмотрены:**
- ❌ **PostgreSQL Triggers**: не поддерживаются Citus на распределённых таблицах
- ❌ **pg_cron**: требует custom образ + сложность поддержки
- ❌ **External scheduler**: лишняя зависимость

**Компромиссы:**
- ➕ Простая эксплуатация, прозрачно в Kubernetes
- ➕ Нет задержки на каждый INSERT (быстрее запись)
- ➖ Данные в views обновляются с задержкой (по расписанию)

**Когда пересмотреть:**
- Если требуется sub-minute латентность обновлений
- Если объём данных требует дифференцированных стратегий (части обновлять чаще)
- Если появится доступный и поддерживаемый pg_cron образ

---

## 2. Event Sourcing: PostgreSQL vs специализированное хранилище

### ✅ Выбрано: PostgreSQL + Citus

**Обоснование:**
- Уже есть в инфраструктуре
- ACID гарантии
- Знакомый SQL для разработчиков
- Citus обеспечивает горизонтальное масштабирование
- Материализованные views из коробки

**Альтернативы рассмотрены:**
- ❌ **EventStoreDB**: дополнительный сервис, overhead
- ❌ **Apache Kafka (только)**: сложность построения проекций
- ❌ **DynamoDB**: vendor lock-in, сложность запросов

**Компромиссы:**
- ➕ Простота архитектуры
- ➕ Единая БД для events и projections
- ➖ Не специализированное решение для ES
- ➖ Нет встроенного event versioning

---

## 3. Schema Registry: Встроенный vs Confluent

### ✅ Выбрано: Confluent Schema Registry (OSS)

**Обоснование:**
- De-facto стандарт для Avro
- REST API для управления
- Schema evolution из коробки
- Совместимость с Kafka ecosystem

**Альтернативы рассмотрены:**
- ❌ **Redpanda Schema Registry**: молодой продукт, меньше функций
- ❌ **Custom решение**: изобретение велосипеда

**Компромиссы:**
- ➕ Зрелое решение
- ➕ Большое комьюнити
- ➖ Java-based (потребляет больше памяти)

---

## 4. Multi-tenancy: Shared DB vs Database-per-tenant

### ✅ Выбрано: Shared DB с tenant_id фильтрацией

**Обоснование:**
- Простота управления (одна БД)
- Citus распределяет данные по tenant_id автоматически
- Легко масштабировать
- Меньше overhead на мелких тенантов

**Альтернативы рассмотрены:**
- ❌ **Database-per-tenant**: сложность миграций, больше ресурсов
- ❌ **Schema-per-tenant**: средний путь, но всё равно сложнее

**Компромиссы:**
- ➕ Простота операций
- ➕ Эффективное использование ресурсов
- ➖ Требует строгой дисциплины в коде (всегда фильтровать по tenant_id)
- ➖ Риск утечки данных между тенантами при ошибке в коде

**Security measures:**
- Обязательный middleware для проверки X-Tenant-Id
- Prepared statements для защиты от SQL injection
- Row-level security (можно добавить позже)

---

## 5. Kafka vs Redpanda

### ✅ Выбрано: Redpanda

**Обоснование:**
- Kafka-compatible API
- Меньше ресурсов (без JVM)
- Проще в эксплуатации (один бинарник)
- Быстрее startup time

**Альтернативы рассмотрены:**
- ❌ **Apache Kafka**: больше ресурсов, сложнее setup
- ❌ **RabbitMQ**: не для event streaming, меньше throughput

**Компромиссы:**
- ➕ Легковесность
- ➕ Drop-in replacement для Kafka
- ➖ Меньше опыта в production у комьюнити
- ➖ Меньше ready-made connectors

---

## 6. Observability: Loki + Grafana vs ELK

### ✅ Выбрано: Loki + Grafana

**Обоснование:**
- Легковесность (по сравнению с Elasticsearch)
- Интеграция с Grafana из коробки
- LogQL похож на PromQL (единая экосистема)
- Меньше индексов = меньше ресурсов

**Альтернативы рассмотрены:**
- ❌ **ELK Stack**: тяжёлый, оverkill для dev окружения
- ❌ **CloudWatch/DataDog**: vendor lock-in, costs

**Компромиссы:**
- ➕ Быстрый поиск по labels
- ➕ Минимальные ресурсы
- ➖ Медленный full-text search (по дизайну)
- ➖ Меньше ready-made dashboards

---

## 7. Development: Tilt vs Docker Compose

### ✅ Выбрано: Tilt + Kubernetes

**Обоснование:**
- Production-like окружение локально
- Live reload для всех сервисов
- Визуальный UI для мониторинга
- Легко масштабируется от dev к staging/prod

**Альтернативы рассмотрены:**
- ❌ **Docker Compose**: проще, но не production-like
- ❌ **Skaffold**: похож на Tilt, но менее удобный UI

**Компромиссы:**
- ➕ Dev = Staging = Prod (consistency)
- ➕ Отличный DX (developer experience)
- ➖ Требует Kubernetes локально
- ➖ Немного сложнее initial setup

---

## Когда пересматривать решения

### Materialized Views → Отдельное хранилище для read-models
**Триггер:** 
- INSERT операции стабильно >500ms
- Нагрузка >1000 events/sec
- Views занимают >50% размера БД

**Решение:**
- Вынести views в отдельный PostgreSQL read-replica
- Или использовать Redis/Elasticsearch для горячих данных

### PostgreSQL ES → EventStoreDB
**Триггер:**
- Требуется сложный event versioning
- Нужны projections с complex queries
- Требуется event replay для debugging

**Решение:**
- Миграция на EventStoreDB
- PostgreSQL остаётся только для projections

### Shared DB → Database-per-tenant
**Триггер:**
- Один тенант потребляет >50% ресурсов БД
- Требуется физическая изоляция данных (compliance)
- Нужны разные retention policies per tenant

**Решение:**
- Большие тенанты → отдельные БД
- Мелкие тенанты → остаются в shared

---

## Метрики для мониторинга

### Materialized Views
- Время refresh: `avg_refresh_time_ms` (норма <200ms)
- Частота refresh: `refresh_count` (должна расти)
- Staleness: `seconds_ago` (норма <10 sec)

### Event Sourcing
- INSERT latency (норма <100ms без триггеров, <300ms с триггерами)
- Events/second throughput
- Event table size growth

### Multi-tenancy
- Tenant data distribution (должна быть равномерной)
- Queries without tenant_id (должно быть 0!)
- Cross-tenant queries (alert!)

---

**Версия:** 1.0  
**Дата:** 2025-11-18  
**Статус:** Production-ready для беттинг платформы
