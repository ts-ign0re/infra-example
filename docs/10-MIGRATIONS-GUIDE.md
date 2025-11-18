# Database Migrations Guide

## Overview

This project uses **Flyway** for database migrations with **Citus** distributed PostgreSQL.

## Migration File Naming

### Format
```
V{VERSION}__{DESCRIPTION}.sql
```

### Versioning Strategies

#### 1. Simple Incremental (Recommended for small teams)
```
V1__initial_schema.sql
V2__add_users_table.sql
V3__add_email_to_users.sql
V4__fix_users_constraint.sql
```

- Easy to read and understand
- Sequential ordering
- Best for single developer or small team

#### 2. Timestamp-based (Recommended for teams)
```
V20251118195800__add_payments.sql
V20251118200000__add_bets.sql
V20251118201500__add_indexes.sql
```

Format: `VYYYYMMDDHHmmss__description.sql`

**Benefits:**
- Prevents version conflicts when multiple developers work in parallel
- Natural ordering by creation time
- Easy to merge branches

**Generate timestamp:**
```bash
# macOS/Linux
date +"%Y%m%d%H%M%S"

# Example output: 20251118195847
```

## Migration Rules

### ✅ DO

1. **Always create new migrations** - never edit applied ones
2. **Test locally** before committing
3. **Use transactions** when possible
4. **Be idempotent** - use `IF NOT EXISTS`, `IF EXISTS`
5. **Write descriptive names** - `add_user_email_index` not `update1`

### ❌ DON'T

1. **Never modify applied migrations** - Flyway tracks checksums
2. **Don't use database-specific features** without reason
3. **Don't mix schema and data changes** in one file (if possible)
4. **Don't forget about distributed tables** - use `create_distributed_table()`

## Fixing Mistakes

### Scenario 1: Migration not yet applied

**Problem:** You committed `V5__add_column.sql` but it's wrong

**Solution:** Delete and recreate
```bash
git rm infra/db/migrations/V5__add_column.sql
# Create correct version
git add infra/db/migrations/V5__add_column_fixed.sql
git commit -m "fix: correct column type"
```

### Scenario 2: Migration already applied locally

**Problem:** Migration applied to your local DB but not to production

**Solution:** Create a new migration to fix
```sql
-- V6__fix_column_type.sql
ALTER TABLE users ALTER COLUMN age TYPE INTEGER;
```

### Scenario 3: Migration applied in production

**Problem:** Migration is broken and deployed

**Solution 1 - Quick fix (for minor issues):**
```sql
-- V7__hotfix_user_constraint.sql
ALTER TABLE users DROP CONSTRAINT IF EXISTS email_unique;
ALTER TABLE users ADD CONSTRAINT email_unique UNIQUE (tenant_id, email);
```

**Solution 2 - Rollback and recreate (for major issues):**
```sql
-- V7__rollback_payments.sql
DROP TABLE IF EXISTS payments CASCADE;

-- V8__recreate_payments_fixed.sql
CREATE TABLE payments (
    tenant_id BIGINT NOT NULL,
    payment_id BIGSERIAL,
    amount DECIMAL(15,2) NOT NULL,
    PRIMARY KEY (tenant_id, payment_id)
);
SELECT create_distributed_table('payments', 'tenant_id');
```

## Citus-Specific Guidelines

### Distributed Tables

All tenant-scoped tables **must** include `tenant_id` and be distributed:

```sql
CREATE TABLE bets (
    tenant_id BIGINT NOT NULL,
    bet_id BIGSERIAL,
    user_id BIGINT NOT NULL,
    amount DECIMAL(15,2) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (tenant_id, bet_id)
);

-- REQUIRED: Distribute table by tenant_id
SELECT create_distributed_table('bets', 'tenant_id');
```

### Reference Tables

Small lookup tables can be replicated to all nodes:

```sql
CREATE TABLE bet_statuses (
    status_code VARCHAR(20) PRIMARY KEY,
    description TEXT
);

-- Replicate to all nodes
SELECT create_reference_table('bet_statuses');
```

### Indexes on Distributed Tables

Always include `tenant_id` in indexes:

```sql
-- ✅ Good - includes tenant_id
CREATE INDEX idx_bets_user ON bets(tenant_id, user_id);

-- ❌ Bad - missing tenant_id
CREATE INDEX idx_bets_user ON bets(user_id);
```

## Event Sourcing Tables

Event tables follow specific patterns:

### Event Table Structure
```sql
CREATE TABLE bet_events (
    tenant_id BIGINT NOT NULL,
    event_id BIGSERIAL,
    aggregate_id BIGINT NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    event_data JSONB NOT NULL,
    idempotency_key UUID NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (tenant_id, event_id),
    UNIQUE (tenant_id, idempotency_key)
);
SELECT create_distributed_table('bet_events', 'tenant_id');
```

### Materialized View + Trigger

