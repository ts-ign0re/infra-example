# Production Deployment Guide

> **Для DevOps:** План имплементации CI/CD pipeline для деплоя микросервисов в production

---

## Обзор архитектуры

### Dev Environment
- **Инструмент:** Tilt (автоматическое обнаружение сервисов)
- **Сборка:** Локально из Dockerfile
- **Деплой:** `kubectl apply -k k8s/overlays/dev`
- **Hot-reload:** Да (live_update в Tilt)
- **Namespace:** `dev-infra`

### Production Environment
- **Инструмент:** GitHub Actions + Kustomize
- **Сборка:** CI собирает Docker образ
- **Registry:** Private Docker Registry (Harbor/GCR/ECR)
- **Деплой:** `kubectl apply -k k8s/overlays/prod`
- **Rollback:** `kubectl rollout undo`
- **Namespace:** `production` (или по вашему соглашению)

---

## Компоненты для имплементации

### 1. Private Docker Registry

**Варианты:**

#### Option A: Harbor (Self-hosted, рекомендуется)
```yaml
# Преимущества:
# - Open-source, бесплатный
# - Vulnerability scanning встроен
# - RBAC, репликация
# - UI для управления

# Установка через Helm:
helm repo add harbor https://helm.goharbor.io
helm install harbor harbor/harbor \
  --set expose.type=loadBalancer \
  --set externalURL=https://registry.example.com \
  --set harborAdminPassword=<strong-password>
```

#### Option B: Google Container Registry (GCR)
```bash
# Преимущества:
# - Managed service
# - Интеграция с GKE
# - Автоматический scanning

# Настройка:
gcloud auth configure-docker
docker tag my-service:v1.0.0 gcr.io/<project-id>/my-service:v1.0.0
docker push gcr.io/<project-id>/my-service:v1.0.0
```

#### Option C: Amazon ECR
```bash
# Преимущества:
# - Managed service
# - Интеграция с EKS
# - Автоматический scanning

# Настройка:
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com
docker tag my-service:v1.0.0 <account-id>.dkr.ecr.us-east-1.amazonaws.com/my-service:v1.0.0
docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/my-service:v1.0.0
```

**Рекомендация:** Harbor для self-hosted, GCR/ECR для cloud-native.

---

### 2. GitHub Actions Workflows

#### Структура workflows:

```
.github/
  workflows/
    build-service.yaml       # Build и push образа
    deploy-prod.yaml         # Deploy в production
    rollback.yaml            # Откат деплоя (manual trigger)
    integration-tests.yaml   # Pre-deploy validation
```

#### `build-service.yaml`

```yaml
name: Build and Push Service

on:
  push:
    branches: [main, develop]
    paths:
      - 'packages/**'
  pull_request:
    paths:
      - 'packages/**'

env:
  REGISTRY: registry.example.com  # Замените на ваш registry
  REGISTRY_USERNAME: ${{ secrets.REGISTRY_USERNAME }}
  REGISTRY_PASSWORD: ${{ secrets.REGISTRY_PASSWORD }}

jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      services: ${{ steps.filter.outputs.changes }}
    steps:
      - uses: actions/checkout@v4
      
      - uses: dorny/paths-filter@v2
        id: filter
        with:
          filters: |
            service-a:
              - 'packages/service-a/**'
            service-b:
              - 'packages/service-b/**'
            tenants-dashboard:
              - 'packages/tenants-dashboard/**'

  build:
    needs: detect-changes
    if: ${{ needs.detect-changes.outputs.services != '[]' }}
    runs-on: ubuntu-latest
    strategy:
      matrix:
        service: ${{ fromJSON(needs.detect-changes.outputs.services) }}
    
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
      
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      
      - name: Log in to Docker Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ env.REGISTRY_USERNAME }}
          password: ${{ env.REGISTRY_PASSWORD }}
      
      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ matrix.service }}
          tags: |
            type=ref,event=branch
            type=ref,event=pr
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=sha,prefix={{branch}}-
      
      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: ./packages/${{ matrix.service }}
          file: ./packages/${{ matrix.service }}/Dockerfile
          push: ${{ github.event_name != 'pull_request' }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
      
      - name: Run Trivy vulnerability scanner
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ env.REGISTRY }}/${{ matrix.service }}:${{ github.sha }}
          format: 'sarif'
          output: 'trivy-results.sarif'
      
      - name: Upload Trivy results to GitHub Security
        uses: github/codeql-action/upload-sarif@v2
        with:
          sarif_file: 'trivy-results.sarif'
```

