# Быстрый старт на Linux (Arch, Ubuntu, Debian)

> **Цель:** Настроить локальный Kubernetes кластер и запустить проект на любом Linux дистрибутиве

---

## 🚀 Автоматическая установка (рекомендуется!)

Самый простой способ - просто запустить:

```bash
cd /path/to/ideas
make tilt-up
```

Скрипт автоматически:
- ✅ Определит ваш Linux дистрибутив (Arch, Ubuntu, Debian)
- ✅ Проверит установленные компоненты (kubectl, Docker, Tilt, кластер)
- ✅ Предложит установить недостающие компоненты (только Arch Linux пока)
- ✅ Поможет создать k3d или minikube кластер
- ✅ Запустит Tilt с инфраструктурой

**Для Arch Linux:** Полная автоматическая установка  
**Для Ubuntu/Debian:** Проверка + инструкции по установке вручную

**Просто следуйте интерактивным подсказкам!**

---

## 📋 Ручная установка

### Ubuntu / Debian

#### Предустановки

```bash
# Обновить систему
sudo apt update && sudo apt upgrade -y

# Установить базовые утилиты
sudo apt install -y curl wget git make
```

#### Шаг 1: Установить Docker

```bash
# Установить Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Добавить пользователя в группу docker
sudo usermod -aG docker $USER

# Применить изменения (или перелогиниться)
newgrp docker

# Включить автозапуск
sudo systemctl enable docker
sudo systemctl start docker

# Проверить
docker --version
docker ps
```

#### Шаг 2: Установить kubectl

```bash
# Установить kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Проверить
kubectl version --client
```

#### Шаг 3: Выбрать и установить Kubernetes кластер

**Вариант A: k3d (рекомендуется - легкий и быстрый)**

```bash
# Установить k3d
wget -q -O - https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# Создать кластер
k3d cluster create local-dev \
  --servers 1 \
  --agents 1 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer"

# Проверить
kubectl cluster-info
kubectl get nodes
```

**Вариант B: minikube**

```bash
# Установить minikube
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube

# Запустить кластер
minikube start --driver=docker --cpus=4 --memory=8192

# Проверить
kubectl cluster-info
kubectl get nodes
```

**Вариант C: kind (Kubernetes IN Docker)**

```bash
# Установить kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Создать кластер
kind create cluster --name local-dev

# Проверить
kubectl cluster-info
kubectl get nodes
```

#### Шаг 4: Установить Tilt

```bash
# Установить Tilt
curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/install.sh | bash

# Проверить
tilt version
```

#### Шаг 5: Запустить проект

```bash
cd /path/to/ideas
make tilt-up
```

---

### Arch Linux

#### Предустановки

```bash
# Обновить систему
sudo pacman -Syu

# Установить базовые утилиты
sudo pacman -S base-devel git curl wget
```

#### Шаг 1: Установить Docker

```bash
# Установить Docker
sudo pacman -S docker docker-compose

# Включить и запустить
sudo systemctl enable docker
sudo systemctl start docker

# Добавить пользователя в группу docker
sudo usermod -aG docker $USER

# Применить изменения
newgrp docker

# Проверить
docker --version
docker ps
```

#### Шаг 2: Установить kubectl

```bash
# Установить kubectl
sudo pacman -S kubectl

# Проверить
kubectl version --client
```

#### Шаг 3: Выбрать и установить Kubernetes кластер

**Вариант A: k3d (рекомендуется - легкий и быстрый)**

```bash
# Установить k3d
yay -S k3d
# или без yay:
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# Создать кластер
k3d cluster create local-dev \
  --servers 1 \
  --agents 1 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer"

# Проверить
kubectl cluster-info
kubectl get nodes
```

**Вариант B: minikube**

```bash
# Установить minikube
sudo pacman -S minikube
# или через yay:
yay -S minikube

# Запустить кластер
minikube start --driver=docker --cpus=4 --memory=8192

# Проверить
kubectl cluster-info
kubectl get nodes
```

**Вариант C: kind**

```bash
# Установить kind
yay -S kind-bin
# или через go:
go install sigs.k8s.io/kind@latest

# Создать кластер
kind create cluster --name local-dev

# Проверить
kubectl cluster-info
kubectl get nodes
```

#### Шаг 4: Установить Tilt

```bash
# Установить Tilt
yay -S tilt-bin
# или без yay:
curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/install.sh | bash

# Проверить
tilt version
```

#### Шаг 5: Запустить проект

```bash
cd /path/to/ideas
make tilt-up
```

---

## Проверка настройки

```bash
# Проверить что kubectl работает
kubectl cluster-info

# Должны увидеть что-то типа:
# Kubernetes control plane is running at https://127.0.0.1:XXXXX

# Проверить current-context
kubectl config current-context

# Должен быть: k3d-local-dev, minikube, или kind-local-dev
```

---

## Troubleshooting

### Проблема: "Kubernetes кластер не настроен"

```bash
# Проверить список кластеров
kubectl config get-contexts

# Если пусто - создайте кластер (см. выше)
# Если есть кластеры, но не выбран current-context:
kubectl config use-context k3d-local-dev
# или
kubectl config use-context minikube
# или
kubectl config use-context kind-local-dev
```

