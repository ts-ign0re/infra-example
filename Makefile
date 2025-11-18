INFRA_DIR := infra
COMPOSE := docker compose -f $(INFRA_DIR)/docker-compose.yml --env-file $(INFRA_DIR)/.env
K8S_NS := dev-infra

.PHONY: infra-up infra-down infra-restart infra-wait infra-test migrate register-schemas generate-types generate-types-ts generate-types-php tilt-up tilt-down add-infra

infra-up:
	@if [ "$(USE_DOCKER)" = "1" ]; then \
		$(COMPOSE) up -d ; \
	else \
		kubectl apply -f $(INFRA_DIR)/k8s/namespace.yaml ; \
		kubectl apply -f $(INFRA_DIR)/k8s/redpanda.yaml -n $(K8S_NS) ; \
		kubectl apply -f $(INFRA_DIR)/k8s/schema-registry.yaml -n $(K8S_NS) ; \
		kubectl apply -f $(INFRA_DIR)/k8s/redis.yaml -n $(K8S_NS) ; \
		kubectl apply -f $(INFRA_DIR)/k8s/postgres.yaml -n $(K8S_NS) ; \
	fi

infra-down:
	@if [ "$(USE_DOCKER)" = "1" ]; then \
		$(COMPOSE) down -v ; \
	else \
		TILT_BIN=$$(bash $(INFRA_DIR)/scripts/ensure-tilt.sh 2>/dev/null || true) ; \
		if [ -n "$$TILT_BIN" ]; then ( cd $(INFRA_DIR) && $$TILT_BIN down ) || true ; fi ; \
		kubectl delete -f $(INFRA_DIR)/k8s/observability/grafana.yaml -n $(K8S_NS) --ignore-not-found ; \
		kubectl delete -f $(INFRA_DIR)/k8s/observability/promtail.yaml -n $(K8S_NS) --ignore-not-found ; \
		kubectl delete -f $(INFRA_DIR)/k8s/observability/loki.yaml -n $(K8S_NS) --ignore-not-found ; \
		kubectl delete -f $(INFRA_DIR)/k8s/citus-init.yaml -n $(K8S_NS) --ignore-not-found ; \
		kubectl delete -f $(INFRA_DIR)/k8s/citus-worker.yaml -n $(K8S_NS) --ignore-not-found ; \
		kubectl delete -f $(INFRA_DIR)/k8s/citus-coordinator.yaml -n $(K8S_NS) --ignore-not-found ; \
		kubectl delete -f $(INFRA_DIR)/k8s/postgres.yaml -n $(K8S_NS) --ignore-not-found ; \
		kubectl delete -f $(INFRA_DIR)/k8s/redis.yaml -n $(K8S_NS) --ignore-not-found ; \
		kubectl delete -f $(INFRA_DIR)/k8s/schema-registry.yaml -n $(K8S_NS) --ignore-not-found ; \
		kubectl delete -f $(INFRA_DIR)/k8s/redpanda.yaml -n $(K8S_NS) --ignore-not-found ; \
		kubectl delete namespace $(K8S_NS) --ignore-not-found || true ; \
		for i in $$(seq 1 60); do \
			if ! kubectl get ns $(K8S_NS) >/dev/null 2>&1; then echo "Namespace $(K8S_NS) deleted"; break; fi; \
			echo "Waiting for namespace $(K8S_NS) to terminate ..."; sleep 2; \
			if [ "$$i" -eq 60 ]; then echo "Timed out waiting for namespace deletion"; exit 1; fi; \
		done ; \
	fi

infra-restart: infra-down infra-up

infra-wait:
	@if [ "$(USE_DOCKER)" = "1" ]; then \
		bash $(INFRA_DIR)/scripts/wait-for-infra.sh ; \
	else \
		USE_K8S=1 K8S_NAMESPACE=$(K8S_NS) bash $(INFRA_DIR)/scripts/wait-for-infra.sh ; \
	fi

migrate:
	@if [ "$(USE_DOCKER)" = "1" ]; then \
		bash $(INFRA_DIR)/scripts/migrate.sh ; \
	else \
		USE_K8S=1 K8S_NAMESPACE=$(K8S_NS) bash $(INFRA_DIR)/scripts/migrate.sh ; \
	fi