#### `deploy-prod.yaml`

```yaml
name: Deploy to Production

on:
  workflow_dispatch:
    inputs:
      service:
        description: 'Service to deploy'
        required: true
        type: choice
        options:
          - service-a
          - service-b
          - tenants-dashboard
      version:
        description: 'Image tag (e.g., v1.0.0 or commit SHA)'
        required: true
        type: string
      dry-run:
        description: 'Dry run (preview changes)'
        required: false
        type: boolean
        default: false

env:
  REGISTRY: registry.example.com
  PROD_NAMESPACE: production
  KUBECONFIG_SECRET: ${{ secrets.KUBECONFIG_PROD }}

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
      
      - name: Validate image exists
        run: |
          echo "Checking if image exists: ${{ env.REGISTRY }}/${{ inputs.service }}:${{ inputs.version }}"
          docker manifest inspect ${{ env.REGISTRY }}/${{ inputs.service }}:${{ inputs.version }}
        env:
          DOCKER_CLI_EXPERIMENTAL: enabled
      
      - name: Validate Kustomize manifests
        run: |
          kubectl kustomize packages/${{ inputs.service }}/k8s/overlays/prod > /dev/null

  deploy:
    needs: validate
    runs-on: ubuntu-latest
    environment:
      name: production
      url: https://${{ inputs.service }}.example.com
    
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
      
      - name: Setup kubectl
        uses: azure/setup-kubectl@v3
      
      - name: Configure kubeconfig
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.KUBECONFIG_PROD }}" | base64 -d > ~/.kube/config
      
      - name: Update image tag in kustomization
        run: |
          cd packages/${{ inputs.service }}/k8s/overlays/prod
          
          # Создать или обновить image-tag.yaml
          cat > image-tag.yaml <<EOF
          apiVersion: kustomize.config.k8s.io/v1beta1
          kind: Kustomization
          
          images:
            - name: ${{ inputs.service }}
              newName: ${{ env.REGISTRY }}/${{ inputs.service }}
              newTag: ${{ inputs.version }}
          EOF
          
          # Добавить в kustomization.yaml если еще нет
          if ! grep -q "image-tag.yaml" kustomization.yaml; then
            yq eval '.resources += ["image-tag.yaml"]' -i kustomization.yaml
          fi
      
      - name: Preview changes (dry-run)
        if: ${{ inputs.dry-run }}
        run: |
          kubectl diff -k packages/${{ inputs.service }}/k8s/overlays/prod || true
      
      - name: Deploy to production
        if: ${{ !inputs.dry-run }}
        run: |
          kubectl apply -k packages/${{ inputs.service }}/k8s/overlays/prod
      
      - name: Wait for rollout
        if: ${{ !inputs.dry-run }}
        run: |
          kubectl rollout status deployment/${{ inputs.service }} \
            -n ${{ env.PROD_NAMESPACE }} \
            --timeout=5m
      
      - name: Verify deployment
        if: ${{ !inputs.dry-run }}
        run: |
          kubectl get pods -n ${{ env.PROD_NAMESPACE }} -l app=${{ inputs.service }}
          
          # Health check
          POD=$(kubectl get pod -n ${{ env.PROD_NAMESPACE }} -l app=${{ inputs.service }} -o jsonpath='{.items[0].metadata.name}')
          kubectl exec -n ${{ env.PROD_NAMESPACE }} $POD -- wget -qO- http://localhost:3000/health
      
      - name: Create GitHub deployment
        if: ${{ !inputs.dry-run }}
        uses: actions/github-script@v7
        with:
          script: |
            await github.rest.repos.createDeployment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              ref: context.sha,
              environment: 'production',
              description: 'Deployed ${{ inputs.service }}:${{ inputs.version }}',
              auto_merge: false
            });
      
      - name: Notify Slack on success
        if: success() && !inputs.dry-run
        uses: slackapi/slack-github-action@v1
        with:
          webhook-url: ${{ secrets.SLACK_WEBHOOK_URL }}
          payload: |
            {
              "text": "✅ Production Deployment Successful",
              "blocks": [
                {
                  "type": "section",
                  "text": {
                    "type": "mrkdwn",
                    "text": "*Service:* ${{ inputs.service }}\n*Version:* ${{ inputs.version }}\n*Deployed by:* ${{ github.actor }}"
                  }
                }
              ]
            }
      
      - name: Notify Slack on failure
        if: failure()
        uses: slackapi/slack-github-action@v1
        with:
          webhook-url: ${{ secrets.SLACK_WEBHOOK_URL }}
          payload: |
            {
              "text": "❌ Production Deployment Failed",
              "blocks": [
                {
                  "type": "section",
                  "text": {
                    "type": "mrkdwn",
                    "text": "*Service:* ${{ inputs.service }}\n*Version:* ${{ inputs.version }}\n*Failed at:* Deployment\n*Run:* ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
                  }
                }
              ]
            }
```

