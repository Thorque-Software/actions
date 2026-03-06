#!/bin/bash
set -e

usage() {
    echo "Uso: $0 <nombre_log_group> <nombre_usuario>"
    exit 1
}

if [ $# -ne 2 ]; then
    usage
fi

NOMBRE_LOG_GROUP=$1
NOMBRE_USUARIO=$2

# Verificar AWS CLI
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI no está instalado."
    exit 1
fi

# Verificar que el usuario existe
if ! aws iam get-user --user-name "$NOMBRE_USUARIO" &> /dev/null; then
    echo "Error: El usuario '$NOMBRE_USUARIO' no existe."
    exit 1
fi

# Crear el grupo de logs
echo "Creando grupo de logs '$NOMBRE_LOG_GROUP'..."
aws logs create-log-group --log-group-name "$NOMBRE_LOG_GROUP"

# Crear política IAM para acceso al grupo de logs
POLICY_NAME="acceso-logs-$NOMBRE_LOG_GROUP"
# Reemplazar caracteres no válidos para nombre de política (solo letras, números, +=,.@_-)
POLICY_NAME=$(echo "$POLICY_NAME" | sed 's/[^a-zA-Z0-9+=,.@_-]/-/g')

POLICY_DOCUMENT=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogStream",
                "logs:PutLogEvents",
                "logs:DescribeLogStreams"
            ],
            "Resource": "arn:aws:logs:*:*:log-group:$NOMBRE_LOG_GROUP:*"
        }
    ]
}
EOF
)

# Crear política (si no existe) y adjuntarla al usuario
echo "Creando política IAM para el grupo de logs..."
POLICY_ARN=$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "$POLICY_DOCUMENT" --query 'Policy.Arn' --output text 2>/dev/null || aws iam list-policies --scope Local --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text)

if [ -z "$POLICY_ARN" ]; then
    echo "Error: No se pudo crear o encontrar la política."
    exit 1
fi

echo "Adjuntando política al usuario '$NOMBRE_USUARIO'..."
aws iam attach-user-policy --user-name "$NOMBRE_USUARIO" --policy-arn "$POLICY_ARN"

echo "Grupo de logs '$NOMBRE_LOG_GROUP' creado y acceso concedido a '$NOMBRE_USUARIO'."
