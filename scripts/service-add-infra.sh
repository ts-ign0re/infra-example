#!/usr/bin/env bash
set -euo pipefail

# ============================================
# ADD INFRASTRUCTURE TO EXISTING PROJECT
# ============================================
# Usage: ./scripts/service-add-infra.sh path/to/existing/service

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="${SCRIPT_DIR%/scripts}"
PACKAGES_DIR="$ROOT_DIR/packages"
TEMPLATE_DIR="$PACKAGES_DIR/.template"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# ============================================
# FUNCTIONS
# ============================================

print_header() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BLUE}  $1${RESET}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
}

print_success() {
  echo -e "${GREEN}✓${RESET} $1"
}

print_info() {
  echo -e "${BLUE}ℹ${RESET} $1"
}

print_warning() {
  echo -e "${YELLOW}⚠${RESET} $1"
}

print_error() {
  echo -e "${RED}✗${RESET} $1"
}

# ============================================
# VALIDATION
# ============================================

if [ $# -eq 0 ]; then
  print_error "Service path is required!"
  echo ""
  echo "Usage: $0 SERVICE_PATH"
  echo ""
  echo "Examples:"
  echo "  $0 packages/existing-service"
  echo "  $0 ../my-existing-repo"
  exit 1
fi

SERVICE_PATH="$1"

# Convert to absolute path
if [[ "$SERVICE_PATH" != /* ]]; then
  SERVICE_PATH="$(cd "$SERVICE_PATH" 2>/dev/null && pwd)" || {
    print_error "Path does not exist: $1"
    exit 1
  }
fi

# Check if service directory exists
if [ ! -d "$SERVICE_PATH" ]; then
  print_error "Service directory not found: $SERVICE_PATH"
  exit 1
fi

# Extract service name from path
SERVICE_NAME=$(basename "$SERVICE_PATH")

# Validate service name (kebab-case)
if ! [[ "$SERVICE_NAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
  print_warning "Service name '$SERVICE_NAME' is not in kebab-case"
  echo ""
  read -p "Continue anyway? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Check if template exists
if [ ! -d "$TEMPLATE_DIR" ]; then
  print_error "Template directory not found: $TEMPLATE_DIR"
  exit 1
fi

# ============================================
# INTERACTIVE MODE
# ============================================

print_header "Add Infrastructure to: $SERVICE_NAME"

echo -e "${YELLOW}What do you want to add?${RESET}\n"
echo "1) Dockerfile (if missing)"
echo "2) Kubernetes manifests (k8s/)"
echo "3) All of the above"
echo "4) Cancel"
echo ""
read -p "Select option [1-4]: " -n 1 -r OPTION
echo ""

case $OPTION in
  1) ADD_DOCKERFILE=true; ADD_K8S=false ;;
  2) ADD_DOCKERFILE=false; ADD_K8S=true ;;
  3) ADD_DOCKERFILE=true; ADD_K8S=true ;;
  4) echo "Cancelled."; exit 0 ;;
  *) print_error "Invalid option"; exit 1 ;;
esac

# ============================================
# DETECT EXISTING SETUP
# ============================================

print_info "Analyzing existing project..."

# Detect language/framework
DETECTED_LANG=""
if [ -f "$SERVICE_PATH/package.json" ]; then
  DETECTED_LANG="nodejs"
  print_success "Detected: Node.js project"
elif [ -f "$SERVICE_PATH/go.mod" ]; then
  DETECTED_LANG="go"
  print_success "Detected: Go project"
elif [ -f "$SERVICE_PATH/requirements.txt" ] || [ -f "$SERVICE_PATH/pyproject.toml" ]; then
  DETECTED_LANG="python"
  print_success "Detected: Python project"
elif [ -f "$SERVICE_PATH/composer.json" ]; then
  DETECTED_LANG="php"
  print_success "Detected: PHP project"
else
  print_warning "Could not detect language/framework"
  DETECTED_LANG="unknown"
fi

# Detect port
DETECTED_PORT="3000"
if [ -f "$SERVICE_PATH/package.json" ]; then
  # Try to find port in package.json scripts
  PORT_FROM_SCRIPTS=$(grep -o "PORT=[0-9]*" "$SERVICE_PATH/package.json" 2>/dev/null | head -1 | cut -d= -f2 || echo "")
  if [ -n "$PORT_FROM_SCRIPTS" ]; then
    DETECTED_PORT="$PORT_FROM_SCRIPTS"
  fi
fi

echo ""
read -p "Application port [default: $DETECTED_PORT]: " USER_PORT
APP_PORT="${USER_PORT:-$DETECTED_PORT}"

# ============================================
# ADD DOCKERFILE
# ============================================

if [ "$ADD_DOCKERFILE" = true ]; then
  if [ -f "$SERVICE_PATH/Dockerfile" ]; then
    print_warning "Dockerfile already exists"
    read -p "Overwrite? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      print_info "Skipping Dockerfile"
      ADD_DOCKERFILE=false
    fi
  fi
  
  if [ "$ADD_DOCKERFILE" = true ]; then
    print_info "Creating Dockerfile..."
    
    case $DETECTED_LANG in
      nodejs)
        cat > "$SERVICE_PATH/Dockerfile" <<'EOF'
# Multi-stage Dockerfile for Node.js
FROM node:20-alpine AS builder

WORKDIR /app

COPY package*.json ./
RUN npm ci --only=production

COPY . .
RUN npm run build || true

FROM node:20-alpine

RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001 -G nodejs

WORKDIR /app

COPY --from=builder --chown=nodejs:nodejs /app/dist ./dist
COPY --from=builder --chown=nodejs:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=nodejs:nodejs /app/package*.json ./

USER nodejs

EXPOSE __APP_PORT__

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:__APP_PORT__/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1))"

CMD ["node", "dist/index.js"]
EOF
        ;;
      
      go)
        cat > "$SERVICE_PATH/Dockerfile" <<'EOF'
FROM golang:1.21-alpine AS builder

WORKDIR /app

COPY go.* ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /server

FROM alpine:latest

RUN apk --no-cache add ca-certificates
RUN addgroup -g 1001 -S appuser && adduser -S appuser -u 1001 -G appuser

COPY --from=builder --chown=appuser:appuser /server /server

USER appuser

EXPOSE __APP_PORT__

HEALTHCHECK --interval=30s CMD wget -qO- http://localhost:__APP_PORT__/health || exit 1

CMD ["/server"]
EOF
        ;;
      
      python)
        cat > "$SERVICE_PATH/Dockerfile" <<'EOF'
FROM python:3.11-slim AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

COPY . .

FROM python:3.11-slim

RUN addgroup --gid 1001 --system appuser && \
    adduser --uid 1001 --system --gid 1001 appuser

WORKDIR /app

COPY --from=builder --chown=appuser:appuser /root/.local /home/appuser/.local
COPY --from=builder --chown=appuser:appuser /app .

USER appuser

ENV PATH=/home/appuser/.local/bin:$PATH

EXPOSE __APP_PORT__

HEALTHCHECK --interval=30s CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:__APP_PORT__/health')" || exit 1

CMD ["python", "main.py"]
EOF
        ;;
      
      *)
        # Generic Dockerfile
        cp "$TEMPLATE_DIR/Dockerfile" "$SERVICE_PATH/Dockerfile"
        ;;
    esac
    
    # Replace port placeholder
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "s/__APP_PORT__/$APP_PORT/g" "$SERVICE_PATH/Dockerfile"
    else
      sed -i "s/__APP_PORT__/$APP_PORT/g" "$SERVICE_PATH/Dockerfile"
    fi
    
    print_success "Dockerfile created"
    
    # Create .dockerignore if it doesn't exist
    if [ ! -f "$SERVICE_PATH/.dockerignore" ]; then
      cp "$TEMPLATE_DIR/.dockerignore" "$SERVICE_PATH/.dockerignore"
      print_success ".dockerignore created"
    fi
  fi
fi

# ============================================
# ADD KUBERNETES MANIFESTS
# ============================================

if [ "$ADD_K8S" = true ]; then
  print_info "Creating Kubernetes manifests..."
  
  # Create k8s directory structure
  mkdir -p "$SERVICE_PATH/k8s/base"
  mkdir -p "$SERVICE_PATH/k8s/overlays/dev"
  mkdir -p "$SERVICE_PATH/k8s/overlays/prod"
  
  # Function to replace placeholders
  replace_placeholders() {
    local file="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "s/REPLACE_SERVICE_NAME/$SERVICE_NAME/g" "$file"
      sed -i '' "s/3000/$APP_PORT/g" "$file"
    else
      sed -i "s/REPLACE_SERVICE_NAME/$SERVICE_NAME/g" "$file"
      sed -i "s/3000/$APP_PORT/g" "$file"
    fi
  }
  
  # Copy base manifests
  for file in deployment.yaml service.yaml kustomization.yaml; do
    if [ -f "$SERVICE_PATH/k8s/base/$file" ]; then
      print_warning "k8s/base/$file already exists, skipping"
    else
      cp "$TEMPLATE_DIR/k8s/base/$file" "$SERVICE_PATH/k8s/base/$file"
      replace_placeholders "$SERVICE_PATH/k8s/base/$file"
      print_success "Created k8s/base/$file"
    fi
  done
  
  # Copy dev overlay
  if [ -f "$SERVICE_PATH/k8s/overlays/dev/kustomization.yaml" ]; then
    print_warning "k8s/overlays/dev/kustomization.yaml already exists, skipping"
  else
    cp "$TEMPLATE_DIR/k8s/overlays/dev/kustomization.yaml" "$SERVICE_PATH/k8s/overlays/dev/"
    replace_placeholders "$SERVICE_PATH/k8s/overlays/dev/kustomization.yaml"
    print_success "Created k8s/overlays/dev/kustomization.yaml"
  fi
  
  # Copy prod overlay
  if [ -f "$SERVICE_PATH/k8s/overlays/prod/kustomization.yaml" ]; then
    print_warning "k8s/overlays/prod/kustomization.yaml already exists, skipping"
  else
    cp "$TEMPLATE_DIR/k8s/overlays/prod/kustomization.yaml" "$SERVICE_PATH/k8s/overlays/prod/"
    replace_placeholders "$SERVICE_PATH/k8s/overlays/prod/kustomization.yaml"
    print_success "Created k8s/overlays/prod/kustomization.yaml"
  fi
  
  # Create .tiltignore if needed
  if [ ! -f "$SERVICE_PATH/.tiltignore" ]; then
    cp "$TEMPLATE_DIR/.tiltignore" "$SERVICE_PATH/.tiltignore"
    print_success ".tiltignore created"
  fi
fi

# ============================================
# VERIFY & TEST
# ============================================

print_header "Verification"

print_info "Checking if service is ready for Tilt..."

HAS_DOCKERFILE=false
HAS_K8S=false

if [ -f "$SERVICE_PATH/Dockerfile" ]; then
  print_success "Dockerfile: ✓"
  HAS_DOCKERFILE=true
else
  print_warning "Dockerfile: ✗"
fi

if [ -f "$SERVICE_PATH/k8s/overlays/dev/kustomization.yaml" ]; then
  print_success "Kubernetes manifests: ✓"
  HAS_K8S=true
else
  print_warning "Kubernetes manifests: ✗"
fi

echo ""

if [ "$HAS_DOCKERFILE" = true ] && [ "$HAS_K8S" = true ]; then
  print_success "Service is ready for Tilt! 🎉"
  
  # Test kustomize build
  print_info "Testing kustomize build..."
  if command -v kustomize &> /dev/null; then
    if kustomize build "$SERVICE_PATH/k8s/overlays/dev" > /dev/null 2>&1; then
      print_success "Kustomize build: OK"
    else
      print_error "Kustomize build failed - check manifests"
    fi
  elif command -v kubectl &> /dev/null; then
    if kubectl kustomize "$SERVICE_PATH/k8s/overlays/dev" > /dev/null 2>&1; then
      print_success "Kustomize build: OK"
    else
      print_error "Kustomize build failed - check manifests"
    fi
  else
    print_warning "kustomize/kubectl not found, skipping validation"
  fi
else
  print_warning "Service is not fully configured yet"
fi

# ============================================
# SUMMARY & NEXT STEPS
# ============================================

print_header "Summary & Next Steps"

echo -e "${GREEN}Files created/updated in:${RESET}"
echo "  $SERVICE_PATH"
echo ""

if [ "$HAS_DOCKERFILE" = true ] && [ "$HAS_K8S" = true ]; then
  echo -e "${GREEN}✅ Ready to deploy!${RESET}"
  echo ""
  echo "Next steps:"
  echo ""
  echo "1. Review the generated files:"
  echo "   ${BLUE}cd $SERVICE_PATH${RESET}"
  echo "   ${BLUE}cat Dockerfile${RESET}"
  echo "   ${BLUE}cat k8s/base/deployment.yaml${RESET}"
  echo ""
  echo "2. Adjust environment variables in deployment.yaml if needed"
  echo ""
  echo "3. Deploy with Tilt:"
  echo "   ${BLUE}make tilt-up${RESET}"
  echo ""
  echo "   Tilt will automatically detect and deploy your service!"
  echo ""
else
  echo "Please complete the missing files before deploying."
  echo ""
fi

echo -e "${YELLOW}📖 Documentation:${RESET}"
echo "   - Services Guide: docs/SERVICES_GUIDE.md"
echo "   - Production Deploy: docs/PRODUCTION_DEPLOYMENT.md"
echo ""

print_success "Done!"
