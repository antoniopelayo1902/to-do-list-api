#!/usr/bin/env bash
# Corre EN LA EC2 (lo invoca deploy.yml por SSH): descarga el zip del release, cambia de versión y reinicia.
set -euo pipefail

TAG="$1"
REPO="$2"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Tag inválido: $TAG"; exit 1; }
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Repo inválido: $REPO"; exit 1; }

# Si la instancia es nueva, espera a que user_data termine antes de tocar nada.
cloud-init status --wait >/dev/null 2>&1 || true

APP_DIR=/opt/todo
RELEASE_DIR="$APP_DIR/releases/$TAG"
ZIP="/tmp/todo-list-api-$TAG.zip"
URL="https://github.com/$REPO/releases/download/$TAG/todo-list-api-$TAG.zip"

echo "Descargando $URL"
curl -fsSL --retry 5 --retry-delay 3 -o "$ZIP" "$URL"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
unzip -q "$ZIP" -d "$RELEASE_DIR"
rm -f "$ZIP"

"$APP_DIR/venv/bin/pip" install --quiet -r "$RELEASE_DIR/src/requirements.txt"

ln -sfn "$RELEASE_DIR" "$APP_DIR/current"
sed -i "s/^APP_VERSION=.*/APP_VERSION=$TAG/" /etc/todo-api.env
chown -R ubuntu:ubuntu "$APP_DIR"
systemctl restart todo-api

# Conserva solo los últimos 3 releases.
ls -1dt "$APP_DIR"/releases/v* 2>/dev/null | tail -n +4 | xargs -r rm -rf

echo "Deploy de $TAG terminado"
