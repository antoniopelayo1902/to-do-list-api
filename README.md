# to-do-list-api — Práctica 4 (CI/CD + Observabilidad)

API de tareas pendientes en FastAPI, desplegada en EC2 con Terraform, persistida en RDS PostgreSQL, con credenciales en Secrets Manager, pipeline de CI/CD en GitHub Actions y observabilidad en CloudWatch. Pensada para correr en **AWS Academy Learner Lab** (us-east-1).

| Endpoint | Descripción |
|---|---|
| `GET /tasks` | Lista las tareas |
| `POST /tasks` | Crea una tarea `{"title": "...", "done": false}` |
| `GET /version` | Versión desplegada (variable de ambiente `APP_VERSION`) |
| `GET /health` | `OK/FAIL` de la base de datos, versión y timestamp |

## Arquitectura

```
 Developer ── PR ──> GitHub Actions: ci.yml (pytest) ── bloquea merge a main si falla
     │
     └─ tag v#.#.# ──> release.yml (zip + GitHub Release) ──> deploy.yml (SSH a EC2)
                                                                    │
 provision.yml / destroy.yml ── Terraform ── state en S3            │
     │                                                               v
     v                   ┌───────────────── VPC default ─────────────────┐
  CloudWatch <─ métricas ─┤  EC2 (Ubuntu, uvicorn :8000) ──5432──> RDS   │
  (dashboard + 3 alarmas) │        │ lee credenciales                     │
       │                  │        v                                      │
       v                  │  Secrets Manager                              │
  SNS ──> correo          └───────────────────────────────────────────────┘
                     health-check.yml (cada 5 min) ──> GET /health
```

## Estructura

```
src/main.py, src/requirements.txt     app instrumentada (boto3 put_metric_data)
tests/test_main.py                    8 pruebas unitarias (DB y CloudWatch simulados)
terraform/                            main.tf, variables.tf, outputs.tf, templates/user_data.sh.tftpl
alerting/alarms.json                  configuración de las 3 alarmas (Terraform las crea desde aquí)
alerting/cloudwatch-dashboard.json    configuración del dashboard (Terraform lo crea desde aquí)
scripts/deploy_on_ec2.sh              lo que corre en la EC2 durante el deploy
scripts/set-aws-secrets.sh            copia las credenciales del lab a los secrets de GitHub
.github/workflows/                    provision, destroy, ci, release, deploy, health-check
```

## Consideraciones de Learner Lab

- No se pueden crear roles IAM: la EC2 usa el **`LabInstanceProfile`** que ya existe (tiene permisos para Secrets Manager y CloudWatch).
- Las credenciales del lab **caducan** (~4 h). Al inicio de cada sesión actualiza los secrets de GitHub con `scripts/set-aws-secrets.sh`.
- El AMI de Ubuntu se busca dinámicamente (los IDs fijos no sirven en el lab).
- Si `terraform apply` falla con la versión de PostgreSQL, revisa las disponibles en la terminal del lab:
  `aws rds describe-db-engine-versions --engine postgres --query 'DBEngineVersions[].EngineVersion'` y cambia `db_engine_version` en `terraform/variables.tf`.
- El state vive en el bucket `tfstate-<account-id>-practica04` que `provision.yml` crea si no existe (privado, versionado y cifrado). `destroy.yml` no lo borra.

## Configuración inicial (una sola vez)

1. **Repositorio público** en GitHub (user_data hace `git clone` y la EC2 descarga el zip del release sin token):
   ```bash
   cd ~/Documents/CodigoNube/Practica04
   gh repo create to-do-list-api --public --source . --remote origin --push
   ```
