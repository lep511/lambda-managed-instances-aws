#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
ENV_FILE="$SCRIPT_DIR/.env"
FUNCTION_DIR="$SCRIPT_DIR/rust-function"
FUNCTION_NAME="lmi-workshop-rust-function"

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

# ==========================================================
#  1. Load environment
# ==========================================================
load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        fail "No se encontró $ENV_FILE. Ejecuta primero: bash workshop/setup-capacity-provider.sh"
    fi
    set -a
    source "$ENV_FILE"
    set +a

    if [[ -z "${CP_ARN:-}" ]]; then
        fail "CP_ARN no está en $ENV_FILE. Ejecuta primero: bash workshop/setup-capacity-provider.sh"
    fi
    if [[ -z "${EXECUTION_ROLE_ARN:-}" ]]; then
        fail "EXECUTION_ROLE_ARN no está en $ENV_FILE"
    fi
    ok "Variables cargadas desde $ENV_FILE"
}

# ==========================================================
#  2. Create Rust project (if it doesn't exist)
# ==========================================================
create_project() {
    if [[ -f "$FUNCTION_DIR/Cargo.toml" ]]; then
        ok "Proyecto Rust ya existe en $FUNCTION_DIR"
        return 0
    fi

    info "Creando proyecto Rust en $FUNCTION_DIR..."
    mkdir -p "$FUNCTION_DIR"
    pushd "$FUNCTION_DIR" > /dev/null
    cargo init --name lmi-workshop-function
    popd > /dev/null
    ok "Proyecto creado"

    write_source_files
}

