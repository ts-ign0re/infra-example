#!/usr/bin/env bash
# Auto-setup script для локального Kubernetes кластера
# Определяет OS и предлагает установку недостающих компонентов

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для вывода
info() { echo -e "${BLUE}ℹ${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warning() { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*"; }

# Определить OS
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [ -f /etc/arch-release ]; then
            echo "arch"
        elif [ -f /etc/debian_version ]; then
            echo "debian"
        elif [ -f /etc/redhat-release ]; then
            echo "redhat"
        else
            echo "linux"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    else
        echo "unknown"
    fi
}

# Проверить установлен ли kubectl
check_kubectl() {
    if command -v kubectl &> /dev/null; then
        success "kubectl установлен: $(kubectl version --client --short 2>/dev/null | head -1)"
        return 0
    else
        warning "kubectl не установлен"
        return 1
    fi
}

# Проверить установлен ли Docker
check_docker() {
    if command -v docker &> /dev/null && docker ps &> /dev/null; then
        success "Docker установлен и работает: $(docker --version)"
        return 0
    elif command -v docker &> /dev/null; then
        warning "Docker установлен, но не запущен"
        return 2
    else
        warning "Docker не установлен"
        return 1
    fi
}

# Проверить установлен ли Tilt
check_tilt() {
    if command -v tilt &> /dev/null; then
        success "Tilt установлен: $(tilt version 2>/dev/null | head -1)"
        return 0
    else
        warning "Tilt не установлен"
        return 1
    fi
}

# Проверить наличие Kubernetes кластера
check_k8s_cluster() {
    if kubectl cluster-info &> /dev/null; then
        local context=$(kubectl config current-context 2>/dev/null || echo "unknown")
        success "Kubernetes кластер доступен: $context"
        return 0
    else
        warning "Kubernetes кластер не настроен"
        return 1
    fi
}

# Проверить установлен ли k3d
check_k3d() {
    if command -v k3d &> /dev/null; then
        success "k3d установлен: $(k3d version 2>/dev/null | head -1)"
        return 0
    else
        return 1
    fi
}

# Проверить установлен ли minikube
check_minikube() {
    if command -v minikube &> /dev/null; then
        success "minikube установлен: $(minikube version --short 2>/dev/null)"
        return 0
    else
        return 1
    fi
}

# Установить k3d на Arch Linux
install_k3d_arch() {
    info "Устанавливаю k3d через yay..."
    if command -v yay &> /dev/null; then
        yay -S --noconfirm k3d
    else
        warning "yay не установлен, использую curl..."
        curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    fi
}

# Установить kubectl на Arch Linux
install_kubectl_arch() {
    info "Устанавливаю kubectl..."
    sudo pacman -S --noconfirm kubectl
}

# Установить Docker на Arch Linux
install_docker_arch() {
    info "Устанавливаю Docker..."
    sudo pacman -S --noconfirm docker docker-compose
    sudo systemctl enable docker
    sudo systemctl start docker
    
    warning "Добавляю пользователя в группу docker..."
    sudo usermod -aG docker $USER
    
    warning "Необходимо перелогиниться для применения изменений группы!"
    warning "Выполните: newgrp docker"
    warning "Или перезагрузитесь: sudo reboot"
}

# Установить Tilt на Arch Linux
install_tilt_arch() {
    info "Устанавливаю Tilt..."
    if command -v yay &> /dev/null; then
        yay -S --noconfirm tilt-bin
    else
        curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/install.sh | bash
    fi
}

# Создать k3d кластер
create_k3d_cluster() {
    info "Создаю k3d кластер 'local-dev'..."
    k3d cluster create local-dev \
        --servers 1 \
        --agents 1 \
        --port "8080:80@loadbalancer" \
        --port "8443:443@loadbalancer"
    
    success "k3d кластер создан!"
    sleep 2
    kubectl cluster-info
}

# Создать minikube кластер
create_minikube_cluster() {
    info "Создаю minikube кластер..."
    minikube start --driver=docker --cpus=4 --memory=8192
    
    success "minikube кластер создан!"
    sleep 2
    kubectl cluster-info
}

