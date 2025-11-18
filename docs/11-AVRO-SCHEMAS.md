# Работа с Avro схемами

> Автоматическая регистрация схем в Schema Registry

---

## 🚀 Быстрый старт

### Схемы регистрируются автоматически!

При запуске `make tilt-up` все схемы из `/infra/schemas/` автоматически регистрируются в Schema Registry.

**Вам НЕ нужно:**
- ❌ Вручную регистрировать схемы
- ❌ Запускать `make register-schemas` после старта
- ❌ Беспокоиться о версионировании (handled automatically)

**Tilt делает всё за вас:**
1. Запускает Schema Registry
2. Ждёт готовности
3. Автоматически регистрирует все `.avsc` файлы
4. Настраивает compatibility mode

---

## 📝 Добавление новой схемы

### Шаг 1: Создайте `.avsc` файл

```bash
# Создать новую схему
cat > infra/schemas/MyNewEvent.avsc <<'EOF'
{
  "type": "record",
  "name": "MyNewEvent",
  "namespace": "com.platform.events",
  "fields": [
    {"name": "id", "type": "string"},
    {"name": "timestamp", "type": "long"},
    {"name": "data", "type": "string"}
  ]
}
EOF
```

### Шаг 2: Добавьте маппинг на топик

Отредактируйте `infra/scripts/register-schemas.sh`:

```bash
map_subject() {
  case "$1" in
    BetEvent) echo "${TOPIC_BETS:-V1_BETS}-value" ;;
    PaymentEvent) echo "${TOPIC_PAYMENTS:-V1_PAYMENTS}-value" ;;
    MyNewEvent) echo "${TOPIC_MY_NEW:-V1_MY_NEW}-value" ;;  # Добавить эту строку
    *) return 1 ;;
  esac
}
```

### Шаг 3: Перезапустите Tilt

```bash
# Tilt автоматически подхватит изменения
# Или принудительно перезапустите регистрацию:
make register-schemas
```

**Готово!** 🎉 Схема зарегистрирована и доступна для использования.

---

## 🔍 Проверка зарегистрированных схем

### Через curl:

```bash
# Список всех subjects
curl http://localhost:8081/subjects

# Получить конкретную схему
curl http://localhost:8081/subjects/V1_BETS-value/versions/latest
```

### Через Tilt UI:

1. Откройте Tilt UI: http://localhost:10350
2. Найдите ресурс `register-schemas`
3. Посмотрите логи регистрации

---

## 📚 Доступные схемы

Текущие схемы в системе:

| Файл | Subject | Топик | Описание |
|------|---------|-------|----------|
| `BetEvent.avsc` | V1_BETS-value | V1_BETS | События ставок |
| `PaymentEvent.avsc` | V1_PAYMENTS-value | V1_PAYMENTS | События платежей |
| `BalanceEvent.avsc` | V1_BALANCES-value | V1_BALANCES | События балансов |
| `ComplianceEvent.avsc` | V1_COMPLIANCE-value | V1_COMPLIANCE | Регуляторные события |
| `SystemEvent.avsc` | V1_SYSTEM-value | V1_SYSTEM | Системные события |
| `TenantEvent.avsc` | V1_TENANTS-value | V1_TENANTS | События управления тенантами |

---

## 🔧 Ручная регистрация (если нужно)

В редких случаях может потребоваться ручная регистрация:

```bash
# Зарегистрировать все схемы вручную
make register-schemas

# Или через скрипт напрямую
cd infra && bash scripts/register-schemas.sh
```

---

## 🛠️ Troubleshooting

### Схема не регистрируется

**Проблема:** Схема не появляется в Schema Registry

**Решение:**
1. Проверьте формат `.avsc` файла:
   ```bash
   jq . infra/schemas/MyEvent.avsc
   ```
2. Проверьте маппинг в `register-schemas.sh`
3. Посмотрите логи в Tilt UI → `register-schemas`

### Schema Registry недоступен

**Проблема:** `Connection refused` при регистрации

**Решение:**
```bash
# Проверить статус Schema Registry
kubectl -n dev-infra get pods -l app=schema-registry

# Проверить логи
kubectl -n dev-infra logs -l app=schema-registry

# Переподнять
kubectl -n dev-infra delete pod -l app=schema-registry
```

### Версия схемы несовместима

**Проблема:** `Incompatible schema` при обновлении

**Решение:**
1. Изменения должны быть обратно совместимы (BACKWARD compatibility)
2. Можно добавлять поля с default значениями
3. Нельзя удалять обязательные поля
4. Нельзя менять типы полей

**Правильно:**
```json
{
  "fields": [
    {"name": "id", "type": "string"},
    {"name": "new_field", "type": ["null", "string"], "default": null}
  ]
}
```

**Неправильно:**
```json
{
  "fields": [
    {"name": "id", "type": "int"}  // Было string - несовместимо!
  ]
}
```

---

## 📖 Дополнительная информация

- [Avro Schema Documentation](https://avro.apache.org/docs/current/spec.html)
- [Schema Registry API](https://docs.confluent.io/platform/current/schema-registry/develop/api.html)
- [Schema Evolution Best Practices](https://docs.confluent.io/platform/current/schema-registry/avro.html)

---

## 🎓 Best Practices

### 1. Всегда используйте namespace

```json
{
  "namespace": "com.platform.events",
  "name": "BetEvent"
}
```

### 2. Добавляйте timestamp

```json
{
  "fields": [
    {"name": "timestamp", "type": "long", "doc": "Unix timestamp in milliseconds"}
  ]
}
```

### 3. Документируйте поля

```json
{
  "fields": [
    {"name": "amount", "type": "long", "doc": "Amount in cents"}
  ]
}
```

### 4. Используйте unions для optional полей

```json
{
  "fields": [
    {"name": "optional_field", "type": ["null", "string"], "default": null}
  ]
}
```

### 5. Версионируйте через namespace

```json
{
  "namespace": "com.platform.events.v2",
  "name": "BetEvent"
}
```
