# Thorque — Reusable Deploy Workflows

Colección de workflows reutilizables de GitHub Actions para desplegar aplicaciones en servidores EC2 (y similares). Cada estrategia está diseñada para distintos contextos: velocidad en desarrollo, confiabilidad en producción.

---

## Índice

- [Comparación rápida](#comparación-rápida)
- [Estrategias existentes](#estrategias-existentes)
  - [1. rsync](#1-rsync)
  - [2. Docker Compose en servidor](#2-docker-compose-en-servidor)
  - [3. ECR Deploy](#3-ecr-deploy)
- [Estrategias recomendadas](#estrategias-recomendadas)
  - [4. Docker image via SSH (sin registry)](#4-docker-image-via-ssh-sin-registry)
  - [5. GHCR Deploy](#5-ghcr-deploy)
  - [6. Blue/Green con ECR](#6-bluegreen-con-ecr)
- [Cómo usar un workflow desde otro repositorio](#cómo-usar-un-workflow-desde-otro-repositorio)
- [Actions reutilizables](#actions-reutilizables)

---

## Comparación rápida

| # | Estrategia | Archivo | Velocidad | Confiabilidad | Complejidad | Ideal para |
|---|-----------|---------|:---------:|:-------------:|:-----------:|------------|
| 1 | rsync | `rsync.yml` | ⚡⚡⚡ | ★★☆ | Baja | Dev |
| 2 | Docker Compose en servidor | `deploy.yml` | ⚡⚡☆ | ★★★ | Baja | Dev / Staging |
| 3 | ECR Deploy | `ecr-deploy.yml` | ⚡⚡☆ | ★★★★ | Media | Producción |
| 4 | Docker image via SSH | `docker-ssh-deploy.yml` | ⚡⚡⚡ | ★★★★ | Baja | Dev / Staging |
| 5 | GHCR Deploy | *(propuesto)* | ⚡⚡☆ | ★★★★ | Baja | Producción |
| 6 | Blue/Green con ECR | *(propuesto)* | ⚡☆☆ | ★★★★★ | Alta | Producción crítica |

---

## Estrategias existentes

### 1. rsync

**Archivo:** `.github/workflows/rsync.yml`

Sube archivos al servidor vía `rsync` y ejecuta un script de post-deploy por SSH. No usa Docker en el proceso de CI; el servidor se encarga de levantar la aplicación con el script que se le pase.

#### Cómo funciona

```
CI Runner
   │
   ├─ checkout
   ├─ rsync (solo los archivos modificados) ──→ EC2
   └─ SSH: ejecuta post-deploy script ──────→ EC2 (npm install, restart, etc.)
```

#### Inputs principales

| Input | Requerido | Default | Descripción |
|-------|-----------|---------|-------------|
| `host` | ✅ | — | IP del servidor |
| `user` | ✅ | — | Usuario SSH |
| `deploy-path` | ✅ | — | Ruta destino en el servidor |
| `files` | ✅ | — | Archivos a subir (separados por espacio) |
| `script` | ❌ | — | Script bash inline a ejecutar post-upload |
| `post-script-path` | ❌ | `""` | Path a un script en el repo |

#### Secrets requeridos

| Secret | Descripción |
|--------|-------------|
| `key` | Clave privada SSH |
| `env-file-content` | Contenido del `.env` |

#### Ejemplo de uso

```yaml
jobs:
  deploy:
    uses: Thorque/actions/.github/workflows/rsync.yml@main
    with:
      host: "1.2.3.4"
      user: ubuntu
      deploy-path: /home/ubuntu/app
      files: "src/ package.json package-lock.json"
      script: |
        npm ci --omit=dev
        pm2 restart app || pm2 start dist/index.js --name app
    secrets:
      key: ${{ secrets.SSH_PRIVATE_KEY }}
      env-file-content: ${{ secrets.ENV_FILE }}
```

#### ✅ Pros
- **El más rápido de todos:** rsync transfiere solo los archivos que cambiaron (diff incremental).
- Sin overhead de Docker en CI.
- Extremadamente flexible: el script de post-deploy puede hacer cualquier cosa.
- No requiere ningún servicio externo (registry, AWS, etc.).

#### ❌ Contras
- **No hay aislamiento de entorno:** el servidor necesita tener Node.js, Python, o el runtime instalado directamente.
- El entorno de producción puede divergir con el tiempo si el servidor se modifica a mano.
- Si el post-script falla a mitad, el servidor queda en estado inconsistente (sin rollback automático).
- No hay historial de imágenes deployadas.

#### Cuándo usarlo
Ideal para **servidores de desarrollo** donde la prioridad es la velocidad y el servidor se considera desechable. También útil para apps que no usan Docker (por ejemplo, un proceso Node.js gestionado por PM2).

---

### 2. Docker Compose en servidor

**Archivo:** `.github/workflows/deploy.yml`

Empaqueta los archivos fuente en un tarball, los sube al servidor vía SCP, y desde ahí el servidor construye la imagen Docker con `docker compose build` y levanta los contenedores.

#### Cómo funciona

```
CI Runner
   │
   ├─ checkout
   ├─ tar (archivos fuente) ──────────────→ EC2
   └─ SSH:
         tar -xzf
         docker compose down
         docker compose build   ← el build ocurre en el servidor
         docker compose run (migraciones)
         docker compose up -d
```

#### Inputs principales

| Input | Requerido | Default | Descripción |
|-------|-----------|---------|-------------|
| `server-ip` | ✅ | — | IP pública del servidor |
| `deploy-path` | ✅ | — | Ruta destino |
| `server-user` | ❌ | `ubuntu` | Usuario SSH |
| `deployment-files` | ❌ | `src/ migrations/ ... Dockerfile docker-compose.yml` | Archivos a incluir |
| `healthcheck-endpoint` | ❌ | `api/v1/eso` | Endpoint de healthcheck |

#### Secrets requeridos

| Secret | Descripción |
|--------|-------------|
| `ssh-private-key` | Clave privada SSH |
| `env-file-content` | Contenido del `.env` |

#### Ejemplo de uso

```yaml
jobs:
  deploy:
    uses: Thorque/actions/.github/workflows/deploy.yml@main
    with:
      server-ip: "1.2.3.4"
      deploy-path: /home/ubuntu/app
      deployment-files: "src/ package.json Dockerfile docker-compose.yml"
    secrets:
      ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}
      env-file-content: ${{ secrets.ENV_FILE }}
```

#### ✅ Pros
- No requiere un registry externo.
- Docker garantiza reproducibilidad del entorno.
- Simple de configurar: solo SSH y el servidor.
- El `docker-compose.yml` vive en el mismo repo.

#### ❌ Contras
- **El build ocurre en el servidor**, consumiendo su CPU y RAM (lento en instancias pequeñas).
- Cada deploy sube todos los archivos aunque no hayan cambiado.
- Sin caché de capas Docker entre deploys (a menos que se configure en el servidor).
- Si el servidor se cae durante el build, la aplicación queda sin servicio.
- Requiere que el servidor tenga Docker instalado y el código fuente presente.

#### Cuándo usarlo
**Staging o desarrollo** donde no se quiere configurar un registry y la instancia tiene recursos suficientes para buildear. No recomendado para producción en instancias pequeñas (t3.micro, etc.).

---

### 3. ECR Deploy

**Archivo:** `.github/workflows/ecr-deploy.yml`

Construye la imagen Docker en el runner de CI (con caché en ECR), la pushea al registry de Amazon ECR, y luego le indica al servidor EC2 que haga `docker pull` y reinicie los contenedores. Es el más robusto de los tres existentes.

#### Cómo funciona

```
CI Runner
   │
   ├─ checkout
   ├─ configure AWS credentials
   ├─ docker buildx build (con caché en ECR) ──→ ECR Registry
   ├─ scp docker-compose.yml ─────────────────→ EC2
   └─ SSH:
         aws ecr get-login-password | docker login
         docker pull (imagen ya buildeada)
         docker compose down
         [migraciones]
         [seeders]
         docker compose up -d
         [docker image prune]
```

#### Inputs principales

| Input | Requerido | Default | Descripción |
|-------|-----------|---------|-------------|
| `AWS_REGION` | ✅ | — | Región de AWS |
| `ECR_REPOSITORY` | ✅ | — | Nombre del repositorio ECR |
| `EC2_HOST` | ✅ | — | IP pública de EC2 |
| `DEPLOY_PATH` | ✅ | — | Ruta destino en EC2 |
| `dockerfile` | ❌ | `Dockerfile` | Nombre del Dockerfile |
| `build-context` | ❌ | `.` | Contexto de build |
| `image-tag` | ❌ | `latest` | Tag de la imagen |
| `COMPOSE_FILE` | ❌ | `docker-compose.yml` | Archivo compose a usar |
| `extra-files` | ❌ | `""` | Archivos adicionales a transferir (ej: `nginx/`) |
| `service-name` | ❌ | `back` | Servicio Docker para comandos |
| `run-migrations` | ❌ | `true` | Ejecutar migraciones |
| `migration-command` | ❌ | `npm run migrate` | Comando de migración |
| `run-seeders` | ❌ | `false` | Ejecutar seeders |
| `seeder-command` | ❌ | `node seeders/index.js` | Comando de seeders |
| `pre-deploy-script` | ❌ | `""` | Script bash antes del `compose up` |
| `post-deploy-script` | ❌ | `""` | Script bash después del `compose up` |
| `healthcheck-enabled` | ❌ | `true` | Activar healthcheck |
| `healthcheck-endpoint` | ❌ | `api/v1/eso` | Endpoint de healthcheck |
| `healthcheck-expected-body` | ❌ | `brad` | Cuerpo esperado |
| `healthcheck-retries` | ❌ | `10` | Reintentos del healthcheck |
| `prune-images` | ❌ | `true` | Limpiar imágenes antiguas |

#### Secrets requeridos

| Secret | Descripción |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS Access Key ID |
| `AWS_SECRET_ACCESS_KEY` | AWS Secret Access Key |
| `EC2_SSH_PRIVATE_KEY` | Clave privada SSH |
| `ENV_FILE_CONTENT` | Contenido del `.env` |

#### Ejemplo de uso

```yaml
jobs:
  deploy:
    uses: Thorque/actions/.github/workflows/ecr-deploy.yml@main
    with:
      AWS_REGION: us-east-1
      ECR_REPOSITORY: my-app-backend
      EC2_HOST: "1.2.3.4"
      DEPLOY_PATH: /home/ubuntu/app
      COMPOSE_FILE: docker-compose.prod.yml
      extra-files: "nginx/"
      run-migrations: true
      run-seeders: false
      healthcheck-endpoint: api/v1/health
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      EC2_SSH_PRIVATE_KEY: ${{ secrets.EC2_SSH_PRIVATE_KEY }}
      ENV_FILE_CONTENT: ${{ secrets.ENV_FILE }}
```

#### ✅ Pros
- **El build ocurre en CI**, no en el servidor (el servidor solo hace `docker pull`).
- Caché de capas Docker en ECR: los rebuilds incrementales son muy rápidos.
- El servidor no necesita el código fuente ni herramientas de build.
- Historial de imágenes en ECR (fácil rollback manual con `docker pull :tag`).
- Altamente configurable: migraciones, seeders, scripts custom, healthcheck.
- Las imágenes son inmutables y auditables.

#### ❌ Contras
- Requiere una cuenta AWS y configurar ECR (costo de almacenamiento de imágenes).
- Más secretos a gestionar (claves AWS + SSH).
- El servidor EC2 necesita el AWS CLI instalado y permisos de ECR.
- Si ECR no está disponible, el deploy falla (dependencia externa).
- Hay downtime entre el `compose down` y el `compose up`.

#### Cuándo usarlo
**Producción y staging** donde importa la reproducibilidad, el rendimiento del servidor y tener un historial de imágenes. Es la opción más recomendada para entornos productivos en AWS.

---

## Estrategias recomendadas

Las estrategias 5 y 6 no tienen un workflow implementado aún pero se describen con suficiente detalle para ser adoptadas.

---

### 4. Docker image via SSH (sin registry)

**Archivo:** `.github/workflows/docker-ssh-deploy.yml`

Elimina la necesidad de un registry externo manteniendo la ventaja de que el build ocurre en CI. La imagen se guarda como un archivo `.tar`, se sube al servidor por SCP y se carga con `docker load`.

#### Cómo funciona

```
CI Runner
   │
   ├─ checkout
   ├─ docker buildx build ──→ imagen local en CI (caché via GHA)
   ├─ docker save ──→ image.tar
   ├─ scp docker-compose.yml ───────────→ servidor
   ├─ scp image.tar ────────────────────→ servidor
   └─ SSH:
         docker load -i image.tar
         echo $ENV > .env
         docker compose down
         [migraciones]
         [seeders]
         docker compose up -d
         [docker image prune]
```

#### Inputs principales

| Input | Requerido | Default | Descripción |
|-------|-----------|---------|-------------|
| `image-name` | ✅ | — | Nombre local de la imagen Docker |
| `server-host` | ✅ | — | IP pública o dominio del servidor |
| `deploy-path` | ✅ | — | Ruta destino en el servidor |
| `image-tag` | ❌ | `latest` | Tag de la imagen |
| `dockerfile` | ❌ | `Dockerfile` | Nombre del Dockerfile |
| `build-context` | ❌ | `.` | Contexto de build |
| `server-user` | ❌ | `ubuntu` | Usuario SSH |
| `compose-file` | ❌ | `docker-compose.yml` | Archivo compose a usar |
| `extra-files` | ❌ | `""` | Archivos/carpetas adicionales a transferir (ej: `nginx/,config/`) |
| `service-name` | ❌ | `back` | Servicio Docker para comandos |
| `run-migrations` | ❌ | `true` | Ejecutar migraciones |
| `migration-command` | ❌ | `npm run migrate` | Comando de migración |
| `run-seeders` | ❌ | `false` | Ejecutar seeders |
| `seeder-command` | ❌ | `node seeders/index.js` | Comando de seeders |
| `pre-deploy-script` | ❌ | `""` | Script bash antes del `compose up` |
| `post-deploy-script` | ❌ | `""` | Script bash después del `compose up` |
| `healthcheck-enabled` | ❌ | `true` | Activar healthcheck |
| `healthcheck-endpoint` | ❌ | `api/v1/eso` | Endpoint de healthcheck |
| `healthcheck-expected-body` | ❌ | `brad` | Cuerpo esperado |
| `healthcheck-retries` | ❌ | `10` | Reintentos del healthcheck |
| `prune-images` | ❌ | `true` | Limpiar imágenes antiguas |

#### Secrets requeridos

| Secret | Descripción |
|--------|-------------|
| `ssh-private-key` | Clave privada SSH |
| `env-file-content` | Contenido del `.env` |

#### Ejemplo de uso

```yaml
# .github/workflows/deploy.yml en tu proyecto
name: Deploy

on:
  push:
    branches: [main]

jobs:
  # Mínimo — solo los inputs obligatorios
  deploy:
    uses: Thorque/actions/.github/workflows/docker-ssh-deploy.yml@main
    with:
      image-name: myapp
      server-host: "1.2.3.4"
      deploy-path: /home/ubuntu/app
    secrets:
      ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}
      env-file-content: ${{ secrets.ENV_FILE }}

  # Completo — configuración avanzada
  deploy-full:
    uses: Thorque/actions/.github/workflows/docker-ssh-deploy.yml@main
    with:
      image-name: myapp
      image-tag: ${{ github.sha }}        # tag por commit SHA en vez de "latest"
      dockerfile: Dockerfile.prod
      server-host: "1.2.3.4"
      server-user: ubuntu
      deploy-path: /home/ubuntu/app
      compose-file: docker-compose.prod.yml
      extra-files: "nginx/,config/"       # carpetas adicionales a transferir
      service-name: back
      run-migrations: true
      migration-command: npm run db:prod:migrate
      run-seeders: false
      pre-deploy-script: "echo 'Iniciando deploy...'"
      post-deploy-script: "echo 'Deploy finalizado!'"
      healthcheck-enabled: true
      healthcheck-endpoint: api/v1/health
      healthcheck-expected-body: brad
      healthcheck-retries: 15
      prune-images: true
    secrets:
      ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}
      env-file-content: ${{ secrets.ENV_FILE }}
```

#### ✅ Pros
- **Sin registry:** no hay costo ni dependencia de AWS/GHCR.
- El build ocurre en CI (no consume CPU del servidor).
- Entorno reproducible igual que con ECR.
- Simple de configurar: solo necesita SSH.
- Caché de capas Docker entre builds via GitHub Actions cache.

#### ❌ Contras
- Transferir una imagen `.tar` puede ser lento (100-500 MB típicamente).
- Si la imagen crece mucho, el SCP puede convertirse en el cuello de botella.
- No hay historial de imágenes (sin registry).

#### Cuándo usarlo
**Desarrollo y staging** donde no se tiene o no se quiere un registry. Es una mejora directa sobre `deploy.yml` (el build deja de ocurrir en el servidor) sin agregar complejidad de AWS.

---

### 5. GHCR Deploy

GitHub Container Registry (GHCR) es el registry de imágenes Docker propio de GitHub. Funciona igual que el ECR Deploy pero usando `ghcr.io` en lugar de AWS ECR, con autenticación via `GITHUB_TOKEN` (sin secretos adicionales).

#### Cómo funciona

```
CI Runner
   │
   ├─ checkout
   ├─ login a ghcr.io (GITHUB_TOKEN) ──→ ghcr.io/org/repo:tag
   ├─ docker buildx build + push ──────→ ghcr.io
   ├─ scp docker-compose.yml ──────────→ EC2
   └─ SSH:
         echo $GITHUB_TOKEN | docker login ghcr.io
         docker pull ghcr.io/org/repo:latest
         docker compose down
         docker compose up -d
```

#### Diferencia clave con ECR

| | ECR | GHCR |
|---|-----|------|
| Autenticación | AWS Access Key + Secret | `GITHUB_TOKEN` (automático) |
| Costo | ~$0.10/GB/mes | Gratis en repos públicos; incluido en plan GitHub |
| Retención de imágenes | Manual / lifecycle policies | Manual |
| Integración | AWS ecosystem | GitHub ecosystem |
| Permisos granulares | IAM policies | GitHub repo permissions |

#### Esquema de workflow

```yaml
# En el proyecto:
jobs:
  deploy:
    uses: Thorque/actions/.github/workflows/ghcr-deploy.yml@main
    with:
      EC2_HOST: "1.2.3.4"
      DEPLOY_PATH: /home/ubuntu/app
      image-name: my-app
    secrets:
      EC2_SSH_PRIVATE_KEY: ${{ secrets.SSH_KEY }}
      ENV_FILE_CONTENT: ${{ secrets.ENV_FILE }}
      # GITHUB_TOKEN se pasa automáticamente desde el contexto del workflow
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

#### ✅ Pros
- **Sin credenciales de AWS:** usa el `GITHUB_TOKEN` del propio workflow.
- Gratis para la mayoría de los casos de uso.
- Integrado con GitHub: las imágenes aparecen en la pestaña "Packages" del repo.
- Mismas ventajas que ECR: build en CI, caché, imágenes inmutables.
- El EC2 solo necesita Docker (no AWS CLI).

#### ❌ Contras
- Si el equipo ya está en AWS (EC2, RDS, S3), GHCR introduce una dependencia fuera del ecosistema.
- Para repos privados, el EC2 necesita un token de acceso a GHCR (PAT o deploy key).
- GitHub puede tener outages que afecten tanto al build como al pull de la imagen.

#### Cuándo usarlo
**Producción o staging** en proyectos que ya usan GitHub y quieren evitar la complejidad de AWS IAM. Es la alternativa más directa a ECR si la empresa no necesita estar atada al ecosistema AWS.

---

### 6. Blue/Green con ECR

En un deploy convencional (estrategias 1-5) siempre hay downtime entre que se baja la versión anterior y se levanta la nueva. Blue/Green elimina ese downtime manteniendo dos entornos idénticos ("blue" y "green") y un load balancer que apunta a uno u otro.

#### Cómo funciona

```
                         ┌──── EC2 Blue  (v1 — activo)
Internet ──→ Load Balancer┤
                         └──── EC2 Green (v1 — idle)

Deploy nueva versión:

1. CI buildea imagen v2 y la pushea a ECR
2. SSH al servidor Green → docker pull v2 → docker compose up
3. Healthcheck en Green ✅
4. Load balancer redirige el tráfico a Green
5. Blue queda en standby con v1 (rollback instantáneo)

                         ┌──── EC2 Blue  (v1 — standby / rollback)
Internet ──→ Load Balancer┤
                         └──── EC2 Green (v2 — activo)
```

En AWS esto puede implementarse con un **Application Load Balancer (ALB)** y dos **Target Groups**, rotando cuál está asociado al listener. El paso de "switch" se hace via AWS CLI:

```bash
aws elbv2 modify-listener \
  --listener-arn $LISTENER_ARN \
  --default-actions Type=forward,TargetGroupArn=$GREEN_TARGET_GROUP_ARN
```

#### Esquema de workflow

```yaml
# En el proyecto:
jobs:
  deploy:
    uses: Thorque/actions/.github/workflows/ecr-blue-green.yml@main
    with:
      AWS_REGION: us-east-1
      ECR_REPOSITORY: my-app-backend
      ALB_LISTENER_ARN: "arn:aws:elasticloadbalancing:..."
      BLUE_TARGET_GROUP_ARN: "arn:aws:elasticloadbalancing:...:targetgroup/blue/..."
      GREEN_TARGET_GROUP_ARN: "arn:aws:elasticloadbalancing:...:targetgroup/green/..."
      BLUE_HOST: "1.2.3.4"
      GREEN_HOST: "1.2.3.5"
      DEPLOY_PATH: /home/ubuntu/app
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      EC2_SSH_PRIVATE_KEY: ${{ secrets.SSH_KEY }}
      ENV_FILE_CONTENT: ${{ secrets.ENV_FILE }}
```

#### ✅ Pros
- **Zero downtime:** el tráfico nunca se interrumpe.
- **Rollback instantáneo:** si algo falla, basta con apuntar el load balancer de vuelta al ambiente anterior (sin necesidad de un nuevo deploy).
- El ambiente standby puede usarse para correr smoke tests con tráfico real antes del switch.
- Las migraciones se corren en el nuevo ambiente antes de recibir tráfico.

#### ❌ Contras
- **Doble costo de infraestructura:** se necesitan dos instancias EC2 corriendo.
- Significativamente más complejo de configurar y mantener (ALB, target groups, etc.).
- Las migraciones de base de datos deben ser compatibles con la versión anterior (backward-compatible) para que Blue pueda hacer rollback.
- No tiene sentido para ambientes de desarrollo.

#### Cuándo usarlo
**Producción de alta disponibilidad** donde el downtime tiene un costo real (e-commerce, SaaS con SLA, APIs críticas). No recomendado para staging ni desarrollo por el costo y la complejidad.

---

## Cómo usar un workflow desde otro repositorio

Todos los workflows son de tipo `workflow_call`, lo que significa que se invocan desde otro repositorio de la siguiente forma:

```yaml
# .github/workflows/deploy.yml en tu proyecto
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    uses: Thorque/actions/.github/workflows/ecr-deploy.yml@main
    with:
      # inputs del workflow
    secrets:
      # secrets del workflow
```

> Reemplazá `Thorque/actions` con el nombre real de la organización y el repositorio.

---

## Actions reutilizables

Además de los workflows, este repo expone composite actions que pueden usarse como steps individuales.

### `healthcheck`

**Path:** `.github/actions/healthcheck`

Verifica que un servidor responda correctamente después del deploy.

```yaml
- name: Health Check
  uses: Thorque/actions/.github/actions/healthcheck@main
  with:
    host: "1.2.3.4"          # requerido
    endpoint: "api/v1/health" # default: "eso"
    body: "ok"                # default: "brad" (vacío = solo verificar HTTP 200)
    retries: "15"             # default: "10"
```
