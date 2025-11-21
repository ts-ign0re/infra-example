# Service Management Cheatsheet

> Quick reference for adding and managing microservices via Git submodules

---

## ⚠️ Important Rules

### ❌ Prohibited
- Creating services directly in `packages/` without submodules
- Committing service code to this repository
- Manual creation without `service-add-infra.sh`

### ✅ Required
- All services MUST be Git submodules
- Only infrastructure files (Dockerfile, k8s/) are committed here
- Service code lives in separate repositories

---

## 📦 Adding New Service

### Step 1: Add as Git submodule

```bash
git submodule add git@github.com:org/service-name.git packages/service-name
git submodule update --init --recursive
```

### Step 2: Add infrastructure

```bash
# Using make
make add-infra PATH=packages/service-name

# Or direct script
./scripts/service-add-infra.sh packages/service-name
```

### Step 3: Deploy

```bash
make tilt-up
```

---

## 🔧 Working with Git Submodules

### Clone repo with submodules

```bash
git clone --recursive git@github.com:org/ideas.git
# or
git clone git@github.com:org/ideas.git
cd ideas
git submodule update --init --recursive
```

### Update submodule

```bash
cd packages/service-name
git pull origin main
cd ../..
git add packages/service-name
git commit -m "Update service-name"
```

### Remove submodule

```bash
git submodule deinit packages/service-name
git rm packages/service-name
rm -rf .git/modules/packages/service-name
git commit -m "Remove service-name"
```

---

## 🔧 Add Infrastructure Script

### Usage

```bash
# Using make (recommended)
make add-infra PATH=packages/service-name

# Direct script
./scripts/service-add-infra.sh packages/service-name

# External repo (not in packages/)
./scripts/service-add-infra.sh /path/to/external/repo
```

**Auto-detects:**
- Node.js (package.json)
- Go (go.mod)
- Python (requirements.txt, pyproject.toml)
- PHP (composer.json)

**Interactive prompts:**
```
What do you want to add?
1) Dockerfile (if missing)
2) Kubernetes manifests (k8s/)
3) All of the above
4) Cancel

Select option [1-4]: 3
Detected: Node.js project
Application port [default: 3000]: 8080
```

---

## 🚀 Deployment

### Start dev environment

```bash
# Start Tilt (auto-discovers all services)
make tilt-up

# Access Tilt UI
open http://localhost:10350
```

### Wait for services

```bash
make infra-wait
```

### Stop dev environment

```bash
make tilt-down

# Full cleanup
make infra-down
```

---

## 📋 Common Commands

### Infrastructure

```bash
make tilt-up          # Start dev environment with Tilt
make tilt-down        # Stop Tilt
make infra-wait       # Wait for services to be ready
make infra-test       # Run integration tests
make infra-down       # Full cleanup (deletes namespace)
```

### Services

```bash
# Add infrastructure to submodule
make add-infra PATH=packages/service-name

# Direct script
./scripts/service-add-infra.sh packages/service-name
```

### Schemas & Migrations

```bash
make register-schemas    # Register Avro schemas to Schema Registry
make migrate            # Run database migrations
make generate-types     # Generate types from Avro (TS + PHP)
```

---

## 🗂️ Service Structure

```
packages/my-service/
├── Dockerfile                    # Multi-stage build
├── .dockerignore                 # Exclude from Docker build
├── .tiltignore                   # Exclude from hot-reload
├── README.md                     # Service documentation
├── k8s/
│   ├── base/                     # Base K8s manifests
│   │   ├── deployment.yaml       # Deployment spec
│   │   ├── service.yaml          # Service spec
│   │   └── kustomization.yaml    # Kustomize base
│   └── overlays/
│       ├── dev/                  # Dev config (1 replica, debug)
│       │   └── kustomization.yaml
│       └── prod/                 # Prod config (3 replicas, optimized)
│           └── kustomization.yaml
└── [your code]                   # Language-specific structure
    ├── Node.js: package.json, index.js, src/
    ├── Go: go.mod, main.go, cmd/, pkg/
    ├── Python: requirements.txt, main.py, app/
    └── PHP: composer.json, index.php, src/
```

---

## 🐳 Dockerfile Templates

### Node.js
```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
RUN npm run build || true

FROM node:20-alpine
RUN addgroup -g 1001 -S nodejs && adduser -S nodejs -u 1001
WORKDIR /app
COPY --from=builder --chown=nodejs:nodejs /app ./
USER nodejs
EXPOSE 3000
CMD ["node", "index.js"]
```

