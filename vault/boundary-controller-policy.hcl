# Политика для orphan-токена, которым Boundary ходит в Vault (credential stores).
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
path "auth/token/revoke-self" {
  capabilities = ["update"]
}
path "sys/leases/renew" {
  capabilities = ["update"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
path "sys/capabilities-self" {
  capabilities = ["update"]
}

# SSH-сертификаты для серверов (роль boundary в SSH-движке)
path "ssh/sign/boundary" {
  capabilities = ["update"]
}

# SA-токены Kubernetes (по mount'у на каждый кластер, см. domain_config.yml)
path "k8s-*/creds/*" {
  capabilities = ["update"]
}