```sql
-- Materialized view for reads
CREATE MATERIALIZED VIEW bets_view AS
SELECT 
    tenant_id,
    aggregate_id as bet_id,
    (event_data->>'user_id')::BIGINT as user_id,
    (event_data->>'amount')::DECIMAL as amount,
    (event_data->>'status') as status,
    created_at
FROM bet_events
WHERE event_type = 'BetPlaced'
WITH NO DATA;

SELECT create_distributed_table('bets_view', 'tenant_id');

-- Trigger for real-time updates
CREATE OR REPLACE FUNCTION refresh_bets_view()
RETURNS TRIGGER AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY bets_view;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_refresh_bets_view
AFTER INSERT ON bet_events
FOR EACH STATEMENT
EXECUTE FUNCTION refresh_bets_view();
```

## Testing Migrations

### Local Testing

```bash
# 1. Apply migrations
make migrate

# 2. Run tests
make infra-test

# 3. Check specific migration
kubectl exec -n dev-infra -it citus-coordinator-0 -- \
  psql -U postgres -d betting_platform -c "\d+ bets"
```

### Clean Slate Testing

```bash
# Destroy and recreate everything
make infra-down
make tilt-up
# Migrations auto-apply via Tilt

# Verify
make infra-test
```

### Manual Testing

```bash
# Connect to database
make db-connect

# Check migration status
SELECT * FROM flyway_schema_history ORDER BY installed_rank;

# Test queries
SET citus.enable_repartition_joins TO on;
SELECT * FROM bets_view WHERE tenant_id = 10001 LIMIT 5;
```

## Migration Workflow

### Step-by-step Process

1. **Create migration file**
   ```bash
   # Option 1: Simple incremental
   touch infra/db/migrations/V4__add_user_preferences.sql
   
   # Option 2: Timestamp
   VERSION=$(date +"%Y%m%d%H%M%S")
   touch infra/db/migrations/V${VERSION}__add_user_preferences.sql
   ```

2. **Write SQL**
   ```sql
   -- V4__add_user_preferences.sql
   CREATE TABLE user_preferences (
       tenant_id BIGINT NOT NULL,
       user_id BIGINT NOT NULL,
       preferences JSONB DEFAULT '{}',
       updated_at TIMESTAMPTZ DEFAULT NOW(),
       PRIMARY KEY (tenant_id, user_id)
   );
   
   SELECT create_distributed_table('user_preferences', 'tenant_id');
   
   CREATE INDEX idx_user_preferences_updated 
   ON user_preferences(tenant_id, updated_at);
   ```

3. **Test locally**
   ```bash
   make migrate
   make infra-test
   ```

4. **Commit**
   ```bash
   git add infra/db/migrations/V4__add_user_preferences.sql
   git commit -m "feat: add user preferences table"
   ```

5. **Deploy** - migrations auto-apply on startup

## Troubleshooting

### Migration Failed

**Error:** `Migration checksum mismatch`

**Cause:** Someone edited an applied migration

**Solution:**
```sql
-- Connect to DB
make db-connect

-- Check history
SELECT * FROM flyway_schema_history WHERE success = false;

-- Option 1: Repair (if you know what you're doing)
DELETE FROM flyway_schema_history WHERE version = '5';

-- Option 2: Create new migration to fix
-- (Recommended)
```

### Migration Stuck

**Error:** `Migration takes too long`

**Cause:** Heavy operation on large table

**Solution:** Break into smaller migrations or use background jobs

```sql
-- Instead of:
ALTER TABLE huge_table ADD COLUMN new_col TEXT;

-- Do:
-- V5__add_column_nullable.sql
ALTER TABLE huge_table ADD COLUMN new_col TEXT;

-- V6__populate_new_column.sql (can be run manually during low traffic)
UPDATE huge_table SET new_col = 'default' WHERE new_col IS NULL;

-- V7__make_column_not_null.sql
ALTER TABLE huge_table ALTER COLUMN new_col SET NOT NULL;
```

### Citus Worker Issues

**Error:** `ERROR: could not connect to worker node`

**Cause:** Migration tries to create distributed table before workers are ready

**Solution:** Wait for workers in migration
```sql
-- Wait for workers
DO $$
DECLARE
    worker_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO worker_count FROM master_get_active_worker_nodes();
    IF worker_count = 0 THEN
        RAISE EXCEPTION 'No Citus workers available';
    END IF;
END $$;

-- Now safe to create distributed table
CREATE TABLE bets (...);
SELECT create_distributed_table('bets', 'tenant_id');
```

## Best Practices Summary

✅ **Use timestamp versions** for team development  
✅ **Test locally first** with `make migrate && make infra-test`  
✅ **Never edit applied migrations** - create new ones  
✅ **Always distribute by tenant_id** for tenant tables  
✅ **Include tenant_id in all indexes** for performance  
✅ **Use idempotent operations** - `IF NOT EXISTS`, `IF EXISTS`  
✅ **Document complex migrations** with comments  
✅ **Keep migrations small** and focused  

❌ **Don't mix schema + data** in one migration  
❌ **Don't use database-specific syntax** unless necessary  
❌ **Don't forget UNIQUE constraints** on idempotency_key  
❌ **Don't create tables without distributing** them  

## Additional Resources

- [Flyway Documentation](https://flywaydb.org/documentation/)
- [Citus Documentation](https://docs.citusdata.com/)
- [Event Sourcing Guide](./08-EVENT-SOURCING.md)
- [Database Queries Guide](./09-DATABASE-QUERIES.md)