### Go
```dockerfile
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY go.* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /server

FROM alpine:latest
RUN addgroup -g 1001 -S appuser && adduser -S appuser -u 1001
COPY --from=builder --chown=appuser:appuser /server /server
USER appuser
EXPOSE 8080
CMD ["/server"]
```

### Python
```dockerfile
FROM python:3.11-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --user -r requirements.txt
COPY . .

FROM python:3.11-slim
RUN adduser --uid 1001 --system appuser
WORKDIR /app
COPY --from=builder --chown=appuser /root/.local /home/appuser/.local
COPY --from=builder --chown=appuser /app .
USER appuser
EXPOSE 8000
CMD ["python", "main.py"]
```

---

## ☸️ Kubernetes Quick Reference

### Check services

```bash
# List all pods
kubectl get pods -n dev-infra

# Check specific service
kubectl get pods -n dev-infra -l app=my-service

# View logs
kubectl logs -n dev-infra -l app=my-service --tail=50 -f

# Describe pod
kubectl describe pod -n dev-infra -l app=my-service
```

### Port forwarding

```bash
# Forward service port
kubectl port-forward -n dev-infra svc/my-service 8080:3000

# Forward to specific pod
kubectl port-forward -n dev-infra pod/my-service-xxx 8080:3000
```

### Debugging

```bash
# Execute command in pod
kubectl exec -n dev-infra -it <pod-name> -- sh

# Test database connection
kubectl exec -n dev-infra -it <pod-name> -- \
  wget -qO- http://localhost:3000/health

# Check kustomize output
kubectl kustomize packages/my-service/k8s/overlays/dev
```

---

## 🔍 Troubleshooting

### Service not showing in Tilt

**Check requirements:**
```bash
ls packages/my-service/Dockerfile
ls packages/my-service/k8s/overlays/dev/kustomization.yaml
```

Both must exist for Tilt auto-discovery.

### Pod not starting

```bash
# Check events
kubectl get events -n dev-infra --sort-by='.lastTimestamp' | grep my-service

# Check logs
kubectl logs -n dev-infra -l app=my-service --previous

# Describe deployment
kubectl describe deployment -n dev-infra my-service
```

### Kustomize build fails

```bash
# Validate manually
kubectl kustomize packages/my-service/k8s/overlays/dev

# Check for syntax errors in YAML
yamllint packages/my-service/k8s/
```

### Hot-reload not working

Edit `.tiltignore`:
```
node_modules/
.git/
dist/
coverage/
*.test.js
```

Restart Tilt:
```bash
make tilt-down
make tilt-up
```

---

## 📝 Best Practices

### Service Naming
- Use kebab-case: `user-service`, `payment-api`
- Be descriptive: `auth-gateway` not `ag`
- Avoid abbreviations

### Dockerfile
- ✅ Multi-stage builds
- ✅ Non-root user (UID 1001)
- ✅ Health check endpoint
- ✅ Minimal base image (alpine, distroless)
- ❌ No secrets in Dockerfile
- ❌ No root user

### Kubernetes
- ✅ Resource limits set
- ✅ Liveness + readiness probes
- ✅ Graceful shutdown (SIGTERM)
- ✅ Labels for all resources
- ❌ No hardcoded values (use ConfigMaps/Secrets)

### Development
- ✅ Add .dockerignore
- ✅ Add .tiltignore
- ✅ Document API endpoints
- ✅ Add health checks (/health, /ready)
- ✅ Use structured logging (JSON)

---

## 🔗 Related Documentation

- [Services Guide](../docs/05-SERVICES-GUIDE.md) - Full development guide
- [Production Deployment](../docs/06-PRODUCTION-DEPLOYMENT.md) - CI/CD setup
- [Architecture Specs](specs.md) - Platform architecture

---

## 🆘 Getting Help

### Check logs
```bash
# Tilt logs
# Open: http://localhost:10350

# Kubernetes logs
kubectl logs -n dev-infra -l app=my-service --tail=100

# Integration tests
make infra-test
```

### Common issues
1. **Port conflicts**: Check port-forwards in `infra/Tiltfile`
2. **Image pull errors**: Check Dockerfile syntax
3. **Database connection**: Verify DATABASE_URL in deployment.yaml
4. **Service not ready**: Check health check endpoints

### Resources
- Tilt UI: http://localhost:10350
- Grafana: http://localhost:3000 (admin/admin)
- Schema Registry: http://localhost:8081

---

**Last updated:** 2025-11-18
