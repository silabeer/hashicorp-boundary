# Boundary: доступ к серверам и Kubernetes-кластерам (Ansible + GitOps)

Развёртывание и управление HashiCorp Boundary (Community Edition) целиком на
Ansible: ноды (контроллеры, воркеры) **и** доменные объекты Boundary (скоупы,
OIDC, группы, роли, хосты, таргеты, Vault-интеграция) конвергируются из git.

Модель доступа: пользователи входят по OIDC (Keycloak, MFA), Boundary
проксирует сессии и подсовывает креденшелы из Vault — SSH-сертификаты для
серверов и сервисные токены SA для Kubernetes-кластеров. Локальных ключей и
kubeconfig'ов у пользователей нет.

## GitOps-модель

Источник истины — файлы в git:

| Файл | Что описывает |
|---|---|
| `ansible/inventory/group_vars/all/domain_config.yml` | желаемое состояние Boundary: орг/проекты, OIDC, группы, роли, серверы, кластеры, пути Vault |
| `ansible/inventory/hosts.ini` | ноды: контроллеры, воркеры (с тегом сети), серверы |
| `ansible/inventory/group_vars/all/boundary.yml` | настройки нод (TLS, БД, версия) |
| `ansible/inventory/group_vars/all/vault.yml` | секреты (ansible-vault): KMS-ключи, пароль БД, токены Keycloak/Vault |

Плейбук `ansible/site.yml` идемпотентен: повторные прогоны ничего не меняют,
расхождения с конфигом конвергируются. Запуск — вручную или в CI на каждый пуш.

Изменение инфраструктуры = изменение файла в git + apply. Добавить сервер:

```yaml
# domain_config.yml
boundary_servers:
  - {name: web-02, address: 10.10.1.12, network: dc1, env: prod}
```

после apply таргет `web-02` с доступом по SSH-сертификату появляется у всех
членов группы Keycloak `boundary-prod-server-access`.

> **Ограничение v1 — нет prune.** Удаление строки из конфига НЕ удаляет объект
> в Boundary (ручные правки в UI не должны сноситься CI). Удалять объекты —
> вручную: `boundary targets delete -id ...` и т.п.

## Архитектура

```
Пользователь (CLI boundary / Desktop)
   │  OIDC + MFA (Keycloak)
   ▼
Controllers (systemd, HA) ── PostgreSQL (метаданные, без секретов)
   │  :9201
   ▼
Workers (по одному в каждой сети, тег network=<сеть>)
   ├─ SSH  : boundary connect ssh → серверы (cert из Vault SSH CA)
   └─ K8S  : boundary connect kube → API кластеров (SA-токен из Vault)
```

Доменная конфигурация применяется с первого контроллера через `boundary` CLI,
авторизация — recovery KMS (`-recovery-config /etc/boundary.d/recovery-kms.hcl`,
файл раскладывает роль контроллера). Долгоживущих админ-токенов нет.

## Структура

```
ansible/
  site.yml                     # controllers → workers → boundary_config → ssh_ca_trust
  inventory/
    hosts.ini.example
    group_vars/all/
      boundary.yml             # несекретные настройки нод
      domain_config.yml        # желаемое состояние Boundary (GitOps)
      vault.yml.example        # секреты (ansible-vault)
  roles/
    boundary_common/           # юзер, репозиторий HashiCorp, пакет, jq
    boundary_controller/       # конфиг, recovery-kms.hcl, systemd, init+migrate БД
    boundary_worker/           # конфиг с тегом network, systemd
    boundary_config/           # GitOps: конвергенция domain_config.yml через CLI
    vault_ssh_ca_trust/        # доверие Vault SSH CA на серверах
scripts/
  gen-kms-keys.sh              # ключи → vault.yml + recovery-kms.hcl
  bssh / bkube                 # пользовательские обёртки (SSH / kubectl)
vault/
  boundary-controller-policy.hcl  # политика orphan-токена для Boundary
  k8s-vault-rbac.yaml             # SA+RBAC в кластере для Vault k8s engine
```

## Развёртывание (quickstart)

Требования: ansible-core ≥ 2.15; Debian/Ubuntu или RHEL на нодах; доступные
PostgreSQL, Vault, Keycloak.

1. **Ключи и секреты**
   ```bash
   ./scripts/gen-kms-keys.sh    # создаст vault.yml с KMS-ключами
   # допишите: boundary_db_password, keycloak_client_secret,
   #           boundary_vault_store_token, (vault_token — для ssh_ca_trust)
   ansible-vault encrypt ansible/inventory/group_vars/all/vault.yml
   ```