#### `rollback.yaml`

```yaml
name: Rollback Production Deployment

on:
  workflow_dispatch:
    inputs:
      service:
        description: 'Service to rollback'
        required: true
        type: choice
        options:
          - service-a
          - service-b
          - tenants-dashboard
      revision:
        description: 'Revision to rollback to (leave empty for previous)'
        required: false
        type: string

env:
  PROD_NAMESPACE: production

jobs:
  rollback:
    runs-on: ubuntu-latest
    environment:
      name: production
    
    steps:
      - name: Setup kubectl
        uses: azure/setup-kubectl@v3
      
      - name: Configure kubeconfig
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.KUBECONFIG_PROD }}" | base64 -d > ~/.kube/config
      
      - name: Get rollout history
        run: |
          echo "Current rollout history:"
          kubectl rollout history deployment/${{ inputs.service }} -n ${{ env.PROD_NAMESPACE }}
      
      - name: Rollback deployment
        run: |
          if [ -z "${{ inputs.revision }}" ]; then
            echo "Rolling back to previous revision..."
            kubectl rollout undo deployment/${{ inputs.service }} -n ${{ env.PROD_NAMESPACE }}
          else
            echo "Rolling back to revision ${{ inputs.revision }}..."
            kubectl rollout undo deployment/${{ inputs.service }} \
              -n ${{ env.PROD_NAMESPACE }} \
              --to-revision=${{ inputs.revision }}
          fi
      
      - name: Wait for rollback
        run: |
          kubectl rollout status deployment/${{ inputs.service }} \
            -n ${{ env.PROD_NAMESPACE }} \
            --timeout=5m
      
      - name: Verify rollback
        run: |
          kubectl get pods -n ${{ env.PROD_NAMESPACE }} -l app=${{ inputs.service }}
          
          POD=$(kubectl get pod -n ${{ env.PROD_NAMESPACE }} -l app=${{ inputs.service }} -o jsonpath='{.items[0].metadata.name}')
          kubectl exec -n ${{ env.PROD_NAMESPACE }} $POD -- wget -qO- http://localhost:3000/health
      
      - name: Notify Slack
        uses: slackapi/slack-github-action@v1
        with:
          webhook-url: ${{ secrets.SLACK_WEBHOOK_URL }}
          payload: |
            {
              "text": "⏪ Production Rollback Completed",
              "blocks": [
                {
                  "type": "section",
                  "text": {
                    "type": "mrkdwn",
                    "text": "*Service:* ${{ inputs.service }}\n*Rolled back by:* ${{ github.actor }}\n*Status:* ${{ job.status }}"
                  }
                }
              ]
            }
```

