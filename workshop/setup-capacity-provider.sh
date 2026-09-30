#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="$(dirname "$0")/.env"
CP_NAME="lmi-workshop-capacity-provider"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { printf "${CYAN}▶ %s${NC}\n" "$*"; }
ok()    { printf "${GREEN}✔ %s${NC}\n" "$*"; }
warn()  { printf "${YELLOW}⚠ %s${NC}\n" "$*"; }
fail()  { printf "${RED}✘ %s${NC}\n" "$*"; exit 1; }

# --- Load existing env file if present ---
load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        info "Cargando variables existentes desde $ENV_FILE"
        set -a
        source "$ENV_FILE"
        set +a
        ok "Variables cargadas"
    fi
}

# --- Prompt for a variable, showing current value as default ---
#     Re-prompts on accidental empty Enter when no default exists.
ask_var() {
    local var_name="$1"
    local prompt_text="$2"
    local current_value="${!var_name:-}"
    local max_retries=3
    local attempt=0

    while true; do
        if [[ -n "$current_value" ]]; then
            printf "${CYAN}%s${NC} [${GREEN}%s${NC}]: " "$prompt_text" "$current_value"
        else
            printf "${CYAN}%s${NC}: " "$prompt_text"
        fi

        local input
        read -r input

        if [[ -n "$input" ]]; then
            export "$var_name=$input"
            return 0
        elif [[ -n "$current_value" ]]; then
            return 0
        fi

        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_retries ]]; then
            fail "$var_name es obligatorio (sin valor tras $max_retries intentos)"
        fi
        warn "Valor vacío. $var_name es obligatorio — intenta de nuevo ($attempt/$max_retries)"
    done
}

# --- Validate that a variable is not empty ---
require_var() {
    local var_name="$1"
    if [[ -z "${!var_name:-}" ]]; then
        fail "Variable $var_name está vacía"
    fi
}

# --- Resolve subnet names to IDs if needed ---
resolve_subnet_ids() {
    local raw="$SUBNET_IDS"
    local resolved=()
    local needs_resolution=false

    IFS=',' read -ra parts <<< "$raw"
    for part in "${parts[@]}"; do
        part=$(echo "$part" | xargs)  # trim whitespace
        if [[ "$part" =~ ^subnet- ]]; then
            resolved+=("$part")
        else
            needs_resolution=true
            info "Resolviendo nombre de subnet '$part' a ID..."
            local sid
            sid=$(aws ec2 describe-subnets \
                --filters "Name=tag:Name,Values=$part" \
                --query "Subnets[0].SubnetId" \
                --output text 2>/dev/null || echo "None")
            if [[ "$sid" == "None" || "$sid" == "null" || -z "$sid" ]]; then
                fail "No se encontró subnet con nombre '$part'. Usa el ID (subnet-xxx) directamente."
            fi
            ok "  $part -> $sid"
            resolved+=("$sid")
        fi
    done

    if [[ "$needs_resolution" == true ]]; then
        SUBNET_IDS=$(IFS=','; echo "${resolved[*]}")
        ok "Subnets resueltas: $SUBNET_IDS"
    fi
}

# --- Validate resource ID formats ---
validate_formats() {
    if [[ ! "$VPC_ID" =~ ^vpc-[0-9a-f]+$ ]]; then
        fail "VPC_ID '$VPC_ID' no tiene formato válido (esperado: vpc-xxx)"
    fi

    if [[ ! "$SECURITY_GROUP_ID" =~ ^sg-[0-9a-f]+$ ]]; then
        fail "SECURITY_GROUP_ID '$SECURITY_GROUP_ID' no tiene formato válido (esperado: sg-xxx)"
    fi

    if [[ ! "$OPERATOR_ROLE_ARN" =~ ^arn:aws:iam: ]]; then
        fail "OPERATOR_ROLE_ARN no parece un ARN de IAM válido"
    fi

    if [[ ! "$EXECUTION_ROLE_ARN" =~ ^arn:aws:iam: ]]; then
        fail "EXECUTION_ROLE_ARN no parece un ARN de IAM válido"
    fi

    IFS=',' read -ra subnet_parts <<< "$SUBNET_IDS"
    for s in "${subnet_parts[@]}"; do
        if [[ ! "$s" =~ ^subnet-[0-9a-f]+$ ]]; then
            fail "Subnet '$s' no tiene formato válido (esperado: subnet-xxx)"
        fi
    done

    ok "Todos los formatos de ID son válidos"
}