write_source_files() {
    info "Escribiendo Cargo.toml..."
    cat > "$FUNCTION_DIR/Cargo.toml" << 'TOML'
[package]
name = "lmi-workshop-function"
version = "0.2.0"
edition = "2021"

[dependencies]
lambda_runtime = { version = "1", features = ["concurrency-tokio"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["full"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }
base64 = "0.22"
rand = "0.8"
polars = { version = "0.55", features = [
    "lazy",
    "csv",
    "parquet",
    "strings",
    "performant",
    "regex",
    "timezones",
    "temporal",
] }

[profile.release]
opt-level = 3
lto = "thin"
codegen-units = 1
panic = "abort"
strip = true
TOML

    if [[ -f "$FUNCTION_DIR/src/main.rs" ]]; then
        ok "src/main.rs ya existe (procesador CSV con Polars)"
    else
        fail "src/main.rs no encontrado. El código fuente del procesador de vuelos debe estar en $FUNCTION_DIR/src/main.rs"
    fi

    ok "Código fuente verificado"
}

# ==========================================================
#  3. Build
# ==========================================================
build_function() {
    local arch
    arch=$(uname -m)

    info "Compilando función Rust para arm64 (Graviton)..."
    pushd "$FUNCTION_DIR" > /dev/null
    if [[ "$arch" == "aarch64" ]]; then
        cargo lambda build --release --output-format zip
    else
        cargo lambda build --release --output-format zip --arm64
    fi
    popd > /dev/null

    local zip_path="$FUNCTION_DIR/target/lambda/lmi-workshop-function/bootstrap.zip"
    if [[ ! -f "$zip_path" ]]; then
        fail "No se generó $zip_path"
    fi

    local size
    size=$(du -h "$zip_path" | cut -f1)
    ok "Compilación exitosa: bootstrap.zip ($size)"
}

# ==========================================================
#  4. Create or update function
# ==========================================================
deploy_function() {
    local zip_path="$FUNCTION_DIR/target/lambda/lmi-workshop-function/bootstrap.zip"

    local existing_state
    existing_state=$(aws lambda get-function \
        --function-name "$FUNCTION_NAME" \
        --query "Configuration.State" \
        --output text 2>/dev/null || echo "NOT_FOUND")

    if [[ "$existing_state" == "NOT_FOUND" ]]; then
        info "Creando función Lambda '$FUNCTION_NAME'..."
        aws lambda create-function \
            --function-name "$FUNCTION_NAME" \
            --runtime provided.al2023 \
            --handler rust.handler \
            --architectures arm64 \
            --zip-file "fileb://$zip_path" \
            --role "$EXECUTION_ROLE_ARN" \
            --memory-size 2048 \
            --timeout 120 \
            --capacity-provider-config "LambdaManagedInstancesCapacityProviderConfig={CapacityProviderArn=$CP_ARN,ExecutionEnvironmentMemoryGiBPerVCpu=2.0}" \
            --output json
        echo ""
        ok "Función creada"
    else
        info "Función '$FUNCTION_NAME' ya existe (estado: $existing_state). Actualizando código..."
        aws lambda update-function-code \
            --function-name "$FUNCTION_NAME" \
            --zip-file "fileb://$zip_path" \
            --output json > /dev/null
        ok "Código actualizado"
    fi

    info "Esperando a que la función esté lista para publicar..."
    local attempts=0
    local max_attempts=30
    while [[ $attempts -lt $max_attempts ]]; do
        local state last_update
        state=$(aws lambda get-function-configuration \
            --function-name "$FUNCTION_NAME" \
            --query "State" \
            --output text 2>/dev/null || echo "UNKNOWN")
        last_update=$(aws lambda get-function-configuration \
            --function-name "$FUNCTION_NAME" \
            --query "LastUpdateStatus" \
            --output text 2>/dev/null || echo "UNKNOWN")

        if [[ ("$state" == "Active" || "$state" == "ActiveNonInvocable") && "$last_update" == "Successful" ]]; then
            ok "Función lista (estado: $state, update: $last_update)"
            return 0
        fi

        attempts=$((attempts + 1))
        printf "  State=%s, LastUpdateStatus=%s (%d/%d) (%s)\n" "$state" "$last_update" "$attempts" "$max_attempts" "$(date +%H:%M:%S)"
        sleep 10
    done

    fail "Timeout esperando a que la función esté lista (State=$state, LastUpdateStatus=$last_update)"
}

# ==========================================================
#  5. Publish version
# ==========================================================
publish_version() {
    info "Publicando nueva versión (esto lanza instancias EC2)..."
    LMI_VERSION=$(aws lambda publish-version \
        --function-name "$FUNCTION_NAME" \
        --description "Rust LMI deployment $(date +%Y-%m-%d_%H:%M:%S)" \
        --query "Version" \
        --output text)

    ok "Versión publicada: $LMI_VERSION"
}

# ==========================================================
#  6. Wait for Active
# ==========================================================
wait_for_active() {
    local version="$1"
    local qualified="$FUNCTION_NAME:$version"

    info "Esperando a que $qualified esté Active (2-5 min)..."
    local attempts=0
    local max_attempts=24
    while [[ $attempts -lt $max_attempts ]]; do
        local state
        state=$(aws lambda get-function \
            --function-name "$qualified" \
            --query "Configuration.State" \
            --output text 2>/dev/null || echo "UNKNOWN")

        if [[ "$state" == "Active" ]]; then
            ok "$qualified está Active"
            return 0
        fi

        attempts=$((attempts + 1))
        printf "  %s... (%d/%d) (%s)\n" "$state" "$attempts" "$max_attempts" "$(date +%H:%M:%S)"
        sleep 15
    done

    fail "Timeout esperando a que la función esté Active (estado: $state)"
}

# ==========================================================
#  7. Invoke test
# ==========================================================
invoke_test() {
    local version="$1"
    local qualified="$FUNCTION_NAME:$version"
    local response_file
    response_file=$(mktemp /tmp/lmi-response-XXXXXX.json)

    info "Invocando $qualified con payload {\"generate_rows\": 5000}..."
    local status_code
    status_code=$(aws lambda invoke \
        --function-name "$qualified" \
        --payload '{"generate_rows": 5000}' \
        --cli-binary-format raw-in-base64-out \
        --query "StatusCode" \
        --output text \
        "$response_file")

    if [[ "$status_code" == "200" ]]; then
        ok "Invocación exitosa (HTTP $status_code)"
    else
        warn "Respuesta inesperada: HTTP $status_code"
    fi

    echo ""
    info "Respuesta:"
    python3 -m json.tool "$response_file" 2>/dev/null || cat "$response_file"
    rm -f "$response_file"
}

# ==========================================================
#  8. Show managed instances
# ==========================================================
show_instances() {
    echo ""
    info "Instancias EC2 gestionadas por el capacity provider:"
    aws ec2 describe-instances \
        --include-managed-resources \
        --filters "Name=tag:aws:lambda:capacity-provider,Values=*lmi-workshop-capacity-provider" \
                  "Name=instance-state-name,Values=running" \
        --query "Reservations[*].Instances[*].[InstanceId,InstanceType,State.Name,Placement.AvailabilityZone]" \
        --output table 2>/dev/null || warn "No se pudieron listar las instancias (requiere AWS CLI v2)"
}

# ==========================================================
#  9. Save version to .env
# ==========================================================
save_version() {
    local version="$1"
    if grep -q "^LMI_VERSION=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s/^LMI_VERSION=.*/LMI_VERSION=$version/" "$ENV_FILE"
    else
        echo "LMI_VERSION=$version" >> "$ENV_FILE"
    fi
    ok "LMI_VERSION=$version guardado en $ENV_FILE"
}

# ==========================================================
#  Main
# ==========================================================
echo ""
printf "${CYAN}╔══════════════════════════════════════════════════╗${NC}\n"
printf "${CYAN}║  LMI Workshop — Deploy Rust Function (Graviton) ║${NC}\n"
printf "${CYAN}╚══════════════════════════════════════════════════╝${NC}\n"
echo ""

load_env

echo ""
create_project

echo ""
build_function

echo ""
deploy_function

echo ""
publish_version

echo ""
wait_for_active "$LMI_VERSION"

echo ""
invoke_test "$LMI_VERSION"

show_instances

echo ""
save_version "$LMI_VERSION"

echo ""
ok "Deploy completo. Función Rust corriendo en Lambda Managed Instances con Graviton."
echo ""
info "Para invocar manualmente:"
echo "  source $ENV_FILE"
echo "  aws lambda invoke --function-name $FUNCTION_NAME:\$LMI_VERSION --payload '{\"generate_rows\": 50000}' --cli-binary-format raw-in-base64-out /dev/stdout"
echo ""
info "O usa el script de invocación:"
echo "  bash workshop/invoke.sh -g 50000"