2. **Inventory**
   ```bash
   cp ansible/inventory/hosts.ini.example ansible/inventory/hosts.ini
   # контроллеры, воркеры (hostvar network!), ssh_servers
   ```

3. **Желаемое состояние** — отредактируйте
   `ansible/inventory/group_vars/all/domain_config.yml` (Keycloak issuer,
   серверы, кластеры).

4. **TLS для API** — сертификат/ключ контроллеров в `/etc/boundary.d/tls/`
   (пути в `boundary.yml`). Стенд: `boundary_tls_enabled: false`.

5. **PostgreSQL**
   ```sql
   CREATE USER boundary WITH PASSWORD '...';
   CREATE DATABASE boundary OWNER boundary;
   ```

6. **Vault / Keycloak** — одноразовая подготовка (см. «Подготовка Vault и
   Keycloak» ниже).

7. **Apply**
   ```bash
   ansible-playbook ansible/site.yml --ask-vault-pass
   ```
   Только доменная конфигурация: `--tags boundary_config`.
   Только ноды: `--skip-tags boundary_config`.

   Пароль первоначального админа Boundary — на первом контроллере в
   `/root/boundary-initial-login.txt` (аварийный вход; постоянная работа —
   через OIDC и recovery KMS).

## Поваренная книга

### Добавить VM для SSH-доступа

1. `domain_config.yml` → `boundary_servers` += `{name, address, network, env}`
   (имя уникально в рамках env).
2. `ansible-playbook ansible/site.yml --tags boundary_config` — таргет, хост и
   сет создадутся автоматически.
3. ВМ в группу `ssh_servers` в `hosts.ini` + полный apply — роль
   `vault_ssh_ca_trust` настроит доверие SSH CA.
4. Пользователь должен быть в группе Keycloak `boundary-<env>-server-access`
   (группы/роли Boundary уже созданы, если env существует).

### Добавить Kubernetes-кластер

1. В кластере: `kubectl apply -f vault/k8s-vault-rbac.yaml`.
2. В Vault:
   ```bash
   vault secrets enable -path=k8s-<name> kubernetes
   vault write k8s-<name>/config kubernetes_host=https://<api>:6443 \
     kubernetes_ca_cert=@ca.crt service_account_jwt=@vault-sa.jwt   # kubectl create token vault -n vault
   vault write k8s-<name>/roles/developer allowed_kubernetes_namespaces="*" \
     token_default_ttl=1h generated_role_rules='{"rules":[{"apiGroups":[""],"resources":["pods"],"verbs":["list"]}]}'
   ```
   (Политика orphan-токена `k8s-*/creds/*` покрывает новый mount без правок.)
3. `domain_config.yml` → `boundary_k8s_clusters` += `{name, api_address, network, env, vault_mount, role, namespace}`.
   Имя кластера — уникально ГЛОБАЛЬНО (поиск таргета по имени без скоупа).
4. `--tags boundary_config`. Пользователи: `bkube <name>`.

### Добавить сеть (новый сегмент/площадка)

1. `hosts.ini` → `[boundary_workers]` += хост с `network=<новая сеть>`
   (можно несколько воркеров на сеть — сессии балансируются).
2. Полный apply — поднимется воркер, зарегистрируется сам (KMS worker-auth).
3. Таргеты с `network=<новая сеть>` автоматически пойдут через него
   (egress-фильтр `"<сеть>" in "/tags/network"`).

### Дать/забрать доступ к конкретным серверам

Доступ управляется **группами Keycloak** (Boundary не умеет deny — grants
аддитивны, «запретить» = не выдать доступ или убрать из группы). Два уровня:

1. **Все серверы env** — группа `boundary-<env>-server-access`
   (или `boundary-<env>-k8s-access` для кластеров).
2. **Точечно** — `boundary_access_rules` в `domain_config.yml`:

   ```yaml
   boundary_access_rules:
     - {group: boundary-prod-dba, env: prod, servers: [db-01]}
     - {group: boundary-prod-dba, env: prod, clusters: [prod]}
     - {group: boundary-prod-oncall, env: prod, servers: ['*']}
   ```

   Для каждого правила роль создаёт managed group с таким именем и роль
   Boundary с грантами `id=<tarгеты>;type=target;actions=...` — ID таргетов
   резолвятся по именам при apply, в git живут только имена.

Шаги: правило/группа → `--tags boundary_config` → назначить пользователя
в группу Keycloak. Изменения применяются при перевыпуске auth-токена
(по умолчанию TTL до 7 дней; для быстрых отзывов уменьшите
`auth_token_time_to_live` в конфиге контроллера).

### Добавить окружение (env)