---

### 3. Kubernetes Secrets Management

**Опции:**

#### Option A: Kubernetes Secrets (базовый)
```bash
# Создать secret
kubectl create secret generic my-service-secrets \
  --from-literal=DATABASE_PASSWORD=supersecret \
  --from-literal=API_KEY=key123 \
  -n production

# Использовать в deployment:
env:
- name: DATABASE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: my-service-secrets
      key: DATABASE_PASSWORD
```

#### Option B: Sealed Secrets (рекомендуется)
```bash
# Установка:
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Создать sealed secret:
echo -n supersecret | kubectl create secret generic my-service-secrets \
  --dry-run=client --from-file=DATABASE_PASSWORD=/dev/stdin -o yaml | \
  kubeseal -o yaml > my-service-sealed-secret.yaml

# Commit в Git (безопасно):
git add my-service-sealed-secret.yaml
git commit -m "Add sealed secrets"
```

#### Option C: External Secrets Operator + Vault
```yaml
# Для enterprise use-cases
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-service-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: my-service-secrets
  data:
    - secretKey: DATABASE_PASSWORD
      remoteRef:
        key: secret/data/myservice
        property: db_password
```

**Рекомендация:** Sealed Secrets для малых команд, External Secrets + Vault для enterprise.

---

### 4. Monitoring & Alerting

#### Prometheus + Grafana (расширение текущего стека)

**Установка Prometheus Operator:**
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace
```

**ServiceMonitor для сервисов:**
```yaml
# packages/my-service/k8s/base/servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-service
spec:
  selector:
    matchLabels:
      app: my-service
  endpoints:
  - port: http
    path: /metrics
    interval: 30s
```

**Grafana Dashboard:**
```json
{
  "dashboard": {
    "title": "My Service Metrics",
    "panels": [
      {
        "title": "Request Rate",
        "targets": [
          {
            "expr": "rate(http_requests_total{service=\"my-service\"}[5m])"
          }
        ]
      },
      {
        "title": "Error Rate",
        "targets": [
          {
            "expr": "rate(http_requests_total{service=\"my-service\",status=~\"5..\"}[5m])"
          }
        ]
      }
    ]
  }
}
```

#### Alerting Rules

```yaml
# prometheus-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: my-service-alerts
spec:
  groups:
  - name: my-service
    interval: 30s
    rules:
    - alert: HighErrorRate
      expr: |
        rate(http_requests_total{service="my-service",status=~"5.."}[5m]) > 0.05
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "High error rate on {{ $labels.service }}"
        description: "{{ $labels.service }} has error rate > 5% for 5 minutes"
    
    - alert: ServiceDown
      expr: up{service="my-service"} == 0
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "Service {{ $labels.service }} is down"
```

---

### 5. Ingress & SSL

#### NGINX Ingress Controller

```bash
# Установка:
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace
```

#### Cert-Manager (Let's Encrypt)

```bash
# Установка:
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# ClusterIssuer:
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: devops@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
```

#### Ingress для сервиса

```yaml
# packages/my-service/k8s/overlays/prod/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-service
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/rate-limit: "100"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - my-service.example.com
    secretName: my-service-tls
  rules:
  - host: my-service.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-service
            port:
              number: 3000
```

---

### 6. Database Migrations

#### Kubernetes Job для миграций

```yaml
# packages/my-service/k8s/overlays/prod/migration-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: my-service-migrate-{{ .Version }}  # Версия из CI/CD
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: migrate
        image: registry.example.com/my-service:v1.0.0
        command: ["npm", "run", "migrate"]
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: database-credentials
              key: url
  backoffLimit: 3
```

#### Pre-deploy hook в CI/CD

```yaml
# В deploy-prod.yaml добавить:
- name: Run database migrations
  run: |
    kubectl apply -f packages/${{ inputs.service }}/k8s/overlays/prod/migration-job.yaml
    kubectl wait --for=condition=complete --timeout=5m job/my-service-migrate-${{ inputs.version }}
