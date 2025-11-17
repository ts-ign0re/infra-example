# Environment Variables - Quick Start

## Connection Strings (Copy-Paste Ready)

```bash
# PostgreSQL / Citus
DATABASE_URL=postgresql://app:app@localhost:5432/app

# Redis
REDIS_URL=redis://localhost:6379

# Kafka
KAFKA_BROKERS=localhost:19092

# Schema Registry
SCHEMA_REGISTRY_URL=http://localhost:8081

# Loki (Logging)
LOKI_URL=http://localhost:3100
```

## Usage Examples

### Node.js

```javascript
// .env или process.env
require('dotenv').config();

// PostgreSQL
const { Pool } = require('pg');
const pool = new Pool({ 
  connectionString: process.env.DATABASE_URL 
});

// Redis
const Redis = require('ioredis');
const redis = new Redis(process.env.REDIS_URL);

// Kafka
const { Kafka } = require('kafkajs');
const kafka = new Kafka({
  brokers: process.env.KAFKA_BROKERS.split(',')
});

// Schema Registry
const { SchemaRegistry } = require('@kafkajs/confluent-schema-registry');
const registry = new SchemaRegistry({ 
  host: process.env.SCHEMA_REGISTRY_URL 
});
```

### Python

```python
import os
from dotenv import load_dotenv
load_dotenv()

# PostgreSQL
import psycopg2
conn = psycopg2.connect(os.environ['DATABASE_URL'])

# Redis
import redis
r = redis.from_url(os.environ['REDIS_URL'])

# Kafka
from kafka import KafkaProducer
producer = KafkaProducer(
    bootstrap_servers=os.environ['KAFKA_BROKERS'].split(',')
)

# Schema Registry
from confluent_kafka.schema_registry import SchemaRegistryClient
sr = SchemaRegistryClient({'url': os.environ['SCHEMA_REGISTRY_URL']})
```

### Go

```go
package main

import (
    "os"
    "strings"
    "github.com/jackc/pgx/v5"
    "github.com/redis/go-redis/v9"
    "github.com/IBM/sarama"
)

func main() {
    // PostgreSQL
    conn, _ := pgx.Connect(context.Background(), os.Getenv("DATABASE_URL"))
    
    // Redis
    opt, _ := redis.ParseURL(os.Getenv("REDIS_URL"))
    rdb := redis.NewClient(opt)
    
    // Kafka
    brokers := strings.Split(os.Getenv("KAFKA_BROKERS"), ",")
    config := sarama.NewConfig()
    producer, _ := sarama.NewSyncProducer(brokers, config)
}
```

### PHP

```php
<?php
// PostgreSQL
$dsn = getenv('DATABASE_URL');
$pdo = new PDO($dsn);

// Redis
$redis = new Redis();
$url = parse_url(getenv('REDIS_URL'));
$redis->connect($url['host'], $url['port'] ?? 6379);

// Kafka (via rdkafka extension)
$conf = new RdKafka\Conf();
$conf->set('bootstrap.servers', getenv('KAFKA_BROKERS'));
$producer = new RdKafka\Producer($conf);
```

## Testing Connections

```bash
# Load variables
source infra/.env

# Test PostgreSQL
psql "$DATABASE_URL" -c "SELECT version();"

# Test Redis
redis-cli -u "$REDIS_URL" PING

# Test Kafka
rpk cluster info --brokers "$KAFKA_BROKERS"

# Test Schema Registry
curl -s "$SCHEMA_REGISTRY_URL/subjects" | jq .
```

## Docker Compose Override

If using Docker Compose (USE_DOCKER=1), the same variables work but may need internal hostnames:

```bash
# For services running inside Docker Compose
DATABASE_URL=postgresql://app:app@postgres:5432/app
REDIS_URL=redis://redis:6379
KAFKA_BROKERS=redpanda:9092
SCHEMA_REGISTRY_URL=http://schema-registry:8081
```

## Kubernetes Service Discovery

For pods running inside `dev-infra` namespace:

```bash
DATABASE_URL=postgresql://app:app@citus-coordinator.dev-infra.svc.cluster.local:5432/app
REDIS_URL=redis://redis.dev-infra.svc.cluster.local:6379
KAFKA_BROKERS=redpanda.dev-infra.svc.cluster.local:9092
SCHEMA_REGISTRY_URL=http://schema-registry.dev-infra.svc.cluster.local:8081
```

## Environment Setup Checklist

- [ ] Copy `infra/.env.sample` to `infra/.env`
- [ ] Verify all services are running (`make infra-wait`)
- [ ] Test connections with your preferred language
- [ ] Check schemas are registered (`curl $SCHEMA_REGISTRY_URL/subjects`)
- [ ] Verify tenant exists (`psql $DATABASE_URL -c "SELECT * FROM tenants;"`)

## Troubleshooting

**"Connection refused" errors:**
```bash
# Check if services are running
kubectl -n dev-infra get pods

# Check port forwards (via Tilt)
open http://localhost:10350
```

**"Database does not exist":**
```bash
# Re-run init
make infra-down && make tilt-up && make infra-wait
```

**Schema Registry empty:**
```bash
# Register schemas
make register-schemas
```
