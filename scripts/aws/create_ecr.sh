#!/bin/bash
set -e

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Uso: $0 <nombre_repositorio> <nombre_usuario> [region]"
    echo "  region: Opcional, por defecto usa la región configurada en AWS CLI"
    exit 1
}

# Verificar argumentos
if [ $# -lt 2 ]; then
    usage
fi

REPO_NAME=$1
USER_NAME=$2
REGION=${3:-$(aws configure get region)}

# Verificar AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI no está instalado.${NC}"
    exit 1
fi

# Verificar que el usuario existe
if ! aws iam get-user --user-name "$USER_NAME" &> /dev/null; then
    echo -e "${RED}Error: El usuario '$USER_NAME' no existe.${NC}"
    exit 1
fi

# Verificar que la región está definida
if [ -z "$REGION" ]; then
    echo -e "${RED}Error: No se pudo determinar la región. Especifícala como tercer argumento.${NC}"
    exit 1
fi

echo -e "${GREEN}Usando región: $REGION${NC}"

# Crear repositorio ECR (si no existe)
echo -e "${YELLOW}Verificando si el repositorio '$REPO_NAME' ya existe...${NC}"
if aws ecr describe-repositories --repository-names "$REPO_NAME" --region "$REGION" &> /dev/null; then
    echo -e "${GREEN}El repositorio '$REPO_NAME' ya existe.${NC}"
else
    echo -e "${YELLOW}Creando repositorio ECR '$REPO_NAME'...${NC}"
    aws ecr create-repository --repository-name "$REPO_NAME" --region "$REGION"
    echo -e "${GREEN}Repositorio creado exitosamente.${NC}"
fi

# Obtener URI del repositorio
REPO_URI=$(aws ecr describe-repositories --repository-names "$REPO_NAME" --region "$REGION" --query 'repositories[0].repositoryUri' --output text)
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
REPO_ARN="arn:aws:ecr:$REGION:$ACCOUNT_ID:repository/$REPO_NAME"

echo -e "URI del repositorio: ${GREEN}$REPO_URI${NC}"

# Crear política IAM para acceso al repositorio
POLICY_NAME="acceso-ecr-$REPO_NAME"
# Limpiar nombre de política (solo caracteres válidos)
POLICY_NAME=$(echo "$POLICY_NAME" | sed 's/[^a-zA-Z0-9+=,.@_-]/-/g')

POLICY_DOCUMENT=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
    {
        "Effect": "Allow",
        "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
        "ecr:DescribeRepositories",
        "ecr:ListImages"
        ],
        "Resource": "*"
    },
{
    "Effect": "Allow",
    "Action": [
    "ecr:BatchGetImage",
    "ecr:BatchCheckLayerAvailability",
    "ecr:CompleteLayerUpload",
    "ecr:GetDownloadUrlForLayer",
    "ecr:InitiateLayerUpload",
    "ecr:PutImage",
    "ecr:UploadLayerPart",
    "ecr:DescribeRepositories",
    "ecr:ListImages",
    "ecr:DeleteRepository",
    "ecr:BatchDeleteImage"
    ],
    "Resource": "$REPO_ARN"
}
]
}
EOF
)

echo -e "${YELLOW}Creando política IAM...${NC}"

# Intentar crear la política; si ya existe, obtener su ARN
POLICY_ARN=$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "$POLICY_DOCUMENT" --query 'Policy.Arn' --output text 2>/dev/null || aws iam list-policies --scope Local --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text)

if [ -z "$POLICY_ARN" ]; then
    echo -e "${RED}Error: No se pudo crear ni encontrar la política.${NC}"
    exit 1
fi

echo -e "${GREEN}Política ARN: $POLICY_ARN${NC}"

# Adjuntar política al usuario
echo -e "${YELLOW}Adjuntando política al usuario '$USER_NAME'...${NC}"
if aws iam attach-user-policy --user-name "$USER_NAME" --policy-arn "$POLICY_ARN"; then
    echo -e "${GREEN}Política adjuntada exitosamente.${NC}"
else
    echo -e "${RED}Error al adjuntar la política.${NC}"
    exit 1
fi

# Instrucciones finales
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Configuración completada exitosamente${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Para iniciar sesión en ECR y probar el acceso, ejecuta:"
echo -e "  ${YELLOW}aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com${NC}"
echo ""
echo -e "Para construir y subir una imagen de prueba:"
echo -e "  ${YELLOW}docker pull nginx:latest${NC}"
echo -e "  ${YELLOW}docker tag nginx:latest $REPO_URI:test${NC}"
echo -e "  ${YELLOW}docker push $REPO_URI:test${NC}"
echo ""
echo -e "Para verificar que el usuario '$USER_NAME' tiene permisos, puedes usar sus credenciales para ejecutar los comandos anteriores."