Окружение = пара проектов `<env>-servers` / `<env>-kubernetes` + две группы
Keycloak + две роли. Изоляция авторизационная: staging-пользователь физически
не может сделать authorize-session на prod-таргете.

1. `domain_config.yml`: `boundary_environments += {staging: Staging}`.
2. Keycloak: создать группы `boundary-staging-server-access` и
   `boundary-staging-k8s-access`, добавить пользователей.
3. `--tags boundary_config` — роль сама создаст проекты, managed groups,
   роли, credential stores и библиотеки для нового env.
4. Наполнить `boundary_servers` / `boundary_k8s_clusters` записями с
   `env: staging`.

Граница изоляции: контроллер и Vault-сторы общие; если нужна физическая
изоляция трафика — отдельные воркеры и отдельные Vault-политики по mount'ам
(это ручной шаг за пределами текущей схемы).

## Порты и доступность

| Кто → куда | Порт | Назначение |
|---|---|---|
| Пользователи → контроллеры | 9200/tcp | API + Admin UI (TLS) |
| Воркеры → контроллеры | 9201/tcp | координация (авто-TLS) |
| Пользователи → воркеры | 9202/tcp | прокси сессий |
| Контроллеры → PostgreSQL | 5432 | БД |
| Контроллеры → Keycloak | 443/8443 | OIDC discovery + callback |
| Контроллеры и воркеры → Vault | 8200 | креденшел-сторы / SSH CA |
| Воркеры → серверы / API k8s | 22, 443... | сессии |

## Эксплуатация

- **Новый сервер/кластер**: строка в `domain_config.yml` → apply.
- **Новая сеть**: воркер в `[boundary_workers]` с `network=<сеть>` → apply;
  таргеты с этим `network` сами пойдут через него (egress-фильтр).
- **Новый пользователь/доступ**: группа в Keycloak
  (`boundary-<env>-server-access` или `boundary-<env>-k8s-access`) — Ansible
  не нужен.
- **Ротация секретов**: обновили `vault.yml` → apply (credential stores и OIDC
  метод конвергируются).
- **Апгрейд Boundary**: `boundary_version` в `boundary.yml` → apply
  (миграция БД автоматически). Для мажорных версий смотрите release notes.
- **CI** (пример, GitLab):
  ```yaml
  boundary:apply:
    script:
      - ansible-playbook ansible/site.yml --vault-password-file <(echo "$ANSIBLE_VAULT_PASS")
    rules:
      - if: $CI_COMMIT_BRANCH == "main"
    when: manual   # или on_success для полного автоматизма
  ```

## Подготовка Vault и Keycloak (одноразово)

**Keycloak** (в realm, напр. `infra`):
1. Клиент `boundary`: confidential, Direct access grants off.
2. Valid redirect URI: `https://<boundary_api_fqdn>:9200/v1/auth-methods/oidc:authenticate:callback`.
3. Маппер групп: Client scope → mapper → Group Membership, claim `groups`,
   full path off, в ID token.
4. Группы: `boundary-admins`, `boundary-server-access`, `boundary-k8s-access`.

**Vault**:
```bash
# SSH CA для серверов
vault secrets enable ssh
vault write ssh/roles/boundary key_type=ca allow_user_certificates=true \
  allowed_users="*" ttl=30m default_extensions={"permit-pty":""}

# Kubernetes-движок — по mount на каждый кластер (см. туториал HashiCorp:
# SA "vault" в кластере с ClusterRole на выдачу SA/RoleBinding'ов)
vault secrets enable -path=k8s-prod kubernetes
vault write k8s-prod/config kubernetes_host=https://<api>:6443 \
  kubernetes_ca_cert=@ca.crt service_account_jwt=@vault-sa.jwt
vault write k8s-prod/roles/developer allowed_kubernetes_namespaces="*" \
  token_default_ttl=1h generated_role_rules='{"rules":[{"apiGroups":[""],"resources":["pods"],"verbs":["list"]}]}'

# Токен для Boundary (политика: auth/token/*-self, sys/leases/renew|revoke,
# ssh/sign/boundary, k8s-*/creds/*)
vault policy write boundary-controller vault/boundary-controller-policy.hcl
vault token create -no-default-policy=true -policy=boundary-controller \
  -orphan=true -period=1h -renewable=true -format=json | jq -r .auth.client_token
```

Boundary сам продлевает store-токен; при пересоздании токена обновите
`boundary_vault_store_token` и сделайте apply.

## Ограничения Community Edition

- **Нет записи сессий** (session recording — HCP/Enterprise). Аудит событий
  есть; записи SSH-терминалов — нет.
- Ingress-фильтры воркеров — HCP-only; в Community маршрутизация — через
  egress-фильтры по тегу `network`, для схемы «воркер в каждой сети» этого
  достаточно.

## FAQ

### Аудит сессий пишется в файл?

Да. Важный нюанс: в Boundary по умолчанию `audit_enabled = false` — аудит
выключен. Контроллеры из этого репозитория настроены иначе
(`ansible/roles/boundary_controller/templates/controller.hcl.j2`):

- все события дублируются в journald (`journalctl -u boundary-controller`);
- аудит и observation-события пишутся в файл
  `/var/log/boundary/audit.ndjson` (формат cloudevents-json, ротация по
  размеру/времени — параметры `boundary_audit_*` в `boundary.yml`).

События (каждое — JSON со вложенным `data.request_info`: method, path,
client_ip, trace-id; у audit-событий есть `serialized` + `serialized_hmac`
для контроля целостности):

- **аутентификация** — audit, путь содержит `:authenticate` (кто вошёл,
  откуда client_ip);
- **авторизация сессии** — audit, путь `/v1/targets/<target_id>:authorize-session`:
  кто, когда, к какому таргету (в `response.details` — идентификаторы
  сессии/пользователя/хоста);
- **жизненный цикл сессии** — audit методов `SessionService`
  (`LookupSession`, `ActivateSession`, `AuthorizeConnection`,
  `CloseConnection`, `CancelConnection`): открытие/закрытие соединений,
  объёмы, длительность;
- **админские действия** — create/update/delete ресурсов;
- system/observation — состояние воркеров и пр.

Примеры запросов:

```bash
# Кто куда подключался (authorize-session)
jq -r 'select(.data.request_info.path // "" | contains(":authorize-session"))
  | [.time, (.data.request_info.client_ip // "-"), .data.request_info.path] | @tsv' \
  /var/log/boundary/audit.ndjson

# Логины (authenticate)
jq -r 'select(.data.request_info.path // "" | contains(":authenticate"))
  | [.time, (.data.request_info.client_ip // "-"), .data.request_info.path] | @tsv' \
  /var/log/boundary/audit.ndjson

# Жизненный цикл сессий
jq -r 'select(.data.request_info.method // "" | contains("SessionService"))
  | [.time, .data.request_info.method] | @tsv' /var/log/boundary/audit.ndjson
```

Чего в файле НЕТ: **команд и их вывода** — содержимое SSH-сеансов, SQL-запросов
и kubectl-команд Boundary не видит и не пишет. Это session recording (BSR),
фича Enterprise/HCP. «Какие команды выполнял пользователь» для SSH ищите в
auditd/sudo-логах на самих серверах (время сессии из Boundary — якорь для
корреляции), для k8s — в audit log kube-apiserver: каждая сессия ходит под
уникальным SA (`v-token-...`), так что запросы однозначно атрибутируются.

Для долгосрочного хранения забирайте ndjson fluent-bit/vector → SIEM.

### Как разрешать/запрещать доступ пользователей к разным серверам?

Только через членство в группах Keycloak — `id=*` в env-wide группах (все
серверы env) или `boundary_access_rules` (конкретные серверы/кластеры), см.
«Поваренная книга». Deny-правил в Boundary нет: доступ всегда «выдать группе»,
отзыв — исключением из группы. Один пользователь может быть в нескольких
группах, права объединяются.

### Какие учётки должны быть заведены на таргет-серверах?

Личные УЗ пользователей на серверах **не нужны**. Вход всегда под технической
учёткой `boundary_vault.ssh_user` (default: `ubuntu`): Boundary получает из
Vault SSH-сертификат с principal = этот пользователь и инжектит его в сессию.
Кто именно подключился — фиксируется в аудите Boundary (сессия привязана к
учётке Keycloak). На сервере требуется доверие Vault CA (роль
`vault_ssh_ca_trust`); техническая учётка заводится той же ролью. Для атрибуции
команд на самих серверах дополнительно включайте auditd / sudo-логирование.
В Kubernetes каждая сессия получает уникальный SA (`v-token-...`) — атрибуция
через k8s audit log.

## Пользовательская сторона

```bash
# SSH (сертификат из Vault подставляется автоматически)
./scripts/bssh prod:web-01        # или: BSSH_ENV=prod ./scripts/bssh web-01

# Kubernetes (SA-токен из Vault, прокси до API; имя — глобально уникальное)
./scripts/bkube prod -- get pods
```

Десктоп-клиенты: Boundary Desktop → логин через Keycloak → Connect к таргету;
для k8s токен показывается в UI (либо обёртка `bkube`).