# --- Save variables to .env ---
save_env() {
    cat > "$ENV_FILE" <<EOF
VPC_ID=${VPC_ID}
SUBNET_IDS=${SUBNET_IDS}
SECURITY_GROUP_ID=${SECURITY_GROUP_ID}
OPERATOR_ROLE_ARN=${OPERATOR_ROLE_ARN}
EXECUTION_ROLE_ARN=${EXECUTION_ROLE_ARN}
EOF
    chmod 600 "$ENV_FILE"
    ok "Variables guardadas en $ENV_FILE"
}

# --- Discover values from the account (best-effort) ---
discover_values() {
    info "Intentando descubrir valores de tu cuenta AWS..."

    if [[ -z "${VPC_ID:-}" ]]; then
        local detected_vpc
        detected_vpc=$(aws ec2 describe-vpcs \
            --filters "Name=tag:Name,Values=*LMI*" \
            --query "Vpcs[0].VpcId" \
            --output text 2>/dev/null || echo "None")
        if [[ "$detected_vpc" != "None" && "$detected_vpc" != "null" && -n "$detected_vpc" ]]; then
            export VPC_ID="$detected_vpc"
            ok "VPC detectada: $VPC_ID"
        fi
    fi

    if [[ -z "${SUBNET_IDS:-}" && -n "${VPC_ID:-}" ]]; then
        local detected_subnets
        detected_subnets=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=$VPC_ID" \
                      "Name=map-public-ip-on-launch,Values=false" \
            --query "Subnets[].SubnetId" \
            --output text 2>/dev/null | tr '\t' ',' || echo "")
        if [[ -n "$detected_subnets" ]]; then
            export SUBNET_IDS="$detected_subnets"
            ok "Subnets privadas detectadas: $SUBNET_IDS"
        fi
    fi

    if [[ -z "${SECURITY_GROUP_ID:-}" && -n "${VPC_ID:-}" ]]; then
        local detected_sg
        detected_sg=$(aws ec2 describe-security-groups \
            --filters "Name=vpc-id,Values=$VPC_ID" \
                      "Name=tag:Name,Values=*LMI*" \
            --query "SecurityGroups[0].GroupId" \
            --output text 2>/dev/null || echo "None")
        if [[ "$detected_sg" != "None" && "$detected_sg" != "null" && -n "$detected_sg" ]]; then
            export SECURITY_GROUP_ID="$detected_sg"
            ok "Security Group detectado: $SECURITY_GROUP_ID"
        fi
    fi

    if [[ -z "${OPERATOR_ROLE_ARN:-}" ]]; then
        local detected_op_role
        detected_op_role=$(aws iam get-role \
            --role-name LMIWorkshopOperatorRole \
            --query "Role.Arn" \
            --output text 2>/dev/null || echo "None")
        if [[ "$detected_op_role" != "None" && "$detected_op_role" != "null" && -n "$detected_op_role" ]]; then
            export OPERATOR_ROLE_ARN="$detected_op_role"
            ok "Operator Role detectado: $OPERATOR_ROLE_ARN"
        fi
    fi

    if [[ -z "${EXECUTION_ROLE_ARN:-}" ]]; then
        local detected_exec_role
        detected_exec_role=$(aws iam get-role \
            --role-name LMIWorkshopExecutionRole \
            --query "Role.Arn" \
            --output text 2>/dev/null || echo "None")
        if [[ "$detected_exec_role" != "None" && "$detected_exec_role" != "null" && -n "$detected_exec_role" ]]; then
            export EXECUTION_ROLE_ARN="$detected_exec_role"
            ok "Execution Role detectado: $EXECUTION_ROLE_ARN"
        fi
    fi
}

# --- Print summary ---
print_summary() {
    echo ""
    info "Resumen de configuración:"
    echo "  VPC_ID            = ${VPC_ID:-<vacío>}"
    echo "  SUBNET_IDS        = ${SUBNET_IDS:-<vacío>}"
    echo "  SECURITY_GROUP_ID = ${SECURITY_GROUP_ID:-<vacío>}"
    echo "  OPERATOR_ROLE_ARN = ${OPERATOR_ROLE_ARN:-<vacío>}"
    echo "  EXECUTION_ROLE_ARN= ${EXECUTION_ROLE_ARN:-<vacío>}"
    echo ""
}

