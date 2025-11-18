-- ============================================
-- V1: Initial Event Sourcing Schema
-- Creates tenants, event tables, and idempotency protection
-- ============================================

-- Enable necessary extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ============================================
-- TENANTS TABLE
-- ============================================

CREATE TABLE IF NOT EXISTS tenants (
    id BIGINT PRIMARY KEY,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    name VARCHAR(255) NOT NULL DEFAULT 'Unnamed Tenant',
    slug VARCHAR(100) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'active',
    plan VARCHAR(50) NOT NULL DEFAULT 'basic',
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
    metadata JSONB DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_tenants_slug ON tenants(slug);
CREATE INDEX IF NOT EXISTS idx_tenants_status ON tenants(status);

-- Distribute tenants table by tenant_id
SELECT create_distributed_table('tenants', 'id');

-- Seed default tenant
INSERT INTO tenants (id, name, slug, status, plan)
VALUES (10001, 'Default Tenant', 'default', 'active', 'basic')
ON CONFLICT (id) DO NOTHING;

-- ============================================
-- EVENT TABLES (Event Sourcing)
-- All events are append-only, immutable logs
-- ============================================

-- BET EVENTS - все события ставок
CREATE TABLE IF NOT EXISTS bet_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL,
    aggregate_id VARCHAR(255) NOT NULL,  -- bet_id
    event_type VARCHAR(100) NOT NULL,    -- V1_BET_PLACED, V1_BET_SETTLED, etc.
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL,           -- Unix timestamp ms
    version INT NOT NULL DEFAULT 1,      -- schema version
    metadata JSONB,                      -- contains idempotency_key, user_agent, etc.
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_bet_events_tenant_id ON bet_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_bet_events_aggregate_id ON bet_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_bet_events_tenant_aggregate ON bet_events(tenant_id, aggregate_id);
CREATE INDEX IF NOT EXISTS idx_bet_events_event_type ON bet_events(event_type);
CREATE INDEX IF NOT EXISTS idx_bet_events_timestamp ON bet_events(timestamp);

SELECT create_distributed_table('bet_events', 'tenant_id');

-- PAYMENT EVENTS - все события платежей
CREATE TABLE IF NOT EXISTS payment_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL,
    aggregate_id VARCHAR(255) NOT NULL,  -- payment_id
    event_type VARCHAR(100) NOT NULL,    -- V1_PAYMENTS_DEPOSIT_CREATED, etc.
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_payment_events_tenant_id ON payment_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_payment_events_aggregate_id ON payment_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_payment_events_tenant_aggregate ON payment_events(tenant_id, aggregate_id);
CREATE INDEX IF NOT EXISTS idx_payment_events_event_type ON payment_events(event_type);
CREATE INDEX IF NOT EXISTS idx_payment_events_timestamp ON payment_events(timestamp);

SELECT create_distributed_table('payment_events', 'tenant_id');

-- BALANCE EVENTS - все события балансов
CREATE TABLE IF NOT EXISTS balance_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL,
    aggregate_id VARCHAR(255) NOT NULL,  -- user_id or balance_id
    event_type VARCHAR(100) NOT NULL,    -- V1_BALANCE_ADJUSTED, etc.
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_balance_events_tenant_id ON balance_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_balance_events_aggregate_id ON balance_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_balance_events_tenant_aggregate ON balance_events(tenant_id, aggregate_id);
CREATE INDEX IF NOT EXISTS idx_balance_events_event_type ON balance_events(event_type);
CREATE INDEX IF NOT EXISTS idx_balance_events_timestamp ON balance_events(timestamp);

SELECT create_distributed_table('balance_events', 'tenant_id');

-- COMPLIANCE EVENTS - все события комплаенса
CREATE TABLE IF NOT EXISTS compliance_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL,
    aggregate_id VARCHAR(255) NOT NULL,  -- user_id or check_id
    event_type VARCHAR(100) NOT NULL,    -- V1_KYC_VERIFIED, V1_LIMIT_EXCEEDED, etc.
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_compliance_events_tenant_id ON compliance_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_compliance_events_aggregate_id ON compliance_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_compliance_events_tenant_aggregate ON compliance_events(tenant_id, aggregate_id);
CREATE INDEX IF NOT EXISTS idx_compliance_events_event_type ON compliance_events(event_type);
CREATE INDEX IF NOT EXISTS idx_compliance_events_timestamp ON compliance_events(timestamp);

SELECT create_distributed_table('compliance_events', 'tenant_id');

-- TENANT EVENTS - события управления тенантами
CREATE TABLE IF NOT EXISTS tenant_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL,
    aggregate_id VARCHAR(255) NOT NULL,  -- tenant_id as string
    event_type VARCHAR(100) NOT NULL,    -- V1_TENANT_CREATED, V1_TENANT_PLAN_CHANGED, etc.
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_tenant_events_tenant_id ON tenant_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_tenant_events_aggregate_id ON tenant_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_tenant_events_event_type ON tenant_events(event_type);
CREATE INDEX IF NOT EXISTS idx_tenant_events_timestamp ON tenant_events(timestamp);

SELECT create_distributed_table('tenant_events', 'tenant_id');

-- SYSTEM EVENTS - аналитика и системные события (некритичные)
CREATE TABLE IF NOT EXISTS system_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL,
    aggregate_id VARCHAR(255),
    event_type VARCHAR(100) NOT NULL,
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_system_events_tenant_id ON system_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_system_events_event_type ON system_events(event_type);
CREATE INDEX IF NOT EXISTS idx_system_events_timestamp ON system_events(timestamp);

SELECT create_distributed_table('system_events', 'tenant_id');

-- ============================================
-- IDEMPOTENCY PROTECTION
-- Unique constraints to prevent duplicate critical operations
-- ============================================

CREATE UNIQUE INDEX IF NOT EXISTS idx_payment_events_idempotency_unique 
ON payment_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_bet_events_idempotency_unique 
ON bet_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_balance_events_idempotency_unique 
ON balance_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_compliance_events_idempotency_unique 
ON compliance_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_events_idempotency_unique 
ON tenant_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;
