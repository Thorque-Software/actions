#!/bin/bash
set -e

usage() {
    echo "Uso: $0 <nombre_usuario>"
    exit 1
}

if [ $# -ne 1 ]; then
    usage
fi

NOMBRE_USUARIO=$1

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

# Crear claves de acceso
echo "Creando claves de acceso para el usuario '$NOMBRE_USUARIO'..."
RESULTADO=$(aws iam create-access-key --user-name "$NOMBRE_USUARIO" --output json)

ACCESS_KEY_ID=$(echo "$RESULTADO" | jq -r '.AccessKey.AccessKeyId')
SECRET_ACCESS_KEY=$(echo "$RESULTADO" | jq -r '.AccessKey.SecretAccessKey')

echo ""
echo "=================================================="
echo "CLAVES DE ACCESO GENERADAS (GUÁRDALAS SEGURAS):"
echo "=================================================="
echo "AccessKeyId: $ACCESS_KEY_ID"
echo "SecretAccessKey: $SECRET_ACCESS_KEY"
echo "=================================================="
echo ""
echo "IMPORTANTE: El SecretAccessKey solo se muestra esta vez."
echo "Puedes configurar el perfil de AWS CLI para este usuario ejecutando:"
echo "  aws configure --profile $NOMBRE_USUARIO"
echo "Y proporcionando las claves mostradas arriba."
