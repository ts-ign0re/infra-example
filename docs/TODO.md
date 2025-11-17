# Project TODO

## Docs and Planning

- [x] Create `docs/TODO` with project tasks
- [x] Move `plan.md` and `specs.md` to `docs/`

## Infrastructure

- [x] Scaffold `infra/` structure: `docker-compose.yml`, `Tiltfile`, `flyway.conf`, `migrations/`, `schemas/`, `scripts/`
- [x] Add `infra/.env.sample` and ignore `infra/.env`
- [x] Add healthchecks for all services

## Avro Schemas

- [x] Create 5 `.avsc` files: Bet, Payment, Balance, Compliance, System
- [x] Fix `event_type` values (no Markdown artifacts)
- [x] Use `TopicNameStrategy` subjects and set `BACKWARD_TRANSITIVE` compatibility

## Scripts

- [x] `wait-for-infra.sh` (Postgres, Redis, Redpanda, Schema Registry)
- [x] `integration-tests.sh` (smoke checks for all services)
- [x] `migrate.sh` (Flyway inside Compose)
- [x] `register-schemas.sh` (register + set compatibility)
- [x] `generate-types-ts.sh` (placeholder)
- [x] `generate-types-php.sh` (placeholder)

## Makefile

- [x] Add `infra-up/down/restart/wait/test/migrate/register-schemas/tilt-up/down`

## Developer Onboarding

- [x] Add `README.md` with prerequisites, `.env` setup, commands

## CI/CD (initial stub)

- [ ] Document pipeline steps (submodules N/A, compose up/wait/migrate/test/down)

## Compliance Tamper-Proof

- [ ] Document approach: event signing + S3 Object Lock (WORM)

## Follow-ups

- [ ] DDL and indexes design (ask user when ready)
- [x] Citus sharding (coordinator/worker) manifests
- [x] Seed default tenant via init job
- [ ] Citus scaling plan and distribution policies

## Integration

- [x] Single command `make integration` (Tilt CI + tests)

## Kubernetes & Tilt Dev

- [x] Add k8s manifests for redpanda, schema-registry, redis, postgres
- [x] Update `infra/Tiltfile` to use k8s with port-forwards
- [x] Add Makefile targets: `k8s-apply/delete/wait/test`
- [x] Update scripts to support k8s mode (USE_K8S=1)
