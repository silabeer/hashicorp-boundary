# Доступ к Kubernetes-кластерам

## Быстрый старт

```bash
./scripts/bkube prod -- get pods
./scripts/bkube prod -n kube-system -- get pods -o wide
```

`prod` — имя кластера (глобально уникальное). Токен сервисного аккаунта
Boundary получает из Vault на время сессии — kubeconfig с постоянными
правами не нужен.

## Что происходит

1. `boundary targets authorize-session` → Vault создаёт короткоживущий
   сервисный аккаунт в кластере (TTL обычно 1 час) и отдаёт его токен;
2. Boundary поднимает локальный прокси до API-сервера кластера;
3. kubectl вызывается с `--server=http://127.0.0.1:<порт>` и `--token=<SA>`.

Имя SA уникально на сессию (`v-token-...`) — действия в кластере можно
однозначно сопоставить с вашей сессией по audit log кластера.

## TLS-проверка

По умолчанию обёртка использует `--insecure-skip-tls-verify` (сертификат
API-сервера не совпадает с 127.0.0.1). Строгий вариант:

```bash
export BKUBE_CA=~/.kube/ca-prod.crt            # CA кластера (выдаёт админ)
export BKUBE_SERVER_NAME=api.prod.internal     # имя в сертификате API
./scripts/bkube prod -- get pods
```

## Интерактивные инструменты (k9s и т.п.)

```bash
boundary connect kube -target-name prod -target-scope-name prod-kubernetes -exec k9s -- -A
```

## Настройка контекста (опционально)

Если хотите ходить обычным `kubectl` без обёртки в течение сессии:

```bash
# получить токен и порт
boundary targets authorize-session -name prod -scope-name prod-kubernetes -format json | jq .
# затем как в руководстве администратора: kubectl config set-cluster / set-credentials / set-context
# (токен живёт ~1 час, сессия — до 8 часов; потом процедуру повторить)
```

Удобнее — Desktop App: кнопка Connect показывает прокси-порт и токен.

## Частые вопросы

**«Forbidden» на операциях.**
Доступ к кластеру есть (вы в группе `boundary-<env>-k8s-access`), но права
внутри кластера определяют RBAC-роль, которую выписывает Vault
(`generated_role_rules`). Если нужна другая операция — запросите у
администратора другую роль/права.

**Сессия жива до 8 часов, токен SA — обычно 1 час.** По истечении токена
запросы начнут отвечать 401 — запустите `bkube` заново.

**Аудит.** Boundary пишет факт подключения; все команды (API-запросы)
пишет audit log kube-apiserver под уникальным именем SA вашей сессии.
