#!/usr/bin/env bash
set -euo pipefail

# Crea un capacity provider con encriptación KMS para volúmenes EBS,
# despliega una función y verifica que los volúmenes estén encriptados.
#
# Prerequisitos:
#   - workshop/.env con SUBNET_IDS, SECURITY_GROUP_ID, OPERATOR_ROLE_ARN, EXECUTION_ROLE_ARN
#   - Llave KMS: alias/lmi-workshop-ebs-key en estado Enabled

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

ENCRYPTED_CP="lmi-workshop-encrypted-cp"
ENCRYPTED_FN="lmi-workshop-encrypted-function"

echo "=== Verificando llave KMS ==="
KMS_KEY_ARN=$(aws kms describe-key \
  --key-id alias/lmi-workshop-ebs-key \
  --query "KeyMetadata.Arn" --output text 2>/dev/null) || true

if [[ -z "$KMS_KEY_ARN" || "$KMS_KEY_ARN" == "None" ]]; then
  echo "ERROR: No se encontró la llave KMS alias/lmi-workshop-ebs-key." >&2
  echo "  Verifica que la infraestructura del workshop fue desplegada correctamente." >&2
  exit 1
fi

echo "KMS Key ARN: $KMS_KEY_ARN"
aws kms describe-key \
  --key-id alias/lmi-workshop-ebs-key \
  --query "KeyMetadata.[KeyId,KeyState,Description]" \
  --output table

echo ""
echo "=== Creando capacity provider encriptado: $ENCRYPTED_CP ==="
aws lambda create-capacity-provider \
  --capacity-provider-name "$ENCRYPTED_CP" \
  --vpc-config "SubnetIds=[$SUBNET_IDS],SecurityGroupIds=[$SECURITY_GROUP_ID]" \
  --permissions-config "CapacityProviderOperatorRoleArn=$OPERATOR_ROLE_ARN" \
  --instance-requirements "Architectures=[x86_64]" \
  --capacity-provider-scaling-config "MaxVCpuCount=16" \
  --kms-key-arn "$KMS_KEY_ARN"

echo ""
echo "Esperando a que $ENCRYPTED_CP esté Active..."
while [[ "$(aws lambda get-capacity-provider \
  --capacity-provider-name "$ENCRYPTED_CP" \
  --query 'CapacityProvider.State' --output text)" != "Active" ]]; do
  echo "  Aún creando... ($(date +%H:%M:%S))"
  sleep 10
done

echo ""
echo "Verificando KMS en el capacity provider:"
aws lambda get-capacity-provider \
  --capacity-provider-name "$ENCRYPTED_CP" \
  --query "CapacityProvider.[State,KmsKeyArn]" \
  --output table

echo ""
echo "=== Desplegando función en el provider encriptado ==="

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
    return {"statusCode": 200, "body": json.dumps({"message": "Hello from the encrypted capacity provider!", "primes_found": len(primes), "duration_seconds": round(duration, 3), "request_id": context.aws_request_id})}
PYEOF

(cd "$WORK_DIR" && zip -q function.zip lambda_function.py)

ENCRYPTED_CP_ARN=$(aws lambda get-capacity-provider \
  --capacity-provider-name "$ENCRYPTED_CP" \
  --query "CapacityProvider.CapacityProviderArn" --output text)

aws lambda create-function \
  --function-name "$ENCRYPTED_FN" \
  --runtime python3.14 \
  --handler lambda_function.lambda_handler \
  --zip-file "fileb://$WORK_DIR/function.zip" \
  --role "$EXECUTION_ROLE_ARN" \
  --memory-size 2048 \
  --capacity-provider-config "LambdaManagedInstancesCapacityProviderConfig={CapacityProviderArn=$ENCRYPTED_CP_ARN,ExecutionEnvironmentMemoryGiBPerVCpu=2.0}"

rm -rf "$WORK_DIR"

echo ""
echo "=== Publicando versión ==="
aws lambda publish-version \
  --function-name "$ENCRYPTED_FN"

echo ""
echo "Esperando a que $ENCRYPTED_FN:1 esté Active..."
while [[ "$(aws lambda get-function \
  --function-name "$ENCRYPTED_FN:1" \
  --query 'Configuration.State' --output text)" != "Active" ]]; do
  echo "  Aún aprovisionando... ($(date +%H:%M:%S))"
  sleep 15
done
echo "¡Función activa!"

echo ""
echo "=== Verificando volúmenes EBS encriptados ==="
echo "(Esperando 60s para que las instancias reciban sus tags...)"
sleep 60

INSTANCE_IDS=$(aws ec2 describe-instances \
  --include-managed-resources \
  --filters "Name=tag:aws:lambda:capacity-provider,Values=*$ENCRYPTED_CP" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].InstanceId" \
  --output text)

if [[ -z "$INSTANCE_IDS" ]]; then
  echo "AVISO: No se encontraron instancias aún. Espera 1-2 minutos y ejecuta:"
  echo "  aws ec2 describe-instances --include-managed-resources \\"
  echo "    --filters \"Name=tag:aws:lambda:capacity-provider,Values=*$ENCRYPTED_CP\" \\"
  echo "              \"Name=instance-state-name,Values=running\" \\"
  echo "    --query \"Reservations[*].Instances[*].InstanceId\" --output text"
else
  for INSTANCE_ID in $INSTANCE_IDS; do
    echo ""
    echo "Instance: $INSTANCE_ID"
    aws ec2 describe-volumes \
      --include-managed-resources \
      --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
      --query "Volumes[*].[VolumeId,Encrypted,KmsKeyId]" \
      --output table
  done
fi

echo ""
echo "Setup de capacity provider encriptado completo."
echo "Los volúmenes de datos muestran Encrypted=True con tu CMK."
