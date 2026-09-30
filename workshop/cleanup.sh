#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { printf "${CYAN}▶ %s${NC}\n" "$*"; }
ok()    { printf "${GREEN}✔ %s${NC}\n" "$*"; }
warn()  { printf "${YELLOW}⚠ %s${NC}\n" "$*"; }
fail()  { printf "${RED}✘ %s${NC}\n" "$*"; }

FUNCTION_NAME="lmi-workshop-rust-function"
CP_NAME="lmi-workshop-capacity-provider"

echo ""
printf "${RED}╔══════════════════════════════════════════════════╗${NC}\n"
printf "${RED}║  LMI Workshop — Cleanup (eliminar todo)         ║${NC}\n"
printf "${RED}╚══════════════════════════════════════════════════╝${NC}\n"
echo ""

read -rp "Esto eliminará la función Lambda, todas sus versiones y el capacity provider. ¿Continuar? (y/N) " confirm
[[ "$confirm" =~ ^[yYsS]$ ]] || { echo "Cancelado."; exit 0; }

echo ""

# =============================================
#  1. Eliminar versiones publicadas
# =============================================
info "Buscando versiones publicadas de $FUNCTION_NAME..."
VERSIONS=$(aws lambda list-versions-by-function \
    --function-name "$FUNCTION_NAME" \
    --query "Versions[?Version!='\$LATEST'].Version" \
    --output text 2>/dev/null || echo "")

if [[ -n "$VERSIONS" ]]; then
    for v in $VERSIONS; do
        info "  Eliminando versión $v..."
        aws lambda delete-function \
            --function-name "$FUNCTION_NAME" \
            --qualifier "$v" 2>/dev/null && ok "  Versión $v eliminada" || warn "  No se pudo eliminar versión $v"
    done
else
    ok "No hay versiones publicadas"
fi

# =============================================
#  2. Eliminar función Lambda
# =============================================
echo ""
info "Eliminando función $FUNCTION_NAME..."
if aws lambda delete-function --function-name "$FUNCTION_NAME" 2>/dev/null; then
    ok "Función eliminada"
else
    warn "Función no encontrada o ya eliminada"
fi

# =============================================
#  3. Esperar a que las instancias se terminen
# =============================================
echo ""
info "Esperando a que las instancias EC2 gestionadas se terminen..."
for i in $(seq 1 12); do
    COUNT=$(aws ec2 describe-instances \
        --include-managed-resources \
        --filters "Name=tag:aws:lambda:capacity-provider,Values=*$CP_NAME" \
                  "Name=instance-state-name,Values=running,pending,shutting-down,stopping" \
        --query "length(Reservations[*].Instances[*][])" \
        --output text 2>/dev/null || echo "0")

    if [[ "$COUNT" == "0" ]]; then
        ok "No hay instancias activas"
        break
    fi

    echo "  $COUNT instancia(s) aún activas... ($i/12) ($(date +%H:%M:%S))"
    sleep 15
done

# =============================================
#  4. Eliminar capacity provider
# =============================================
echo ""
info "Eliminando capacity provider $CP_NAME..."
if aws lambda delete-capacity-provider --capacity-provider-name "$CP_NAME" 2>/dev/null; then
    ok "Capacity provider eliminado"
else
    warn "Capacity provider no encontrado o ya eliminado"
fi

# =============================================
#  5. Verificación final
# =============================================
echo ""
info "Verificación final..."

FUNC_CHECK=$(aws lambda get-function --function-name "$FUNCTION_NAME" 2>&1 || true)
if echo "$FUNC_CHECK" | grep -q "ResourceNotFoundException"; then
    ok "Función: no existe"
else
    warn "Función: aún podría existir"
fi

CP_CHECK=$(aws lambda get-capacity-provider --capacity-provider-name "$CP_NAME" 2>&1 || true)
if echo "$CP_CHECK" | grep -q "ResourceNotFoundException"; then
    ok "Capacity provider: no existe"
else
    CP_STATE=$(echo "$CP_CHECK" | python3 -c "import sys,json; print(json.load(sys.stdin)['CapacityProvider']['State'])" 2>/dev/null || echo "desconocido")
    warn "Capacity provider: estado $CP_STATE (puede tardar unos minutos en eliminarse)"
fi

INSTANCES=$(aws ec2 describe-instances \
    --include-managed-resources \
    --filters "Name=tag:aws:lambda:capacity-provider,Values=*$CP_NAME" \
              "Name=instance-state-name,Values=running" \
    --query "length(Reservations[*].Instances[*][])" \
    --output text 2>/dev/null || echo "0")
if [[ "$INSTANCES" == "0" ]]; then
    ok "Instancias EC2: ninguna corriendo"
else
    warn "Instancias EC2: $INSTANCES aún corriendo (se terminarán automáticamente)"
fi

# =============================================
#  6. Limpiar variables de deploy del .env
# =============================================
echo ""
if [[ -f "$ENV_FILE" ]]; then
    info "Limpiando variables de deploy de $ENV_FILE..."
    sed -i '/^LMI_VERSION=/d' "$ENV_FILE"
    sed -i '/^CP_ARN=/d' "$ENV_FILE"
    ok ".env conservado (se eliminaron LMI_VERSION y CP_ARN)"
fi

echo ""
ok "Cleanup completado."
echo ""
info "Si las instancias aún aparecen, espera unos minutos y verifica con:"
echo "  aws ec2 describe-instances --include-managed-resources \\"
echo "    --filters \"Name=tag:aws:lambda:capacity-provider,Values=*$CP_NAME\" \\"
echo "              \"Name=instance-state-name,Values=running\" \\"
echo "    --query \"Reservations[*].Instances[*].[InstanceId,State.Name]\" --output table"
