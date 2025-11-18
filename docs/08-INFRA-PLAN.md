# План действий для настройки инфраструктуры разработки

## 1. Подготовка репозитория

1. Создать основной репозиторий (далее — main-repo) и разместить в корне следующие элементы:
   - каталог `infra/` — инфраструктура.
   - каталог `project-php/` — git submodule с PHP-проектом.
   - каталог `project-nodejs/` — git submodule с Node.js-проектом.
   - файл `Makefile` — единая точка вызова инфраструктурных задач.
   - файл `plan.md` — текущий план.
2. Подключить сабмодули:
   - `git submodule add <ssh-url-php> project-php`
   - `git submodule add <ssh-url-node> project-nodejs`
3. Настроить README для команды с описанием структуры и ссылкой на этот план.
4. Обновить `.gitmodules` и зафиксировать изменения в репозитории.

## 2. Настройка инфраструктурной конфигурации (`infra/`)

1. Создать `infra/docker-compose.yml`, включив сервисы:
   - `redpanda` — брокер Kafka.
   - `schema-registry` — Confluent Schema Registry.
   - `redis` — кеш.
   - `postgres` — БД.
   - `flyway` — контейнер для миграций.
   - `cytus` — сервис с дефолтным шардом.
   - `cytus-init` — post-start инициализация дефолтного тенанта/шарда.
2. Для каждого сервиса прописать `healthcheck` и использовать переменные окружения.
3. Создать `infra/Tiltfile` с вызовом `docker_compose('./docker-compose.yml')`.
4. Создать `infra/flyway.conf` с параметрами миграций (ссылками на переменные окружения).
5. Подготовить структуру каталогов:
   - `infra/migrations/` — SQL-миграции.
   - `infra/schemas/` — Avro-схемы.
   - `infra/scripts/` — bash-скрипты.

## 3. Переменные окружения

1. Создать `infra/.env.sample` с полным списком переменных:
   - параметры PostgreSQL, Redis, Redpanda, Schema Registry, Cytus, Flyway.
   - опциональные локальные URL.
2. Добавить `infra/.env.sample` в репозиторий.
3. Создать `infra/.env` (вручную или автоматически) и добавить в `.gitignore`.
4. Обновить `docker-compose.yml`, `flyway.conf` и все скрипты для использования значений из `.env`.

## 4. Bash-скрипты (`infra/scripts/`)

Для каждого скрипта сделать `chmod +x` и обеспечить чтение `.env`.

1. `wait-for-infra.sh` — ожидание готовности всех сервисов (Postgres, Redis, Redpanda, Schema Registry, Cytus).
2. `integration-tests.sh` — smoke-тесты:
   - проверка операций в Postgres и Redis.
   - проверка топиков Redpanda (`rpk`), доступности Schema Registry и Cytus.
3. `migrate.sh` — запуск Flyway миграций внутри Docker Compose.
4. `register-schemas.sh` — регистрация всех Avro-схем в Schema Registry.
5. `generate-types-ts.sh` — генерация TypeScript типов (через `avro-to-typescript`) в каталог Node.js-сабмодуля.
6. `generate-types-php.sh` — генерация PHP-классов (через `quicktype`) в каталог PHP-сабмодуля.
7. `generate-types.sh` — интерактивный выбор доступного сабмодуля и запуск соответствующего скрипта.

## 5. Типизация событий Redpanda

1. Определить Avro-схемы в `infra/schemas/*.avsc` для всех доменных событий.
2. Организовать регистрацию схем через `make register-schemas` (см. раздел Makefile).
3. Настроить обработку схем в Cytus и всех потребителях/продюсерах:
   - использовать URL Schema Registry из `.env`;
   - гарантировать сериализацию и десериализацию через Avro.