# --- Create the capacity provider ---
create_capacity_provider() {
    info "Verificando si el capacity provider '$CP_NAME' ya existe..."
    local state
    state=$(aws lambda get-capacity-provider \
        --capacity-provider-name "$CP_NAME" \
        --query "CapacityProvider.State" \
        --output text 2>/dev/null || echo "NOT_FOUND")

    if [[ "$state" == "Active" ]]; then
        ok "Capacity provider '$CP_NAME' ya existe y está Active"
        return 0
    elif [[ "$state" == "Pending" ]]; then
        warn "Capacity provider '$CP_NAME' existe pero está en Pending, esperando..."
    elif [[ "$state" != "NOT_FOUND" ]]; then
        warn "Capacity provider '$CP_NAME' está en estado: $state"
        return 1
    else
        info "Creando capacity provider '$CP_NAME'..."
        aws lambda create-capacity-provider \
            --capacity-provider-name "$CP_NAME" \
            --vpc-config "SubnetIds=[$SUBNET_IDS],SecurityGroupIds=[$SECURITY_GROUP_ID]" \
            --permissions-config "CapacityProviderOperatorRoleArn=$OPERATOR_ROLE_ARN" \
            --instance-requirements "Architectures=[arm64]" \
            --capacity-provider-scaling-config "MaxVCpuCount=30" \
            --output json

        echo ""
        ok "Capacity provider creado. Esperando activación..."
    fi

    local attempts=0
    local max_attempts=12
    while [[ $attempts -lt $max_attempts ]]; do
        state=$(aws lambda get-capacity-provider \
            --capacity-provider-name "$CP_NAME" \
            --query "CapacityProvider.State" \
            --output text 2>/dev/null || echo "UNKNOWN")

        if [[ "$state" == "Active" ]]; then
            ok "Capacity provider '$CP_NAME' está Active"
            return 0
        fi

        attempts=$((attempts + 1))
        printf "  Aún en %s... (%d/%d) (%s)\n" "$state" "$attempts" "$max_attempts" "$(date +%H:%M:%S)"
        sleep 10
    done

    fail "Timeout esperando a que el capacity provider esté Active (estado: $state)"
}

# --- Export CP_ARN for downstream scripts ---
export_cp_arn() {
    local cp_arn
    cp_arn=$(aws lambda get-capacity-provider \
        --capacity-provider-name "$CP_NAME" \
        --query "CapacityProvider.CapacityProviderArn" \
        --output text)

    echo "" >> "$ENV_FILE"
    echo "CP_ARN=${cp_arn}" >> "$ENV_FILE"

    ok "CP_ARN exportado: $cp_arn"
    echo ""
    info "Para cargar las variables en tu shell actual:"
    echo "  source $ENV_FILE"
}

# ==========================================================
#  Main
# ==========================================================
echo ""
printf "${CYAN}╔══════════════════════════════════════════════════╗${NC}\n"
printf "${CYAN}║  LMI Workshop — Setup Capacity Provider (Rust)  ║${NC}\n"
printf "${CYAN}╚══════════════════════════════════════════════════╝${NC}\n"
echo ""

# 1. Load any saved values
load_env

# 2. Try auto-discovery
discover_values

# 3. Ask for each variable (pre-filled with discovered/saved values)
echo ""
info "Ingresa o confirma las variables de entorno (Enter para mantener el valor actual):"
echo ""
ask_var VPC_ID            "VPC ID (ej: vpc-0abc123)"
ask_var SUBNET_IDS        "Subnet IDs privadas separadas por coma (ej: subnet-aaa,subnet-bbb,subnet-ccc)"
ask_var SECURITY_GROUP_ID "Security Group ID (ej: sg-0xyz)"
ask_var OPERATOR_ROLE_ARN "Operator Role ARN (con política AWSLambdaManagedEC2ResourceOperator)"
ask_var EXECUTION_ROLE_ARN "Execution Role ARN (rol de ejecución de la función Lambda)"

# 4. Validate required
require_var VPC_ID
require_var SUBNET_IDS
require_var SECURITY_GROUP_ID
require_var OPERATOR_ROLE_ARN
require_var EXECUTION_ROLE_ARN

# 5. Resolve subnet names to IDs if needed
resolve_subnet_ids

# 6. Validate formats
validate_formats

# 7. Show summary and confirm
print_summary

printf "¿Continuar con estos valores? [S/n]: "
read -r confirm
if [[ "${confirm,,}" == "n" ]]; then
    warn "Cancelado por el usuario"
    exit 0
fi

# 8. Save
save_env

# 9. Create capacity provider
echo ""
create_capacity_provider

# 10. Export CP_ARN
export_cp_arn

echo ""
ok "Setup completo. El capacity provider está listo para desplegar funciones."
