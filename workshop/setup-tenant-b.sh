#!/usr/bin/env bash
set -euo pipefail

# Crea un segundo capacity provider (Tenant B) y despliega una función en él.
# Demuestra que capacity providers separados corren en instancias EC2 separadas.
#
# Prerequisitos:
#   - workshop/.env con SUBNET_IDS, SECURITY_GROUP_ID, OPERATOR_ROLE_ARN, EXECUTION_ROLE_ARN
#   - Capacity provider principal (lmi-workshop-capacity-provider) en estado Active

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

for var in SUBNET_IDS SECURITY_GROUP_ID OPERATOR_ROLE_ARN EXECUTION_ROLE_ARN; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var no está definida. Ejecuta setup-capacity-provider.sh primero o exporta las variables." >&2
    exit 1
  fi
done

TENANT_B_CP="lmi-workshop-tenant-b-cp"
TENANT_B_FN="lmi-workshop-tenant-b-function"

echo "=== Creando capacity provider: $TENANT_B_CP ==="
aws lambda create-capacity-provider \
  --capacity-provider-name "$TENANT_B_CP" \
  --vpc-config "SubnetIds=[$SUBNET_IDS],SecurityGroupIds=[$SECURITY_GROUP_ID]" \
  --permissions-config "CapacityProviderOperatorRoleArn=$OPERATOR_ROLE_ARN" \
  --instance-requirements "Architectures=[x86_64]" \
  --capacity-provider-scaling-config "MaxVCpuCount=16" \
  --tags Tenant=tenant-b,Environment=workshop

echo ""
echo "Esperando a que $TENANT_B_CP esté Active..."
while [[ "$(aws lambda get-capacity-provider \
  --capacity-provider-name "$TENANT_B_CP" \
  --query 'CapacityProvider.State' --output text)" != "Active" ]]; do
  echo "  Aún creando... ($(date +%H:%M:%S))"
  sleep 10
done
echo "Capacity provider $TENANT_B_CP activo."

echo ""
echo "=== Creando función: $TENANT_B_FN ==="

WORK_DIR=$(mktemp -d)
cat > "$WORK_DIR/lambda_function.py" << 'PYEOF'
import json
import time

def lambda_handler(event, context):
    count = event.get("count", 1000)
    start = time.time()
    primes = []
    for num in range(2, count):
        is_prime = True
        for i in range(2, int(num**0.5) + 1):
            if num % i == 0:
                is_prime = False
                break
        if is_prime:
            primes.append(num)
    duration = time.time() - start
    return {"statusCode": 200, "body": json.dumps({"message": "Hello from Tenant B!", "primes_found": len(primes), "duration_seconds": round(duration, 3), "request_id": context.aws_request_id})}
PYEOF

(cd "$WORK_DIR" && zip -q function.zip lambda_function.py)

TENANT_B_CP_ARN=$(aws lambda get-capacity-provider \
  --capacity-provider-name "$TENANT_B_CP" \
  --query "CapacityProvider.CapacityProviderArn" --output text)

aws lambda create-function \
  --function-name "$TENANT_B_FN" \
  --runtime python3.14 \
  --handler lambda_function.lambda_handler \
  --zip-file "fileb://$WORK_DIR/function.zip" \
  --role "$EXECUTION_ROLE_ARN" \
  --memory-size 2048 \
  --capacity-provider-config "LambdaManagedInstancesCapacityProviderConfig={CapacityProviderArn=$TENANT_B_CP_ARN,ExecutionEnvironmentMemoryGiBPerVCpu=2.0}"

rm -rf "$WORK_DIR"

echo ""
echo "=== Publicando versión ==="
TENANT_B_VERSION=$(aws lambda publish-version \
  --function-name "$TENANT_B_FN" \
  --description "Tenant B initial deployment" \
  --query "Version" --output text)

echo "Published version: $TENANT_B_VERSION"

echo ""
echo "Esperando a que $TENANT_B_FN:$TENANT_B_VERSION esté Active..."
while [[ "$(aws lambda get-function \
  --function-name "$TENANT_B_FN:$TENANT_B_VERSION" \
  --query 'Configuration.State' --output text)" != "Active" ]]; do
  echo "  Aún aprovisionando... ($(date +%H:%M:%S))"
  sleep 15
done
echo "¡Función activa!"

echo ""
echo "=== Verificando instancias separadas ==="
echo ""
echo "--- Tenant A (lmi-workshop-capacity-provider) ---"
aws ec2 describe-instances \
  --include-managed-resources \
  --filters "Name=tag:aws:lambda:capacity-provider,Values=*lmi-workshop-capacity-provider" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].[InstanceId,InstanceType]" \
  --output table

echo ""
echo "--- Tenant B ($TENANT_B_CP) ---"
aws ec2 describe-instances \
  --include-managed-resources \
  --filters "Name=tag:aws:lambda:capacity-provider,Values=*$TENANT_B_CP" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].[InstanceId,InstanceType]" \
  --output table

if [[ -f "$ENV_FILE" ]]; then
  grep -q "^TENANT_B_VERSION=" "$ENV_FILE" && \
    sed -i "s/^TENANT_B_VERSION=.*/TENANT_B_VERSION=$TENANT_B_VERSION/" "$ENV_FILE" || \
    echo "TENANT_B_VERSION=$TENANT_B_VERSION" >> "$ENV_FILE"
else
  echo "TENANT_B_VERSION=$TENANT_B_VERSION" > "$ENV_FILE"
fi

echo ""
echo "Setup completo. TENANT_B_VERSION=$TENANT_B_VERSION guardado en .env"
echo "Ejecuta 'bash workshop/demo-isolation.sh' para demostrar el aislamiento noisy-neighbor."