2. **Llave SSH para el deploy** (en tu Mac):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/practica04 -N "" -C practica04
   gh secret set EC2_SSH_PUBLIC_KEY  < ~/.ssh/practica04.pub
   gh secret set EC2_SSH_PRIVATE_KEY < ~/.ssh/practica04
   ```
3. **Token para releases** (`RELEASE_TOKEN`). Un release creado con `GITHUB_TOKEN` no dispara otros workflows, así que `deploy.yml` nunca correría. Crea un *fine-grained token* en GitHub > Settings > Developer settings > Personal access tokens, solo para este repo, con permiso **Contents: Read and write**, y guárdalo:
   ```bash
   gh secret set RELEASE_TOKEN
   ```
4. **Variables del repo**:
   ```bash
   gh variable set ALERT_EMAIL --body "tu-correo@iteso.mx"
   gh variable set SSH_ALLOWED_CIDRS --body '["0.0.0.0/0"]'
   gh variable set APP_ALLOWED_CIDRS --body '["0.0.0.0/0"]'
   ```
   > Los runners de GitHub Actions no tienen IP fija, por eso el deploy (SSH) y el health-check necesitan `0.0.0.0/0`. Eso deja el puerto 22 (solo con llave) y la API (sin autenticación) abiertos a internet mientras la infraestructura exista. RDS **no** queda expuesta: solo acepta conexiones desde el Security Group de la EC2. Destruye la infraestructura al terminar cada sesión.
5. **Proteger `main`** (Settings > Rules > Rulesets > New branch ruleset):
   - Target: default branch. Activa *Require a pull request before merging* y *Require status checks to pass*, agrega el check **`unit-tests`** (y opcionalmente `terraform-validate`). Activa *Block force pushes*.
   - El check aparece en la lista después de que el workflow CI corrió al menos una vez.

## Cada sesión del Learner Lab

1. Start Lab, abre **AWS Details > AWS CLI: Show** y corre en tu Mac: `bash scripts/set-aws-secrets.sh` (pega el bloque y Ctrl-D).
2. Actions > **Provision infrastructure** > Run workflow. Al terminar, el resumen muestra `app_url` y el link del dashboard.
3. Confirma el correo de **AWS Notification - Subscription Confirmation** (cada vez que se recrea el tópico).
4. Espera ~5-10 min a que RDS esté disponible y prueba:
   ```bash
   APP=http://<public_ip>:8000
   curl $APP/health
   curl -X POST $APP/tasks -H "Content-Type: application/json" \
     -d '{"title": "estudiar para el examen de desarrollo en la nube", "done": false}'
   curl $APP/tasks
   curl $APP/version
   ```
5. Al terminar: Actions > **Destroy infrastructure** > escribe `destroy`. Desactiva el workflow *Health check* (Actions > Health check > ⋯ > Disable workflow) mientras no haya infraestructura, para que no falle cada 5 minutos.

## CI (Pull Request)

```bash
git checkout -b feature/algo
# cambia algo
git commit -am "cambio" && git push -u origin feature/algo
gh pr create --fill
```
El PR corre `unit-tests`; si falla, el ruleset impide el merge. Para la evidencia puedes abrir un PR que rompa una prueba y ver el merge bloqueado.

## CD (release + deploy)

```bash
git checkout main && git pull
git tag v1.0.0
git push origin v1.0.0
```
1. `release.yml` corre las pruebas, crea `todo-list-api-v1.0.0.zip` con `git archive` y publica el release.
2. `deploy.yml` (on release published) busca la EC2 por su tag `Name`, entra por SSH, descarga el zip del release **en la EC2**, cambia el symlink `/opt/todo/current`, actualiza `APP_VERSION` y reinicia el servicio.
3. El mismo workflow verifica con `GET /version` que quedó corriendo `v1.0.0`.

Si recreaste la EC2, vuelve a desplegar la última versión con Actions > Deploy > Run workflow > `tag: v1.0.0`.

## Observabilidad

| Métrica | Tipo | Alarma |
|---|---|---|
| `AWS/EC2 CPUUtilization` | Nativa | Promedio > 70% en 2 periodos de 5 min |
| `TodoApp RDSErrors` | Propia (`put_metric_data`) | Sum >= 1 en 1 periodo de 1 min |
| `TodoApp PendingTasks` | Propia (`put_metric_data`) | Máximo > 20 en 1 periodo de 5 min |

El porqué de cada umbral y la acción esperada están en `alerting/alarms.json`. Las 3 alarmas notifican al tópico SNS `todo-list-api-alerts`.

**Probar la alarma de errores de RDS** (en la terminal del Learner Lab):
```bash
aws rds stop-db-instance --db-instance-identifier todo-list-api-db
# espera a que el estado sea "stopped" (~3-5 min), luego genera errores:
for i in $(seq 1 10); do curl -s http://<public_ip>:8000/health; echo; sleep 5; done
# la alarma pasa a ALARM en 1-2 min y llega el correo. Después:
aws rds start-db-instance --db-instance-identifier todo-list-api-db
```

**Probar la alarma de tareas pendientes**:
```bash
for i in $(seq 1 25); do
  curl -s -X POST http://<public_ip>:8000/tasks -H "Content-Type: application/json" -d "{\"title\": \"tarea $i\"}" > /dev/null
done
```

## Pruebas locales

```bash
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r src/requirements.txt -r tests/requirements-dev.txt
pytest -v
```

## Capturas para el reporte

1. Dashboard `todo-list-api-dashboard` en CloudWatch con las 3 gráficas.
2. Alarma `todo-list-api-rds-errors` en estado **In alarm** (y el correo de SNS).
3. El objeto `practica04/terraform.tfstate` en el bucket `tfstate-<account-id>-practica04` (S3).
4. Opcionales: corridas verdes de los 6 workflows, el PR bloqueado, el release v1.0.0 y `curl /version`.

## Troubleshooting

- La app no responde: entra por SSH (`ssh -i ~/.ssh/practica04 ubuntu@<ip>`) y revisa `sudo cat /var/log/todo-user-data.log` y `sudo journalctl -u todo-api -n 50`.
- `/health` da `FAIL` justo después del provision: RDS sigue creándose; espera unos minutos.
- `ExpiredToken` en un workflow: las credenciales del lab caducaron; corre otra vez `scripts/set-aws-secrets.sh`.
- `deploy.yml` no se dispara: falta `RELEASE_TOKEN` o el release se creó con `GITHUB_TOKEN`.
