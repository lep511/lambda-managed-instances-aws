#!/usr/bin/env bash
set -euo pipefail

# Elimina los recursos creados en el módulo de Multi-Tenancy y Seguridad:
#   - lmi-workshop-tenant-b-function + lmi-workshop-tenant-b-cp
#   - lmi-workshop-encrypted-function + lmi-workshop-encrypted-cp
#   - Archivos temporales de las demos
#
# NO elimina el capacity provider principal ni la función de Rust.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

echo "========================================="
echo "  Limpieza de recursos Multi-Tenancy"
echo "========================================="
echo ""

delete_function() {
  local fn_name=$1
  echo "Eliminando función: $fn_name..."
  if aws lambda get-function --function-name "$fn_name" >/dev/null 2>&1; then
    aws lambda delete-function --function-name "$fn_name"
    echo "  Eliminada."
  else
    echo "  No existe, saltando."
  fi
}

delete_capacity_provider() {
  local cp_name=$1
  echo "Eliminando capacity provider: $cp_name..."
  if aws lambda get-capacity-provider --capacity-provider-name "$cp_name" >/dev/null 2>&1; then
    aws lambda delete-capacity-provider --capacity-provider-name "$cp_name"
    echo "  Eliminado. Lambda terminará las instancias EC2 asociadas automáticamente."
  else
    echo "  No existe, saltando."
  fi
}

echo "--- Tenant B ---"
delete_function "lmi-workshop-tenant-b-function"
delete_capacity_provider "lmi-workshop-tenant-b-cp"

echo ""
echo "--- Encrypted CP ---"
delete_function "lmi-workshop-encrypted-function"
delete_capacity_provider "lmi-workshop-encrypted-cp"

echo ""
echo "--- Archivos temporales ---"
for f in tenant-b-baseline.json tenant-b-result.json tenant-a-load.json; do
  if [[ -f "$f" ]]; then
    rm -f "$f"
    echo "  Eliminado: $f"
  fi
done

if [[ -f "$ENV_FILE" ]]; then
  sed -i '/^TENANT_B_VERSION=/d' "$ENV_FILE"
  echo "  TENANT_B_VERSION eliminado de .env"
fi

echo ""
echo "========================================="
echo "  Limpieza completa."
echo ""
echo "  Recursos eliminados:"
echo "    - lmi-workshop-tenant-b-function"
echo "    - lmi-workshop-tenant-b-cp"
echo "    - lmi-workshop-encrypted-function"
echo "    - lmi-workshop-encrypted-cp"
echo ""
echo "  Recursos NO eliminados (usa cleanup.sh):"
echo "    - lmi-workshop-capacity-provider"
echo "    - lmi-workshop-rust-function"
echo "========================================="
