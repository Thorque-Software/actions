#!/bin/bash
set -e

usage() {
    echo "Uso: $0 <nombre_bucket> <nombre_usuario>"
    exit 1
}

if [ $# -ne 2 ]; then
    usage
fi

NOMBRE_BUCKET=$1
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

# Crear bucket S3 (privado por defecto)
echo "Creando bucket S3 '$NOMBRE_BUCKET'..."
aws s3 mb "s3://$NOMBRE_BUCKET" --region sa-east-1  # Cambiar región si es necesario

# Bloquear acceso público por seguridad (opcional, pero recomendado)
aws s3api put-public-access-block --bucket "$NOMBRE_BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Crear política IAM para acceso al bucket
POLICY_NAME="acceso-s3-$NOMBRE_BUCKET"
POLICY_DOCUMENT=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket"
            ],
            "Resource": "arn:aws:s3:::$NOMBRE_BUCKET"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::$NOMBRE_BUCKET/*"
        }
    ]
}
EOF
)

# Crear política (si no existe) y adjuntarla al usuario
echo "Creando política IAM para el bucket..."
POLICY_ARN=$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "$POLICY_DOCUMENT" --query 'Policy.Arn' --output text 2>/dev/null || aws iam list-policies --scope Local --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text)

if [ -z "$POLICY_ARN" ]; then
    echo "Error: No se pudo crear o encontrar la política."
    exit 1
fi

echo "Adjuntando política al usuario '$NOMBRE_USUARIO'..."
aws iam attach-user-policy --user-name "$NOMBRE_USUARIO" --policy-arn "$POLICY_ARN"

echo "Bucket '$NOMBRE_BUCKET' creado y acceso concedido a '$NOMBRE_USUARIO'."
