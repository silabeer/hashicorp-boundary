# Доступ к базам данных

К базам вы подключаетесь через Boundary, а логин/пароль Boundary получает
автоматически из Vault: на каждую сессию создаётся **временная пара
учётных данных** (обычно TTL 1 час), привязанная к вашей роли в БД. Постоянных
паролей у вас нет и быть не должно.

## PostgreSQL

```bash
boundary connect postgres \
  -target-name prod-pg \
  -target-scope-name prod-databases \
  -dbname app
```

Команда откроет `psql`, уже залогиненного во временную учётку Vault
(`PGUSER`/`PGPASSWORD` подставляются автоматически). Любой другой клиент:

```bash
boundary connect postgres -target-name prod-pg -target-scope-name prod-databases \
  -dbname app -style psql -- -c '\l'
```

pgAdmin/DBeaver: поднимите туннель и подключитесь к localhost:

```bash
boundary connect -target-name prod-pg -target-scope-name prod-databases \
  -listen-port 15432
# DBeaver: host 127.0.0.1, port 15432, логин/пароль — из выдачи ниже
```

## MySQL

```bash
boundary connect mysql \
  -target-name prod-mysql \
  -target-scope-name prod-databases \
  -dbname app
```

## Любая другая СУБД / ручной режим

Для клиентов без встроенного хелпера получите креды и адрес прокси напрямую:

```bash
AUTHZ=$(boundary targets authorize-session -name prod-pg -scope-name prod-databases -format json)
USER=$(jq -r '.item.credentials[0].secret.decoded.username' <<<"$AUTHZ")
PASS=$(jq -r '.item.credentials[0].secret.decoded.password' <<<"$AUTHZ")
AT=$(jq -r '.item.authorization_token' <<<"$AUTHZ")

# прокси до БД (слушает 127.0.0.1:15432)
boundary connect -target-name prod-pg -target-scope-name prod-databases \
  -authz-token "$AT" -listen-port 15432 &

PGPASSWORD="$PASS" psql -h 127.0.0.1 -p 15432 -U "$USER" -d app
```

## Частые вопросы

**«У вас нет прав» / таргет не виден.**
Вы не в группе `boundary-<env>-db-access` (или в точечной группе без этой
базы). Запросите доступ у администратора.

**Подключение оборвалось посреди работы.**
У динамических кредов Vault TTL (по умолчанию 1 час) — подключитесь заново,
это нормально. Длинные миграции прогоняйте с администратором: он поднимет TTL
или выдаст отдельную роль.

**Какие права у выданной учётки?**
Те, что описаны в роли Vault (`creation_statements` в терминах
администратора): например read-only. Список привилегий — у администратора.

**Аудит.** Boundary фиксирует факт подключения (кто, когда, к какой БД).
Сами SQL-запросы Boundary не пишет — их аудит делается на стороне БД
(например, `pgaudit` в PostgreSQL); временную учётку из Vault легко найти в
логах БД по имени пользователя.