# Интерактивный выбор метода установки кластера
choose_cluster_type() {
    echo ""
    info "Выберите тип Kubernetes кластера:"
    echo "  1) k3d (рекомендуется - легкий и быстрый)"
    echo "  2) minikube (стандартный вариант)"
    echo "  3) Отмена (настрою вручную)"
    echo ""
    read -p "Ваш выбор [1-3]: " choice
    
    case $choice in
        1)
            if ! check_k3d; then
                if [[ $(detect_os) == "arch" ]]; then
                    install_k3d_arch
                else
                    error "Автоматическая установка k3d поддерживается только на Arch Linux"
                    info "Установите вручную: https://k3d.io/v5.6.0/#installation"
                    return 1
                fi
            fi
            create_k3d_cluster
            ;;
        2)
            if ! check_minikube; then
                if [[ $(detect_os) == "arch" ]]; then
                    info "Устанавливаю minikube..."
                    sudo pacman -S --noconfirm minikube
                else
                    error "Автоматическая установка minikube поддерживается только на Arch Linux"
                    info "Установите вручную: https://minikube.sigs.k8s.io/docs/start/"
                    return 1
                fi
            fi
            create_minikube_cluster
            ;;
        3)
            info "Настройте кластер вручную и запустите 'make tilt-up' снова"
            return 1
            ;;
        *)
            error "Неверный выбор"
            return 1
            ;;
    esac
}

# Главная функция
main() {
    echo ""
    info "🔍 Проверка окружения для Kubernetes..."
    echo ""
    
    local os=$(detect_os)
    info "Обнаружена ОС: $os"
    echo ""
    
    # Проверки
    local need_install=false
    local need_cluster=false
    
    # Проверка kubectl
    if ! check_kubectl; then
        need_install=true
        if [[ "$os" == "arch" ]]; then
            echo ""
            read -p "Установить kubectl? [Y/n]: " answer
            if [[ "$answer" != "n" && "$answer" != "N" ]]; then
                install_kubectl_arch
            fi
        fi
    fi
    
    # Проверка Docker
    local docker_status=0
    check_docker || docker_status=$?
    if [[ $docker_status -eq 1 ]]; then
        need_install=true
        if [[ "$os" == "arch" ]]; then
            echo ""
            read -p "Установить Docker? [Y/n]: " answer
            if [[ "$answer" != "n" && "$answer" != "N" ]]; then
                install_docker_arch
                error "Docker установлен! Необходимо перелогиниться или выполнить: newgrp docker"
                exit 1
            fi
        fi
    elif [[ $docker_status -eq 2 ]]; then
        echo ""
        read -p "Запустить Docker? [Y/n]: " answer
        if [[ "$answer" != "n" && "$answer" != "N" ]]; then
            sudo systemctl start docker
            success "Docker запущен"
        fi
    fi
    
    # Проверка кластера
    if ! check_k8s_cluster; then
        need_cluster=true
    fi
    
    # Проверка Tilt
    if ! check_tilt; then
        need_install=true
        if [[ "$os" == "arch" ]]; then
            echo ""
            read -p "Установить Tilt? [Y/n]: " answer
            if [[ "$answer" != "n" && "$answer" != "N" ]]; then
                install_tilt_arch
            fi
        fi
    fi
    
    # Если нужен кластер
    if [[ "$need_cluster" == true ]]; then
        echo ""
        warning "Kubernetes кластер не обнаружен"
        
        if [[ "$os" == "arch" ]]; then
            read -p "Создать локальный кластер автоматически? [Y/n]: " answer
            if [[ "$answer" != "n" && "$answer" != "N" ]]; then
                choose_cluster_type
            else
                error "Кластер не настроен. Следуйте инструкции: docs/03-LINUX-SETUP.md"
                exit 1
            fi
        else
            error "Кластер не настроен. Следуйте инструкции: docs/01-SETUP-INFRASTRUCTURE.md"
            exit 1
        fi
    fi
    
    # Финальная проверка
    echo ""
    info "🎉 Финальная проверка..."
    echo ""
    
    if check_kubectl && check_docker && check_k8s_cluster && check_tilt; then
        echo ""
        success "✅ Всё готово для запуска!"
        success "Запускаю Tilt..."
        return 0
    else
        echo ""
        error "❌ Не все компоненты установлены"
        error "Проверьте вывод выше и установите недостающие компоненты"
        
        if [[ "$os" == "arch" ]]; then
            info "Инструкция: docs/03-LINUX-SETUP.md"
        else
            info "Инструкция: docs/01-SETUP-INFRASTRUCTURE.md"
        fi
        
        exit 1
    fi
}

# Запуск
main "$@"
