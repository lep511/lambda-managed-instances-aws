#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
fi

FUNCTION_NAME="lmi-workshop-rust-function"
VERSION="${LMI_VERSION:-1}"
QUALIFIED="${FUNCTION_NAME}:${VERSION}"
ROWS_PER_INVOCATION=2000000
CONCURRENCY=5
OUTPUT_DIR="/tmp/lmi-parallel-$$"

usage() {
    cat <<EOF
Invoca la función Lambda en paralelo, cada invocación con 2M filas.

Uso:
  $(basename "$0") [opciones]

Opciones:
  -c, --concurrency N   Invocaciones en paralelo (default: $CONCURRENCY)
  -r, --rows ROWS       Filas por invocación (default: $ROWS_PER_INVOCATION)
  -v, --version VER     Versión publicada (default: \$LMI_VERSION o 1)
  -h, --help            Mostrar esta ayuda

Ejemplos:
  $(basename "$0")                  # 5 invocaciones x 2M = 10M filas
  $(basename "$0") -c 10            # 10 invocaciones x 2M = 20M filas
  $(basename "$0") -c 8 -r 5000000  # 8 invocaciones x 5M = 40M filas
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--concurrency) CONCURRENCY="$2"; shift 2 ;;
        -r|--rows)        ROWS_PER_INVOCATION="$2"; shift 2 ;;
        -v|--version)     VERSION="$2"; QUALIFIED="${FUNCTION_NAME}:${VERSION}"; shift 2 ;;
        -h|--help)        usage ;;
        *) echo "Opción desconocida: $1"; usage ;;
    esac
done

mkdir -p "$OUTPUT_DIR"
TOTAL_ROWS=$(( ROWS_PER_INVOCATION * CONCURRENCY ))

echo "============================================"
echo "  Prueba de carga paralela — Lambda LMI"
echo "============================================"
echo "Función:       $QUALIFIED"
echo "Invocaciones:  $CONCURRENCY"
echo "Filas/inv:     $(printf "%'d" $ROWS_PER_INVOCATION)"
echo "Total filas:   $(printf "%'d" $TOTAL_ROWS)"
echo "============================================"
echo ""

invoke_one() {
    local id=$1
    local outfile="$OUTPUT_DIR/response-${id}.json"
    local logfile="$OUTPUT_DIR/log-${id}.txt"
    local start_ts end_ts elapsed

    start_ts=$(date +%s%3N)

    local invoke_out
    local invoke_rc=0
    invoke_out=$(aws lambda invoke \
        --function-name "$QUALIFIED" \
        --payload "{\"generate_rows\": $ROWS_PER_INVOCATION}" \
        --cli-binary-format raw-in-base64-out \
        "$outfile" 2>&1) || invoke_rc=$?

    end_ts=$(date +%s%3N)
    elapsed=$(( end_ts - start_ts ))

    if [[ $invoke_rc -ne 0 ]]; then
        local err_msg
        err_msg=$(echo "$invoke_out" | grep -oP '(TooManyRequestsException|Throttl|error|Error).*' | head -1)
        echo "  [#${id}] FAIL   ${elapsed}ms — ${err_msg:-CLI exit code $invoke_rc}" | tee "$logfile"
        echo "$invoke_out" >> "$logfile"
        return 1
    fi

    local func_error
    func_error=$(echo "$invoke_out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('FunctionError',''))" 2>/dev/null || true)

    if [[ -n "$func_error" ]]; then
        local err_type
        err_type=$(python3 -c "import json; print(json.load(open('$outfile')).get('errorType','unknown'))" 2>/dev/null || echo "unknown")
        echo "  [#${id}] ERROR  ${elapsed}ms — $err_type" | tee "$logfile"
        echo "$invoke_out" >> "$logfile"
        return 1
    else
        local durations
        durations=$(python3 -c "
import json
d=json.load(open('$outfile'))
p=d.get('processing',{})
print(p.get('load_duration_seconds', '?'), d.get('total_duration_seconds', '?'))
" 2>/dev/null || echo "? ?")
        local load_s total_s
        read -r load_s total_s <<< "$durations"
        echo "  [#${id}] OK     ${elapsed}ms cliente, ${total_s}s función (carga ${load_s}s)" | tee "$logfile"
        return 0
    fi
}

export -f invoke_one
export QUALIFIED ROWS_PER_INVOCATION OUTPUT_DIR

echo "Lanzando $CONCURRENCY invocaciones..."
echo ""

GLOBAL_START=$(date +%s%3N)

PIDS=()
for i in $(seq 1 "$CONCURRENCY"); do
    invoke_one "$i" &
    PIDS+=($!)
done

SUCCEEDED=0
FAILED=0
for pid in "${PIDS[@]}"; do
    if wait "$pid"; then
        SUCCEEDED=$(( SUCCEEDED + 1 ))
    else
        FAILED=$(( FAILED + 1 ))
    fi
done

GLOBAL_END=$(date +%s%3N)
GLOBAL_ELAPSED=$(( GLOBAL_END - GLOBAL_START ))

echo ""
echo "============================================"
echo "  Resumen"
echo "============================================"
echo "Tiempo total:  ${GLOBAL_ELAPSED}ms"
echo "Exitosas:      $SUCCEEDED / $CONCURRENCY"
echo "Fallidas:      $FAILED / $CONCURRENCY"
echo "Throughput:    $(printf "%'d" $(( TOTAL_ROWS * 1000 / (GLOBAL_ELAPSED + 1) ))) filas/seg"
echo "============================================"

if (( FAILED > 0 )); then
    echo ""
    echo "--- Detalle de errores ---"
    for i in $(seq 1 "$CONCURRENCY"); do
        local_log="$OUTPUT_DIR/log-${i}.txt"
        local_resp="$OUTPUT_DIR/response-${i}.json"
        if [[ -f "$local_log" ]] && grep -qE "FAIL|ERROR" "$local_log" 2>/dev/null; then
            cat "$local_log"
            if [[ -f "$local_resp" ]] && grep -q "errorType" "$local_resp" 2>/dev/null; then
                echo "         $(cat "$local_resp")"
            fi
        fi
    done
fi

echo ""
echo "Respuestas guardadas en: $OUTPUT_DIR/"