```

---

### 7. Blue-Green / Canary Deployments

#### Option A: Kubernetes native (labels)

```yaml
# Blue deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-service-blue
spec:
  selector:
    matchLabels:
      app: my-service
      version: blue
  template:
    metadata:
      labels:
        app: my-service
        version: blue

---
# Green deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-service-green
spec:
  selector:
    matchLabels:
      app: my-service
      version: green

---
# Service switches between blue/green
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  selector:
    app: my-service
    version: blue  # Переключить на green при деплое
```

#### Option B: Argo Rollouts (рекомендуется)

```bash
# Установка:
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

```yaml
# Rollout вместо Deployment:
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: my-service
spec:
  replicas: 5
  strategy:
    canary:
      steps:
      - setWeight: 20
      - pause: {duration: 5m}
      - setWeight: 40
      - pause: {duration: 5m}
      - setWeight: 60
      - pause: {duration: 5m}
      - setWeight: 80
      - pause: {duration: 5m}
  template:
    spec:
      containers:
      - name: my-service
        image: registry.example.com/my-service:v1.0.0
```

---

## Implementation Checklist

### Phase 1: Infrastructure Setup (Week 1-2)

- [ ] Выбрать и настроить Docker Registry (Harbor/GCR/ECR)
- [ ] Создать production namespace в K8s
- [ ] Установить NGINX Ingress Controller
- [ ] Настроить Cert-Manager для SSL
- [ ] Настроить Sealed Secrets или Vault
- [ ] Установить Prometheus + Grafana (если еще нет)

### Phase 2: CI/CD Pipeline (Week 2-3)

- [ ] Создать GitHub Actions workflows:
  - [ ] `build-service.yaml`
  - [ ] `deploy-prod.yaml`
  - [ ] `rollback.yaml`
- [ ] Настроить GitHub Secrets:
  - [ ] `REGISTRY_USERNAME`
  - [ ] `REGISTRY_PASSWORD`
  - [ ] `KUBECONFIG_PROD`
  - [ ] `SLACK_WEBHOOK_URL`
- [ ] Настроить GitHub Environments (production с approvals)
- [ ] Добавить vulnerability scanning (Trivy)

### Phase 3: Monitoring & Alerting (Week 3-4)

- [ ] Настроить ServiceMonitor для каждого сервиса
- [ ] Создать Grafana dashboards
- [ ] Настроить Prometheus alerts
- [ ] Интегрировать alerting с Slack/PagerDuty
- [ ] Настроить Loki retention policies для production

### Phase 4: Documentation & Training (Week 4)

- [ ] Обновить 05-SERVICES-GUIDE.md с prod примерами
- [ ] Создать runbooks для common issues
- [ ] Провести training для команды
- [ ] Создать incident response plan

### Phase 5: First Production Deploy (Week 5)

- [ ] Выбрать pilot сервис (tenants-dashboard?)
- [ ] Dry-run деплоя
- [ ] Production deploy с мониторингом
- [ ] Протестировать rollback
- [ ] Собрать feedback и улучшить процесс

---

## Cost Estimation

### Infrastructure (monthly):

- **Docker Registry:**
  - Harbor (self-hosted): ~$50-100 (VM costs)
  - GCR: ~$0.10/GB storage + egress
  - ECR: ~$0.10/GB storage + egress

- **Kubernetes Cluster:**
  - GKE/EKS: $70/month (3 nodes × $24)
  - DigitalOcean: $40/month (3 nodes × $12)

- **Monitoring:**
  - Prometheus + Grafana (self-hosted): $0 (runs in cluster)
  - Grafana Cloud: $0-299/month

- **SSL Certificates:**
  - Let's Encrypt: $0

**Total estimated: $110-470/month** (зависит от выбора managed vs self-hosted)

---

## Security Best Practices

