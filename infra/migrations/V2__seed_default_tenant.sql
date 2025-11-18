-- ============================================
-- V2: Seed default tenant (10001)
-- ============================================

-- Insert default tenant only if not exists
INSERT INTO tenants (id, name, slug, status, plan, metadata)
VALUES (
    10001,
    'Default Tenant',
    'default',
    'active',
    'enterprise',
    '{"description": "Default tenant for development and testing", "created_by": "system"}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

-- Log tenant creation event
INSERT INTO tenant_events (id, tenant_id, aggregate_id, event_type, event_data, timestamp, version)
SELECT 
    uuid_generate_v4(),
    10001,
    'tenant-10001',
    'V1_TENANT_CREATED',
    jsonb_build_object(
        'tenant_id', 10001,
        'name', 'Default Tenant',
        'slug', 'default',
        'plan', 'enterprise',
        'status', 'active'
    ),
    EXTRACT(EPOCH FROM NOW())::BIGINT * 1000,
    1
WHERE NOT EXISTS (
    SELECT 1 FROM tenant_events 
    WHERE tenant_id = 10001 
    AND event_type = 'V1_TENANT_CREATED'
);
