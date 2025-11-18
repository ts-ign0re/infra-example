-- ============================================
-- V1: Initial schema with tenants and event tables
-- ============================================

-- Enable necessary extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ============================================
-- TENANTS TABLE (alter existing or create new)
-- ============================================

-- Create tenants table if not exists
CREATE TABLE IF NOT EXISTS tenants (
    id BIGINT PRIMARY KEY,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

DO $$ 
BEGIN
    -- Add columns if they don't exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='tenants' AND column_name='name') THEN
        ALTER TABLE tenants ADD COLUMN name VARCHAR(255) NOT NULL DEFAULT 'Unnamed Tenant';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='tenants' AND column_name='slug') THEN
        ALTER TABLE tenants ADD COLUMN slug VARCHAR(100);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='tenants' AND column_name='status') THEN
        ALTER TABLE tenants ADD COLUMN status VARCHAR(50) NOT NULL DEFAULT 'active';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='tenants' AND column_name='plan') THEN
        ALTER TABLE tenants ADD COLUMN plan VARCHAR(50) NOT NULL DEFAULT 'basic';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='tenants' AND column_name='updated_at') THEN
        ALTER TABLE tenants ADD COLUMN updated_at TIMESTAMP NOT NULL DEFAULT NOW();
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='tenants' AND column_name='metadata') THEN
        ALTER TABLE tenants ADD COLUMN metadata JSONB DEFAULT '{}'::jsonb;
    END IF;
END $$;

-- Update slug for existing records
UPDATE tenants SET slug = 'tenant-' || CAST(id AS TEXT) WHERE slug IS NULL;
ALTER TABLE tenants ALTER COLUMN slug SET NOT NULL;

-- Note: UNIQUE constraint on slug not possible in Citus without including partition column
-- Application must ensure uniqueness
CREATE INDEX IF NOT EXISTS idx_tenants_slug ON tenants(slug);

-- Add check constraints
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tenants_status_check') THEN
        ALTER TABLE tenants ADD CONSTRAINT tenants_status_check CHECK (status IN ('active', 'suspended', 'deleted'));
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tenants_plan_check') THEN
        ALTER TABLE tenants ADD CONSTRAINT tenants_plan_check CHECK (plan IN ('basic', 'premium', 'enterprise'));
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_tenants_slug ON tenants(slug);
CREATE INDEX IF NOT EXISTS idx_tenants_status ON tenants(status);

-- ============================================
-- TIER 1: CRITICAL EVENT TABLES
-- ============================================

-- 1. BET EVENTS
CREATE TABLE IF NOT EXISTS bet_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL REFERENCES tenants(id),
    aggregate_id VARCHAR(255) NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB DEFAULT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    
    CONSTRAINT bet_events_tenant_fk FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_bet_events_tenant_id ON bet_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_bet_events_aggregate_id ON bet_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_bet_events_event_type ON bet_events(event_type);
CREATE INDEX IF NOT EXISTS idx_bet_events_timestamp ON bet_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_bet_events_tenant_aggregate ON bet_events(tenant_id, aggregate_id);

-- 2. PAYMENT EVENTS
CREATE TABLE IF NOT EXISTS payment_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL REFERENCES tenants(id),
    aggregate_id VARCHAR(255) NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB DEFAULT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    
    CONSTRAINT payment_events_tenant_fk FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_payment_events_tenant_id ON payment_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_payment_events_aggregate_id ON payment_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_payment_events_event_type ON payment_events(event_type);
CREATE INDEX IF NOT EXISTS idx_payment_events_timestamp ON payment_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_payment_events_tenant_aggregate ON payment_events(tenant_id, aggregate_id);

-- 3. BALANCE EVENTS
CREATE TABLE IF NOT EXISTS balance_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL REFERENCES tenants(id),
    aggregate_id VARCHAR(255) NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB DEFAULT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    
    CONSTRAINT balance_events_tenant_fk FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_balance_events_tenant_id ON balance_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_balance_events_aggregate_id ON balance_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_balance_events_event_type ON balance_events(event_type);
CREATE INDEX IF NOT EXISTS idx_balance_events_timestamp ON balance_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_balance_events_tenant_aggregate ON balance_events(tenant_id, aggregate_id);

-- 4. COMPLIANCE EVENTS
CREATE TABLE IF NOT EXISTS compliance_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL REFERENCES tenants(id),
    aggregate_id VARCHAR(255) NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB DEFAULT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    
    CONSTRAINT compliance_events_tenant_fk FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_compliance_events_tenant_id ON compliance_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_compliance_events_aggregate_id ON compliance_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_compliance_events_event_type ON compliance_events(event_type);
CREATE INDEX IF NOT EXISTS idx_compliance_events_timestamp ON compliance_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_compliance_events_tenant_aggregate ON compliance_events(tenant_id, aggregate_id);

-- ============================================
-- TIER 2: SYSTEM EVENTS (all other events)
-- ============================================
CREATE TABLE IF NOT EXISTS system_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL REFERENCES tenants(id),
    aggregate_id VARCHAR(255) NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB DEFAULT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    
    CONSTRAINT system_events_tenant_fk FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_system_events_tenant_id ON system_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_system_events_aggregate_id ON system_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_system_events_event_type ON system_events(event_type);
CREATE INDEX IF NOT EXISTS idx_system_events_timestamp ON system_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_system_events_tenant_aggregate ON system_events(tenant_id, aggregate_id);

-- ============================================
-- TENANT EVENTS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS tenant_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL REFERENCES tenants(id),
    aggregate_id VARCHAR(255) NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB DEFAULT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    
    CONSTRAINT tenant_events_tenant_fk FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_tenant_events_tenant_id ON tenant_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_tenant_events_aggregate_id ON tenant_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_tenant_events_event_type ON tenant_events(event_type);
CREATE INDEX IF NOT EXISTS idx_tenant_events_timestamp ON tenant_events(timestamp);

-- ============================================
-- FLYWAY METADATA (for tracking migrations)
-- ============================================
CREATE TABLE IF NOT EXISTS flyway_schema_history (
    installed_rank INT NOT NULL PRIMARY KEY,
    version VARCHAR(50),
    description VARCHAR(200) NOT NULL,
    type VARCHAR(20) NOT NULL,
    script VARCHAR(1000) NOT NULL,
    checksum INT,
    installed_by VARCHAR(100) NOT NULL,
    installed_on TIMESTAMP NOT NULL DEFAULT NOW(),
    execution_time INT NOT NULL,
    success BOOLEAN NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_flyway_schema_history_success ON flyway_schema_history(success);
