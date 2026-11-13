#!/usr/bin/env bash
# Copia las credenciales temporales del Learner Lab a los secrets del repo en GitHub.
# Córrelo en tu Mac (dentro del repo) al inicio de cada sesión del lab. Requiere `gh auth login`.
# Uso: bash scripts/set-aws-secrets.sh  -> pega el bloque "AWS CLI" de AWS Details y presiona Ctrl-D.
set -euo pipefail

echo "Pega el bloque [default] de AWS Details > AWS CLI y presiona Ctrl-D:"
BLOCK=$(cat)

get() { printf '%s\n' "$BLOCK" | grep -i "^$1" | head -1 | cut -d= -f2- | tr -d '[:space:]'; }

KEY_ID=$(get aws_access_key_id)
SECRET=$(get aws_secret_access_key)
TOKEN=$(get aws_session_token)

if [ -z "$KEY_ID" ] || [ -z "$SECRET" ] || [ -z "$TOKEN" ]; then
  echo "No encontré las 3 credenciales en el texto pegado." >&2
  exit 1
fi

printf '%s' "$KEY_ID" | gh secret set AWS_ACCESS_KEY_ID
printf '%s' "$SECRET" | gh secret set AWS_SECRET_ACCESS_KEY
printf '%s' "$TOKEN"  | gh secret set AWS_SESSION_TOKEN
echo "Listo: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY y AWS_SESSION_TOKEN actualizados."