register-schemas:
	@if [ "$(USE_DOCKER)" = "1" ]; then \
		bash $(INFRA_DIR)/scripts/register-schemas.sh ; \
	else \
		USE_K8S=1 K8S_NAMESPACE=$(K8S_NS) bash $(INFRA_DIR)/scripts/register-schemas.sh ; \
	fi

generate-types: generate-types-ts generate-types-php

generate-types-ts:
	bash $(INFRA_DIR)/scripts/generate-types-ts.sh

generate-types-php:
	bash $(INFRA_DIR)/scripts/generate-types-php.sh

tilt-up:
	@bash $(INFRA_DIR)/scripts/check-k8s.sh && \
	kubectl apply -f $(INFRA_DIR)/k8s/namespace.yaml && \
	TILT_BIN=$$(bash $(INFRA_DIR)/scripts/ensure-tilt.sh) && \
	cd $(INFRA_DIR) && DEV_MODE=true $$TILT_BIN up --stream=true

tilt-down:
	@TILT_BIN=$$(bash $(INFRA_DIR)/scripts/ensure-tilt.sh); \
	cd $(INFRA_DIR) && $$TILT_BIN down
integration:
	@bash $(INFRA_DIR)/scripts/check-k8s.sh && \
	TILT_BIN=$$(bash $(INFRA_DIR)/scripts/ensure-tilt.sh) && \
	kubectl apply -f $(INFRA_DIR)/k8s/namespace.yaml && \
	( cd $(INFRA_DIR) && $$TILT_BIN ci ) && \
	USE_K8S=1 K8S_NAMESPACE=$(K8S_NS) bash $(INFRA_DIR)/scripts/integration-tests.sh && \
	( cd $(INFRA_DIR) && $$TILT_BIN down )
obs-up:
	kubectl apply -f $(INFRA_DIR)/k8s/observability/loki.yaml -n $(K8S_NS)
	kubectl apply -f $(INFRA_DIR)/k8s/observability/promtail.yaml -n $(K8S_NS)
	kubectl apply -f $(INFRA_DIR)/k8s/observability/grafana.yaml -n $(K8S_NS)

obs-down:
	kubectl delete -f $(INFRA_DIR)/k8s/observability/grafana.yaml -n $(K8S_NS) --ignore-not-found
	kubectl delete -f $(INFRA_DIR)/k8s/observability/promtail.yaml -n $(K8S_NS) --ignore-not-found
	kubectl delete -f $(INFRA_DIR)/k8s/observability/loki.yaml -n $(K8S_NS) --ignore-not-found

# Enhanced integration tests v1.01 (with visual progress)
infra-test:
	@echo "Registering Avro schemas before tests..."
	@$(MAKE) register-schemas > /dev/null 2>&1 || true
	@if [ "$(USE_DOCKER)" = "1" ]; then \
		bash $(INFRA_DIR)/scripts/integration-tests.sh ; \
	else \
		USE_K8S=1 K8S_NAMESPACE=$(K8S_NS) bash $(INFRA_DIR)/scripts/integration-tests.sh ; \
	fi

# ============================================
# SERVICE MANAGEMENT
# ============================================

add-infra:
	@if [ -z "$(PATH)" ]; then \
		echo "Usage: make add-infra PATH=packages/existing-service" ; \
		echo "" ; \
		echo "Example: make add-infra PATH=packages/tenants-dashboard" ; \
		exit 1 ; \
	fi
	@./scripts/service-add-infra.sh $(PATH)

# ============================================
# ENVIRONMENT MANAGEMENT
# ============================================

# ============================================
# ENVIRONMENT MANAGEMENT
# ============================================

# Show all available environment variables in cluster
show-env:
	@echo "📋 Environment variables available to all services:"
	@echo ""
	@kubectl get configmap common-env -n $(K8S_NS) -o jsonpath='{.data}' 2>/dev/null | jq -r 'to_entries[] | "  \(.key)=\(.value)"' || echo "  ConfigMap not found. Run 'make tilt-up' first."

# Check environment variables in a running service
check-env:
	@echo "Checking environment in service: $(SERVICE)"
	@kubectl exec -n $(K8S_NS) deployment/$(SERVICE) -- env | sort || echo "Service $(SERVICE) not found"

# Example: make check-env SERVICE=tenants-dashboard

# ============================================
# HELP
# ============================================

.PHONY: help
help:

