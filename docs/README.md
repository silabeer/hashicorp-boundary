# Доступ к инфраструктуре через Boundary — для пользователей

Boundary — это шлюз доступа: вместо VPN, bastion-хостов, раздачи SSH-ключей
и kubeconfig'ов вы входите своей корпоративной учёткой (Keycloak) и
подключаетесь к разрешённым серверам, Kubernetes-кластерам и базам.
Пароли и ключи выдаются автоматически на время сессии и нигде не хранятся.

## Что понадобится

1. **Boundary CLI**:
   - macOS: `brew tap hashicorp/tap && brew install hashicorp/tap/boundary`
   - Linux (Debian/Ubuntu):
     ```bash
     wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
     echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
     sudo apt update && sudo apt install boundary
     ```
   - Или графическое приложение **Boundary Desktop** (macOS/Windows) —
     есть кнопка Connect и показ выданных креденшелов.
2. **Адрес контроллера** — выдаёт администратор, например:
   ```bash
   export BOUNDARY_ADDR=https://boundary.example.com:9200
   ```
3. **Доступ** — ваша учётка должна быть в нужной группе Keycloak
   (`boundary-<env>-server-access`, `boundary-<env>-k8s-access`,
   `boundary-<env>-db-access` или точечной группе). Обращайтесь к
   администратору.

## Вход

```bash
# ID OIDC-метода выдаёт администратор
boundary authenticate oidc -auth-method-id <amoidc_...>
```

Откроется браузер → логин/пароль Keycloak (+ MFA) → возврат в терминал.
Токен сохраняется в системное хранилище ключей. Срок жизни токена — до 7
дней (дальше нужен повторный вход).

Посмотреть доступные вам таргеты:
```bash
boundary targets list -recursive
```
(или в Desktop App на вкладке Targets).

## Дальше

- [SSH на серверы](ssh.md)
- [Kubernetes (kubectl)](kubernetes.md)
- [Базы данных](databases.md)

## Важно понимать

- **Всё логируется**: кто, когда и куда подключился — пишется в аудит
  Boundary. Это нормально, это его работа.
- **Запрещённое не работает**: если таргета нет в вашем списке — у вас нет
  прав, запрашивайте у администратора (доступ выдаётся группой Keycloak).
- **Не передавайте** свои сессии и выданные креденшелы другим людям —
  действия в сессии атрибутируются вам.