### Image Scanning
```yaml
# В build-service.yaml уже добавлен Trivy
# Дополнительно можно добавить:
- name: Scan for secrets in code
  uses: trufflesecurity/trufflehog@main
  with:
    path: ./packages/${{ matrix.service }}
```

### Network Policies
```yaml
# packages/my-service/k8s/overlays/prod/network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: my-service
spec:
  podSelector:
    matchLabels:
      app: my-service
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: ingress-nginx
    ports:
    - protocol: TCP
      port: 3000
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: dev-infra  # или production
    ports:
    - protocol: TCP
      port: 5432  # PostgreSQL
    - protocol: TCP
      port: 6379  # Redis
    - protocol: TCP
      port: 9092  # Kafka
```

### Pod Security Standards
```yaml
# Enforce в namespace:
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

---

## Disaster Recovery

### Backup Strategy

**Database (Citus):**
```bash
# Daily backups:
kubectl create cronjob citus-backup \
  --image=postgres:15 \
  --schedule="0 2 * * *" \
  -- /bin/sh -c "pg_dump $DATABASE_URL | gzip > /backups/backup-$(date +%Y%m%d).sql.gz"
```

**Kubernetes Resources:**
```bash
# Velero для backup всего кластера:
velero install \
  --provider aws \
  --bucket my-backup-bucket \
  --backup-location-config region=us-east-1 \
  --secret-file ./credentials-velero

# Scheduled backup:
velero schedule create daily-backup --schedule="0 1 * * *"
```

### Recovery Procedures

1. **Service rollback:** `kubectl rollout undo` (см. rollback.yaml)
2. **Database restore:** `psql $DATABASE_URL < backup.sql`
3. **Full cluster restore:** `velero restore create --from-backup daily-backup-20251118`

---

## Maintenance Windows

### Zero-downtime deployments

**Требования:**
- `replicas: >= 2` в production
- `maxUnavailable: 0` в strategy
- Health checks настроены
- Graceful shutdown реализован

```yaml
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0  # Zero downtime!
```

### Maintenance mode

```yaml
# Temporary Ingress для maintenance page:
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: maintenance
  annotations:
    nginx.ingress.kubernetes.io/permanent-redirect: https://maintenance.example.com
spec:
  rules:
  - host: my-service.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: maintenance-page
            port:
              number: 80
```

---

## Contacts & Escalation

- **DevOps Lead:** [Name] - Slack: @devops-lead
- **On-Call rotation:** PagerDuty schedule
- **Incident channel:** #incidents
- **Questions:** #dev-infra

---

## Appendix

### Useful Commands

```bash
# Check deployment status
kubectl get deployments -n production

# View logs
kubectl logs -n production -l app=my-service --tail=100 -f

# Port-forward to prod (debugging only!)
kubectl port-forward -n production svc/my-service 8080:3000

# Scale deployment
kubectl scale deployment my-service -n production --replicas=5

# Get resource usage
kubectl top pods -n production -l app=my-service

# Check rollout history
kubectl rollout history deployment/my-service -n production

# Manual rollback to specific revision
kubectl rollout undo deployment/my-service -n production --to-revision=3
```

### Troubleshooting Guide

**Problem:** Image pull errors
```bash
# Check secret
kubectl get secret registry-credentials -n production -o yaml

# Test pull manually
docker login registry.example.com
docker pull registry.example.com/my-service:v1.0.0
```

**Problem:** Pod crash loop
```bash
# Check logs
kubectl logs -n production -l app=my-service --previous

# Check events
kubectl get events -n production --sort-by='.lastTimestamp'

# Describe pod
kubectl describe pod -n production -l app=my-service
```

**Problem:** Database connection timeout
```bash
# Test from pod
kubectl run -it --rm debug --image=postgres:15 --restart=Never -- \
  psql "postgresql://app:app@citus-coordinator.dev-infra.svc.cluster.local:5432/app" -c "SELECT 1"
```

---

**Документ подготовлен:** 2025-11-18  
**Для вопросов:** DevOps team в #dev-infra
