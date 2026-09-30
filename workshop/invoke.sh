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
OUTPUT_FILE="response.json"

usage() {
    cat <<EOF
Invoca la función Lambda de análisis de vuelos en LMI.

Uso:
  $(basename "$0") [opciones]

Opciones:
  -g, --generate ROWS   Generar ROWS filas sintéticas (default: 10000)
  -f, --file CSV_PATH   Enviar un archivo CSV codificado en Base64
  -n, --name NAME       Nombre de la función (default: $FUNCTION_NAME)
  -v, --version VER     Versión publicada (default: \$LMI_VERSION o 1)
  -o, --output FILE     Archivo de salida (default: $OUTPUT_FILE)
  -h, --help            Mostrar esta ayuda

Ejemplos:
  $(basename "$0") -g 50000              # 50K filas sintéticas
  $(basename "$0") -f datos.csv          # CSV propio (max ~4 MB)
  $(basename "$0") -g 100000 -v 2        # 100K filas, versión 2
EOF
    exit 0
}

GENERATE_ROWS=""
CSV_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -g|--generate) GENERATE_ROWS="$2"; shift 2 ;;
        -f|--file)     CSV_FILE="$2"; shift 2 ;;
        -n|--name)     FUNCTION_NAME="$2"; QUALIFIED="${FUNCTION_NAME}:${VERSION}"; shift 2 ;;
        -v|--version)  VERSION="$2"; QUALIFIED="${FUNCTION_NAME}:${VERSION}"; shift 2 ;;
        -o|--output)   OUTPUT_FILE="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *) echo "Opción desconocida: $1"; usage ;;
    esac
done

if [[ -n "$CSV_FILE" ]]; then
    if [[ ! -f "$CSV_FILE" ]]; then
        echo "Error: archivo no encontrado: $CSV_FILE" >&2
        exit 1
    fi

    FILE_SIZE=$(stat -c%s "$CSV_FILE" 2>/dev/null || stat -f%z "$CSV_FILE")
    MAX_CSV_SIZE=$((4 * 1024 * 1024))
    if (( FILE_SIZE > MAX_CSV_SIZE )); then
        echo "Error: el archivo ($(( FILE_SIZE / 1024 / 1024 )) MB) excede el límite de ~4 MB para payload síncrono" >&2
        exit 1
    fi

    echo "Codificando $CSV_FILE ($(( FILE_SIZE / 1024 )) KB) en Base64..."
    CSV_B64=$(base64 -w 0 < "$CSV_FILE")
    PAYLOAD="{\"csv_base64\": \"$CSV_B64\"}"
else
    ROWS="${GENERATE_ROWS:-10000}"
    PAYLOAD="{\"generate_rows\": $ROWS}"
    echo "Generando $ROWS filas sintéticas de vuelos..."
fi

echo "Invocando $QUALIFIED..."
echo ""

INVOKE_OUTPUT=$(aws lambda invoke \
    --function-name "$QUALIFIED" \
    --payload "$PAYLOAD" \
    --cli-binary-format raw-in-base64-out \
    "$OUTPUT_FILE" 2>&1)

echo "$INVOKE_OUTPUT"
echo ""

FUNCTION_ERROR=$(echo "$INVOKE_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('FunctionError',''))" 2>/dev/null || true)

if [[ -n "$FUNCTION_ERROR" ]]; then
    echo "--- ERROR en la función ---"
    python3 -m json.tool "$OUTPUT_FILE" >&2
    exit 1
else
    echo "--- Resultado ---"
    python3 -m json.tool "$OUTPUT_FILE"
fi