### Проблема: Docker permission denied

```bash
# Добавить себя в группу docker
sudo usermod -aG docker $USER

# Перелогиниться или применить изменения
newgrp docker

# Или перезагрузиться
sudo reboot
```

### Проблема: kubectl не находит кластер

```bash
# Проверить что Docker работает
docker ps

# Проверить что кластер запущен
k3d cluster list
# или
minikube status
# или
kind get clusters

# Если кластер не запущен:
k3d cluster start local-dev
# или
minikube start
# или
kind create cluster --name local-dev
```

### Проблема: Tilt не запускается

```bash
# Убедиться что порт 10350 свободен
sudo netstat -tlnp | grep 10350
# или на Ubuntu:
sudo ss -tlnp | grep 10350

# Если занят - убить процесс или использовать другой порт
tilt up --port=10351
```

### Проблема: k3d не может создать кластер (Ubuntu)

```bash
# Проверить что Docker работает корректно
docker run hello-world

# Проверить что нет конфликтов с firewall
sudo ufw status

# Если firewall включен, разрешить Docker networks
sudo ufw allow from 172.17.0.0/16
sudo ufw allow from 172.18.0.0/16
```

---

## Что дальше?

После успешного запуска `make tilt-up`:

1. **Откройте Tilt UI**: http://localhost:10350
2. **Подождите** пока все ресурсы станут зелеными (~2-3 минуты)
3. **Проверьте инфраструктуру**:
   ```bash
   make infra-test
   ```
4. **Следуйте основной документации**: `docs/02-QUICKSTART.md`

---

## Полезные команды

```bash
# Статус кластера
kubectl cluster-info

# Список всех подов
kubectl get pods -A

# Логи конкретного сервиса
kubectl -n dev-infra logs -f deploy/citus-coordinator

# Остановить Tilt
# Ctrl+C в терминале или:
tilt down

# Удалить кластер (если нужно пересоздать)
k3d cluster delete local-dev
# или
minikube delete
# или
kind delete cluster --name local-dev
```

---

## Рекомендации по ресурсам

**Минимальные требования:**
- CPU: 4 ядра
- RAM: 8 GB
- Диск: 20 GB свободного места

**Рекомендуемые:**
- CPU: 6-8 ядер
- RAM: 16 GB
- Диск: 40 GB свободного места
- SSD (для быстрой работы БД)

**Настройка ресурсов для k3d:**
```bash
k3d cluster create local-dev \
  --servers 1 \
  --agents 1 \
  --port "8080:80@loadbalancer" \
  --k3s-arg "--kubelet-arg=max-pods=250@server:*"
```

**Настройка ресурсов для minikube:**
```bash
minikube start \
  --driver=docker \
  --cpus=6 \
  --memory=12288 \
  --disk-size=40g
```

---

## Linux специфичные замечания

### Ubuntu/Debian: snap vs apt

Ubuntu часто устанавливает пакеты через snap, что может вызвать проблемы:

```bash
# Проверить установлен ли через snap
snap list | grep docker

# Если да - лучше переустановить через apt (см. инструкцию выше)
sudo snap remove docker
```

### Arch Linux: AUR helpers

Если у вас нет `yay`:
```bash
# Установить yay
cd /tmp
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si
```

### Firewall (все дистрибутивы)

Если используете firewall (ufw, firewalld, iptables):
```bash
# Ubuntu/Debian (ufw)
sudo ufw allow from 172.17.0.0/16
sudo ufw allow from 172.18.0.0/16

# Fedora/CentOS (firewalld)
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="172.17.0.0/16" accept'
sudo firewall-cmd --reload

# Arch Linux (iptables)
sudo iptables -A INPUT -s 172.17.0.0/16 -j ACCEPT
sudo iptables -A INPUT -s 172.18.0.0/16 -j ACCEPT
```

### SELinux / AppArmor

Если включен (обычно на Ubuntu/Fedora):
```bash
# Проверить статус AppArmor (Ubuntu)
sudo aa-status

# Проверить статус SELinux (Fedora)
getenforce

# Если вызывает проблемы с Docker:
# Ubuntu - отключить для Docker
sudo aa-complain /usr/bin/docker

# Fedora - настроить SELinux
sudo setsebool -P container_manage_cgroup on
```

---

## Сравнение вариантов установки кластера

| Вариант | Плюсы | Минусы | Рекомендуется |
|---------|-------|--------|---------------|
| **k3d** | Очень легкий, быстрый запуск | Меньше функций | ✅ Для разработки |
| **minikube** | Полный функционал, стабильный | Медленнее, больше ресурсов | ✅ Если нужна совместимость |
| **kind** | Быстрый, хорош для тестов | Меньше документации | ⚠️ Для CI/CD |

**Наша рекомендация:** k3d для повседневной разработки

---

**Дата:** 2025-11-19  
**OS:** Linux (Arch, Ubuntu, Debian, Fedora)  
**Tested on:** Arch Linux (kernel 6.6+), Ubuntu 22.04/24.04, Debian 12

