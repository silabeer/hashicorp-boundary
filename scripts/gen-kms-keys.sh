#!/usr/bin/env bash
# Генерирует KMS-ключи Boundary (aes-gcm, base64/32 байта) и раскладывает их:
#   - ansible/inventory/group_vars/all/vault.yml  (root / worker-auth / recovery)
#   - terraform/recovery-kms.hcl                  (recovery-ключ для будущего Terraform)
# Если vault.yml уже существует — ключи печатаются в stdout (файл не трогаем).
set -euo pipefail
cd "$(dirname "$0")/.."

rand() { openssl rand -base64 32; }

ROOT_KEY="$(rand)"
WORKER_KEY="$(rand)"
RECOVERY_KEY="$(rand)"

VAULT_YML="ansible/inventory/group_vars/all/vault.yml"

write_recovery_hcl() {
  mkdir -p terraform
  cat > terraform/recovery-kms.hcl <<EOF
kms "aead" {
  purpose   = "recovery"
  aead_type = "aes-gcm"
  key       = "${RECOVERY_KEY}"
  key_id    = "global_recovery"
}
EOF
  chmod 600 terraform/recovery-kms.hcl
}

if [[ -f "$VAULT_YML" ]]; then
  cat <<EOF
$VAULT_YML уже существует — файл не изменён.
Добавьте/обновите ключи вручную:

boundary_kms_root_key: "${ROOT_KEY}"
boundary_kms_worker_auth_key: "${WORKER_KEY}"
boundary_kms_recovery_key: "${RECOVERY_KEY}"
EOF
else
  mkdir -p "$(dirname "$VAULT_YML")"
  cat > "$VAULT_YML" <<EOF
# Секреты Boundary. Зашифруйте: ansible-vault encrypt $VAULT_YML
boundary_kms_root_key: "${ROOT_KEY}"
boundary_kms_worker_auth_key: "${WORKER_KEY}"
boundary_kms_recovery_key: "${RECOVERY_KEY}"

# Пароль пользователя PostgreSQL (boundary_db_user).
boundary_db_password: ""

# Токен Vault с политикой для роли vault_ssh_ca_trust (чтение ssh/config/ca).
vault_token: ""

# Секрет клиента Keycloak (OIDC auth method).
keycloak_client_secret: ""

# Орфан-токен Vault для Boundary credential stores
# (политика: ssh/sign/boundary и k8s-*/creds/*).
boundary_vault_store_token: ""
EOF
  chmod 600 "$VAULT_YML"
  echo "Создан $VAULT_YML — заполните boundary_db_password/vault_token и выполните:"
  echo "  ansible-vault encrypt $VAULT_YML"
fi

write_recovery_hcl
echo "Обновлён terraform/recovery-kms.hcl (0600)"
