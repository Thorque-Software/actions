#!/bin/bash
set -e  # Detener ejecución si ocurre un error

# Función para mostrar uso
usage() {
    echo "Uso: $0 <nombre_usuario>"
    exit 1
}

# Verificar argumentos
if [ $# -ne 1 ]; then
    usage
fi

NOMBRE_USUARIO=$1

# Verificar si AWS CLI está instalado
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI no está instalado."
    exit 1
fi

# Verificar si el usuario ya existe
if aws iam get-user --user-name "$NOMBRE_USUARIO" &> /dev/null; then
    echo "El usuario '$NOMBRE_USUARIO' ya existe."
else
    # Crear el usuario IAM
    echo "Creando usuario IAM '$NOMBRE_USUARIO'..."
    aws iam create-user --user-name "$NOMBRE_USUARIO"
    echo "Usuario creado exitosamente."
fi

# Mostrar ARN del usuario
ARN_USUARIO=$(aws iam get-user --user-name "$NOMBRE_USUARIO" --query 'User.Arn' --output text)
echo "ARN del usuario: $ARN_USUARIO"
