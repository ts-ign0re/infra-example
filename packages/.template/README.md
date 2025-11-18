# REPLACE_SERVICE_NAME

> Brief description of what this service does

## Getting Started

### Development

1. **Start infrastructure:**
   ```bash
   make tilt-up
   ```

2. **Service will be automatically discovered and deployed to `dev-infra` namespace**

3. **Access the service:**
   ```bash
   # Via port-forward (if configured in Tiltfile)
   kubectl port-forward -n dev-infra svc/REPLACE_SERVICE_NAME 8080:3000
   
   # Then open: http://localhost:8080
   ```

### Local Testing (without Kubernetes)

```bash
# Install dependencies
npm install

# Set environment variables
export DATABASE_URL=postgresql://app:app@localhost:5432/app
export REDIS_URL=redis://localhost:6379
export KAFKA_BROKERS=localhost:19092

# Run
npm run dev
```

## API Endpoints

### Health Checks

- **GET /health** - Liveness probe
  - Returns 200 if service is alive
  - Checks critical dependencies (DB, Redis)

- **GET /ready** - Readiness probe
  - Returns 200 if service is ready to serve traffic

### Business Endpoints

_(Add your API documentation here)_

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PORT` | HTTP server port | `3000` |
| `NODE_ENV` | Environment | `production` |
| `DATABASE_URL` | PostgreSQL connection string | - |
| `REDIS_URL` | Redis connection string | - |
| `KAFKA_BROKERS` | Kafka broker list | - |
| `TENANT_ID_HEADER` | Header for tenant ID | `X-Tenant-Id` |

## Architecture

### Dependencies

- **PostgreSQL (Citus)** - Primary database
- **Redis** - Caching and sessions
- **Kafka (Redpanda)** - Event streaming
- **Loki** - Logging (optional, via stdout)

### Database Schema

_(Describe your tables, migrations, etc.)_

## Testing

```bash
# Unit tests
npm test

# Integration tests
npm run test:integration

# E2E tests
npm run test:e2e
```

## Deployment

### Production

Service is automatically deployed via GitHub Actions when:
- PR is merged to `main`
- Manual trigger via GitHub UI

See [Production Deployment Guide](../../docs/PRODUCTION_DEPLOYMENT.md) for details.

### Rollback

```bash
# Via GitHub Actions (recommended)
# Go to Actions → Rollback Production Deployment

# Manual rollback
kubectl rollout undo deployment/REPLACE_SERVICE_NAME -n production
```

## Monitoring

- **Logs:** Loki at http://localhost:3000 (Grafana)
- **Metrics:** Prometheus at http://localhost:9090
- **Dashboards:** Grafana at http://localhost:3000

## Troubleshooting

### Service not starting

```bash
# Check pod status
kubectl get pods -n dev-infra -l app=REPLACE_SERVICE_NAME

# Check logs
kubectl logs -n dev-infra -l app=REPLACE_SERVICE_NAME --tail=100

# Describe pod
kubectl describe pod -n dev-infra -l app=REPLACE_SERVICE_NAME
```

### Database connection issues

```bash
# Test connection from pod
kubectl exec -n dev-infra -it $(kubectl get pod -n dev-infra -l app=REPLACE_SERVICE_NAME -o jsonpath='{.items[0].metadata.name}') -- \
  wget -qO- http://localhost:3000/health
```

## Contributing

1. Create feature branch
2. Make changes
3. Test locally with `make tilt-up`
4. Create PR
5. Wait for CI/CD checks
6. Merge after approval

## License

Proprietary - All rights reserved