4. Гайдлайны по именованию событий (Единый формат):
   - Канонический идентификатор события: `event_type` в UPPER_SNAKE_CASE без точек, вида `V{N}_{CONTEXT}_{ENTITY}_{ACTION}`.
   - Примеры: `V1_PAYMENTS_DEPOSIT_COMPLETED`, `V1_BETS_BET_PLACED`, `V1_SYSTEM_EMAIL_SENT`.
   - Компоненты:
     - `V{N}` — версия (V1, V2 ...), увеличивается при ломающих изменениях.
     - `{CONTEXT}` — bounded context (PAYMENTS, BETS, BALANCES, COMPLIANCE, SYSTEM).
     - `{ENTITY}` — сущность (DEPOSIT, WITHDRAWAL, BET, BALANCE, KYC и т.п.).
     - `{ACTION}` — действие в прошедшем времени (CREATED, COMPLETED, REJECTED и т.п.).
   - (Опционально) `event_name` как человеко‑читаемое имя в dot‑нотации может храниться для обратной совместимости, но `event_type` — канонический идентификатор в коде и схемах.
5. Обновлять Avro‑схемы с соблюдением обратной совместимости:
   - в Schema Registry включить совместимость не ниже BACKWARD;
   - добавлять новые поля только с `default`-значениями либо как опциональные;
   - запрещено удалять/переименовывать существующие поля в рамках текущей версии события;
   - при необходимости ломающих изменений — создавать новую версию события (см. пункт 4) и фиксировать update в changelog схем;
   - документировать все изменения в отдельном разделе README или `SCHEMA_CHANGELOG.md`.
   - Avro enum‑символы соответствуют `[A-Za-z_][A-Za-z0-9_]*` — используем UPPER_SNAKE_CASE.
   - Для TIER1 `event_type` реализуется как enum; для `system_events` допускается строка, но значение всегда в UPPER_SNAKE_CASE.

## 6. Makefile в корне репозитория

Реализовать команды:

- `make infra-up` — запуск инфраструктуры.
- `make infra-down` — остановка и очистка.
- `make infra-restart` — перезапуск.
- `make infra-wait` — вызов `wait-for-infra.sh`.
- `make infra-test` — smoke-тесты.
- `make migrate` — Flyway миграции.
- `make register-schemas` — регистрация Avro-схем.
- `make generate-types` — интерактивная генерация типов.
- `make generate-types-ts` и `make generate-types-php` — прямые вызовы.
- `make tilt-up` / `make tilt-down` — управление Tilt.

## 7. Интеграция с робочим процессом разработчиков

1. Документировать шаги в README:
   - клонирование основного репозитория с сабмодулями: `git clone --recurse-submodules`.
   - копирование `.env.sample` → `.env` и настройка переменных.
   - запуск `make infra-up`, ожидание `make infra-wait`, проверка `make infra-test`.
   - генерация типов через `make generate-types`.
2. Для каждой команды (PHP/Node.js) описать специфические инструкции по сборке и запуску приложений в локальной среде.
3. Обеспечить, чтобы разработчики коммитили обновлённые типы в соответствующие сабмодули.

## 8. CI/CD и тестирование инфраструктуры

1. Настроить пайплайн (GitHub Actions, GitLab CI и т.д.) с шагами:
   - `git submodule update --init --recursive`.
   - `make infra-up`.
   - `make infra-wait`.
   - `make migrate`.
   - `make register-schemas`.
   - `make infra-test`.
   - (опционально) `make generate-types` и проверка на отсутствие diff.
   - `make infra-down`.
2. Обновить README с описанием pipeline и используемых команд.
3. Добавить проверку актуальности Avro-схем и типов (Diff или lint).

## 9. Поддержка и развитие

1. Назначить ответственного за обновление инфраструктурных образов (Postgres, Redis, Redpanda, Schema Registry, Cytus, Flyway).
2. Ввести правила версионирования Avro-схем (semver, обратная совместимость).
3. Обновлять документацию при каждом изменении инфраструктуры.
4. Регулярно проверять выполнение smoke-тестов и миграций на свежей копии репозитория.
