INFRA_DIR := infra
COMPOSE := docker compose -f $(INFRA_DIR)/docker-compose.yml --env-file $(INFRA_DIR)/.env
K8S_NS := dev-infra

.PHONY: infra-up infra-down infra-restart infra-wait infra-test migrate register-schemas generate-types generate-types-ts generate-types-php tilt-up tilt-down

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
		kubectl delete -f $(INFRA_DIR)/k8s/postgres.yaml -n $(K8S_NS) --ignore-not-found ; \
		kubectl delete -f $(INFRA_DIR)/k8s/redis.yaml -n $(K8S_NS) --ignore-not-found ; \
		kubectl delete -f $(INFRA_DIR)/k8s/schema-registry.yaml -n $(K8S_NS) --ignore-not-found ; \
		kubectl delete -f $(INFRA_DIR)/k8s/redpanda.yaml -n $(K8S_NS) --ignore-not-found ; \
		kubectl delete -f $(INFRA_DIR)/k8s/namespace.yaml --ignore-not-found ; \
	fi

infra-restart: infra-down infra-up

infra-wait:
	@if [ "$(USE_DOCKER)" = "1" ]; then \
		bash $(INFRA_DIR)/scripts/wait-for-infra.sh ; \
	else \
		USE_K8S=1 K8S_NAMESPACE=$(K8S_NS) bash $(INFRA_DIR)/scripts/wait-for-infra.sh ; \
	fi

infra-test:
	@if [ "$(USE_DOCKER)" = "1" ]; then \
		bash $(INFRA_DIR)/scripts/integration-tests.sh ; \
	else \
		USE_K8S=1 K8S_NAMESPACE=$(K8S_NS) bash $(INFRA_DIR)/scripts/integration-tests.sh ; \
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
	cd $(INFRA_DIR) && $$TILT_BIN up --stream=true

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
