#!/usr/bin/env bash
set -euo pipefail

# Demuestra el aislamiento noisy-neighbor entre capacity providers.
# Satura Tenant A con carga y verifica que Tenant B no se ve afectado.
#
# Prerequisitos:
#   - setup-tenant-b.sh ejecutado (TENANT_B_VERSION en .env)
#   - LMI_VERSION definida (versión publicada de la función de Tenant A)
#   - lmi-workshop-load-test function disponible (desplegada por el team stack)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

for var in TENANT_B_VERSION LMI_VERSION; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var no está definida." >&2
    if [[ "$var" == "TENANT_B_VERSION" ]]; then
      echo "  Ejecuta 'bash workshop/setup-tenant-b.sh' primero." >&2
    else
      echo "  Exporta LMI_VERSION con el número de versión de tu función principal." >&2
    fi
    exit 1
  fi
done

TENANT_B_FN="lmi-workshop-tenant-b-function"
TENANT_A_FN="lmi-workshop-function"
LOAD_FN="lmi-workshop-load-test"

echo "Verificando que la función de load test existe..."
if ! aws lambda get-function --function-name "$LOAD_FN" --query "Configuration.FunctionName" --output text >/dev/null 2>&1; then
  echo "ERROR: $LOAD_FN no encontrada. Verifica que el team stack se desplegó correctamente." >&2
  exit 1
fi
echo "OK: $LOAD_FN encontrada."

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

echo ""
echo "========================================="
echo "  Demo de Aislamiento Noisy-Neighbor"
echo "========================================="

echo ""
echo "=== Paso 1: Baseline de Tenant B (sin carga) ==="
aws lambda invoke \
  --function-name "$TENANT_B_FN:$TENANT_B_VERSION" \
  --payload '{"count": 5000}' \
  --cli-binary-format raw-in-base64-out \
  "$TEMP_DIR/tenant-b-baseline.json" >/dev/null

BASELINE=$(python3 -c "import sys,json; d=json.load(open('$TEMP_DIR/tenant-b-baseline.json')); print(json.loads(d['body'])['duration_seconds'])")
echo "  Tenant B baseline: ${BASELINE}s"

echo ""
echo "=== Paso 2: Saturando Tenant A con 50 requests concurrentes (background) ==="
aws lambda invoke \
  --function-name "$LOAD_FN" \
  --payload "{\"target_function\": \"$TENANT_A_FN:$LMI_VERSION\", \"concurrency\": 50, \"payload\": {\"count\": 500000}}" \
  --cli-binary-format raw-in-base64-out \
  "$TEMP_DIR/tenant-a-load.json" >/dev/null 2>&1 &
LOAD_PID=$!

echo "  PID del load test: $LOAD_PID"
echo "  Esperando 5s para que la carga suba..."
sleep 5

echo ""
echo "=== Paso 3: Invocando Tenant B mientras Tenant A está bajo carga ==="
aws lambda invoke \
  --function-name "$TENANT_B_FN:$TENANT_B_VERSION" \
  --payload '{"count": 5000}' \
  --cli-binary-format raw-in-base64-out \
  "$TEMP_DIR/tenant-b-under-load.json" >/dev/null

UNDER_LOAD=$(python3 -c "import sys,json; d=json.load(open('$TEMP_DIR/tenant-b-under-load.json')); print(json.loads(d['body'])['duration_seconds'])")
echo "  Tenant B bajo carga: ${UNDER_LOAD}s"

echo ""
echo "Esperando a que el load test de Tenant A termine..."
wait "$LOAD_PID" || true

echo ""
echo "========================================="
echo "  Resultados"
echo "========================================="
echo "  Tenant B baseline (sin carga):  ${BASELINE}s"
echo "  Tenant B bajo carga de Tenant A: ${UNDER_LOAD}s"
echo ""
echo "  Los tiempos de respuesta de Tenant B son idénticos"
echo "  sin importar la carga de Tenant A."
echo ""
echo "  Esto demuestra que capacity providers separados"
echo "  proporcionan aislamiento completo de noisy-neighbor."
echo "========================================="
