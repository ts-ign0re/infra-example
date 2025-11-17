#!/usr/bin/env bash
set -euo pipefail

# Verify kubectl is installed and a Kubernetes context is available.
# If not, print actionable install/enable instructions and exit non-zero.

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl не найден." >&2
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "Установите: brew install kubectl" >&2
  else
    echo "Установите kubectl для вашей ОС: https://kubernetes.io/docs/tasks/tools/" >&2
  fi
  exit 1
fi

current_ctx=$(kubectl config current-context 2>/dev/null || true)
if [ -z "$current_ctx" ]; then
  echo "Kubernetes кластер не настроен (нет current-context)." >&2
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "Варианты:" >&2
    echo "  1) Docker Desktop → Settings → Kubernetes → Enable Kubernetes" >&2
    echo "  2) kind: brew install kind && kind create cluster --name dev" >&2
    echo "  3) minikube: brew install minikube && minikube start" >&2
  else
    echo "Создайте локальный кластер (kind/minikube) и повторите попытку." >&2
  fi
  exit 1
fi

# Verify cluster is reachable
if ! kubectl get ns >/dev/null 2>&1; then
  echo "Нет подключения к Kubernetes кластеру (context: $current_ctx)." >&2
  echo "Проверьте, что кластер запущен и доступен." >&2
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "Для Docker Desktop: включите Kubernetes и дождитесь статуса 'running'." >&2
    echo "Для kind: kind create cluster --name dev && kubectl config use-context kind-dev" >&2
    echo "Для minikube: minikube start && kubectl config use-context minikube" >&2
  fi
  echo "Если kubeconfig в нестандартном месте — экспортируйте переменную KUBECONFIG." >&2
  echo "Пример: export KUBECONFIG=~/.kube/config" >&2
  exit 1
fi

# Verify at least one Ready node
ready_nodes=$(kubectl get nodes -o json 2>/dev/null | jq -r '[.items[] | any(.status.conditions[]; .type=="Ready" and .status=="True")] | any' 2>/dev/null || echo false)
if [ "$ready_nodes" != "true" ]; then
  echo "В кластере нет готовых (Ready) нод." >&2
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "Если используете Docker Desktop: включите Kubernetes и дождитесь, пока нода станет Ready." >&2
    echo "Если kind: kind create cluster --name dev (или kind get clusters / kind get nodes для проверки)." >&2
    echo "Если minikube: minikube start и дождитесь Ready." >&2
  fi
  exit 1
fi

exit 0
