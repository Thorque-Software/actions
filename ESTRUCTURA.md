# Estructura de Deploy — Thorque Software

## Visión general

```
thorque-backend/   ← repo Node.js/TypeScript (API REST)
thorque-frontend/  ← repo Next.js
thorque-actions/   ← este repo (workflows y actions reutilizables)
```

Tres entornos:

| Entorno | Backend | Frontend | Trigger | Estrategia de deploy |
|---------|---------|----------|---------|----------------------|
| **dev** | EC2 pequeña (t3.micro) | — | push a `dev` | **rsync** — máxima velocidad, sin overhead de Docker |
| **staging** | EC2 mediana (t3.small) | EC2 mediana (t3.small) | push a `staging` | **Docker image via SSH** — build en CI, sin registry externo |
| **prod** | EC2/ECS (según escala) | EC2/Vercel | PR merged a `main` con aprobación manual | **ECR Deploy** — build incremental con caché, historial de imágenes, rollback |

---

## 1. Ramas Git

### Backend y Frontend (misma convención)

```
main        ← producción. Solo se toca via PR desde staging.
staging     ← entorno de staging. PR desde dev.
dev         ← integración. Commits directos o PR desde feature branches.
feat/*      ← features individuales. PR a dev.
fix/*       ← bugfixes. PR a dev (o a staging si es hotfix).
```

**Reglas de protección recomendadas (GitHub Branch Protection):**
- `main`: require PR + 1 aprobación + status checks verdes. No push directo.
- `staging`: require status checks verdes. No push directo.
- `dev`: push directo permitido para agilidad.

---

## 2. Estructura de repositorios

### `thorque-backend/`

```
thorque-backend/
├── src/
├── migrations/
├── seeders/
├── index.ts
├── app.ts
├── drizzle.config.prod.ts
├── package.json
├── tsconfig.json
├── Dockerfile                    ← imagen de producción/staging
├── Dockerfile.dev                ← imagen para dev (con hot reload)
├── docker-compose.dev.yml        ← stack local de desarrollo
├── docker-compose.staging.yml    ← stack staging (back + nginx)
├── docker-compose.prod.yml       ← stack producción
├── .env.example                  ← plantilla de variables (sin valores reales)
└── .github/
    └── workflows/
        ├── deploy-dev.yml        ← se dispara en push a dev
        ├── deploy-staging.yml    ← se dispara en push a staging
        └── deploy-prod.yml       ← se dispara en push a main (con aprobación)
```

### `thorque-frontend/`

```
thorque-frontend/
├── src/
├── public/
├── next.config.ts
├── package.json
├── tsconfig.json
├── Dockerfile                    ← imagen Next.js standalone
├── .env.example
└── .github/
    └── workflows/
        ├── deploy-staging.yml    ← se dispara en push a staging
        └── deploy-prod.yml       ← se dispara en push a main
```

### `thorque-actions/` (este repo)

```
thorque-actions/
├── .github/
│   └── workflows/
│       ├── deploy.yml            ← workflow reutilizable: build + ssh + docker
│       ├── rsync.yml             ← workflow reutilizable: rsync simple
│       └── healthcheck.yml       ← workflow reutilizable: health check
├── scripts/
│   └── aws/
│       ├── create_user.sh
│       ├── create_keys.sh
│       ├── create_ecr.sh
│       ├── create_bucket.sh
│       └── create_cloud_watch.sh
└── ESTRUCTURA.md
```

---

## 3. Dockerfiles

### `Dockerfile` (backend — staging/prod)

```dockerfile
FROM node:22-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./
EXPOSE 3000
CMD ["node", "dist/index.js"]
```

### `Dockerfile.dev` (backend — dev con hot reload)

```dockerfile
FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
EXPOSE 3000
CMD ["npm", "run", "dev"]
```

### `Dockerfile` (frontend — staging/prod, Next.js standalone)

```dockerfile
FROM node:22-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
ARG NEXT_PUBLIC_API_URL
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL
RUN npm run build

FROM node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
EXPOSE 3001
CMD ["node", "server.js"]
```

> Requiere `output: 'standalone'` en `next.config.ts`.

---

## 4. Docker Compose por entorno

### `docker-compose.dev.yml` (backend — corre en el servidor dev)

```yaml
services:
  back:
    image: thorque-back:latest      # imagen cargada por el CI via docker load
    env_file: .env
    restart: unless-stopped
    networks:
      - app

  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
    volumes:
      - ./nginx/dev.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - back
    restart: unless-stopped
    networks:
      - app

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
    volumes:
      - db_data:/var/lib/postgresql/data
    networks:
      - app

networks:
  app:
    driver: bridge

volumes:
  db_data:
```

**`nginx/dev.conf`** (en el repo del backend):

```nginx
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://back:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

> Sin SSL en dev. El puerto 80 queda expuesto en la EC2 (abrir en el Security Group). El backend no expone ningún puerto directamente, solo es accesible a través de nginx dentro de la red Docker.

### `docker-compose.staging.yml` (back + front en el mismo servidor)

```yaml
services:
  back:
    build:
      context: ./back
      dockerfile: Dockerfile
    env_file: ./back/.env
    restart: unless-stopped
    networks:
      - app

  front:
    build:
      context: ./front
      dockerfile: Dockerfile
      args:
        NEXT_PUBLIC_API_URL: ${NEXT_PUBLIC_API_URL}
    restart: unless-stopped
    networks:
      - app

  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/staging.conf:/etc/nginx/conf.d/default.conf
      - ./certs:/etc/nginx/certs          # Let's Encrypt / cert manual
    depends_on:
      - back
      - front
    networks:
      - app

networks:
  app:
    driver: bridge
```

> Este `docker-compose.staging.yml` vive en el **servidor de staging**, no en ningún repo. El CI lo genera o lo sube como artefacto. Ver sección 5.

### `docker-compose.prod.yml`

Misma estructura que staging pero con réplicas, límites de memoria y logging a CloudWatch.

---

## 5. GitHub Actions Workflows

### Backend — `deploy-dev.yml` (estrategia: rsync)

```yaml
# thorque-backend/.github/workflows/deploy-dev.yml
name: Deploy Dev

on:
  push:
    branches: [dev]

jobs:
  deploy:
    uses: thorque-software/thorque-actions/.github/workflows/rsync.yml@main
    with:
      host: ${{ vars.DEV_SERVER_IP }}
      user: ubuntu
      deploy-path: /home/ubuntu/thorque-back
      files: "src/ migrations/ seeders/ index.ts app.ts drizzle.config.prod.ts package.json tsconfig.json Dockerfile.dev docker-compose.dev.yml"
      script: |
        docker compose -f docker-compose.dev.yml down
        docker compose -f docker-compose.dev.yml up -d --build
        docker compose -f docker-compose.dev.yml run back npm run db:migrate
    secrets:
      key: ${{ secrets.DEV_SSH_KEY }}
      env-file-content: ${{ secrets.DEV_ENV }}
```

> rsync transfiere solo los archivos modificados → deploys en segundos. El build del Dockerfile.dev ocurre en el servidor, pero en dev eso es aceptable dado que la instancia es desechable y la velocidad de CI importa más que el consumo de CPU.

### Backend — `deploy-staging.yml` (estrategia: Docker image via SSH)

```yaml
# thorque-backend/.github/workflows/deploy-staging.yml
name: Deploy Staging (Backend)

on:
  push:
    branches: [staging]

jobs:
  deploy:
    uses: thorque-software/thorque-actions/.github/workflows/docker-ssh-deploy.yml@main
    with:
      image-name: thorque-back
      server-host: ${{ vars.STAGING_SERVER_IP }}
      deploy-path: /home/ubuntu/staging/back
      compose-file: docker-compose.staging.yml
      service-name: back
      run-migrations: true
      migration-command: npm run db:prod:migrate
      healthcheck-endpoint: api/v1/health
    secrets:
      ssh-private-key: ${{ secrets.STAGING_SSH_KEY }}
      env-file-content: ${{ secrets.STAGING_BACK_ENV }}
```

### Frontend — `deploy-staging.yml` (estrategia: Docker image via SSH)

```yaml
# thorque-frontend/.github/workflows/deploy-staging.yml
name: Deploy Staging (Frontend)

on:
  push:
    branches: [staging]

jobs:
  deploy:
    uses: thorque-software/thorque-actions/.github/workflows/docker-ssh-deploy.yml@main
    with:
      image-name: thorque-front
      server-host: ${{ vars.STAGING_SERVER_IP }}
      deploy-path: /home/ubuntu/staging/front
      compose-file: docker-compose.staging.yml
      service-name: front
      run-migrations: false
      healthcheck-endpoint: api/health
    secrets:
      ssh-private-key: ${{ secrets.STAGING_SSH_KEY }}
      env-file-content: ${{ secrets.STAGING_FRONT_ENV }}
```

> El build ocurre en el runner de CI (no consume CPU de la t3.small). La imagen se envía como `.tar` por SCP. Sin necesidad de configurar ECR ni credenciales AWS para staging.

### Prod — con aprobación manual (estrategia: ECR Deploy)

```yaml
# thorque-backend/.github/workflows/deploy-prod.yml
name: Deploy Prod (Backend)

on:
  push:
    branches: [main]

jobs:
  deploy:
    environment: production          # ← requiere aprobación en GitHub Environments
    uses: thorque-software/thorque-actions/.github/workflows/ecr-deploy.yml@main
    with:
      AWS_REGION: us-east-1
      ECR_REPOSITORY: thorque-back
      EC2_HOST: ${{ vars.PROD_SERVER_IP }}
      DEPLOY_PATH: /home/ubuntu/prod/back
      COMPOSE_FILE: docker-compose.prod.yml
      service-name: back
      run-migrations: true
      migration-command: npm run db:prod:migrate
      healthcheck-endpoint: api/v1/health
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.PROD_AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.PROD_AWS_SECRET_ACCESS_KEY }}
      EC2_SSH_PRIVATE_KEY: ${{ secrets.PROD_SSH_KEY }}
      ENV_FILE_CONTENT: ${{ secrets.PROD_BACK_ENV }}
```

> Build incremental con caché en ECR: el servidor solo hace `docker pull`. Historial de imágenes por SHA para rollback manual. El `environment: production` bloquea el deploy hasta que un aprobador lo confirme en GitHub.

---

## 6. Secrets y Variables en GitHub

Configurar en cada repo bajo **Settings → Secrets and variables → Actions**:

### Variables (no sensibles, visibles en logs)
| Variable | Dev | Staging | Prod |
|----------|-----|---------|------|
| `DEV_SERVER_IP` | IP del servidor dev | — | — |
| `STAGING_SERVER_IP` | — | IP del servidor staging | — |
| `PROD_SERVER_IP` | — | — | IP del servidor prod |

### Secrets (sensibles)
| Secret | Descripción |
|--------|-------------|
| `DEV_SSH_KEY` | Clave privada EC2 dev |
| `STAGING_SSH_KEY` | Clave privada EC2 staging |
| `PROD_SSH_KEY` | Clave privada EC2 prod |
| `DEV_ENV` | Contenido completo del `.env` de dev |
| `STAGING_BACK_ENV` | `.env` del backend en staging |
| `STAGING_FRONT_ENV` | `.env` del frontend en staging |
| `PROD_BACK_ENV` | `.env` del backend en prod |
| `PROD_FRONT_ENV` | `.env` del frontend en prod |

---

## 7. Infraestructura AWS

### Por entorno

| Recurso | Dev | Staging | Prod |
|---------|-----|---------|------|
| EC2 | t3.micro (1 instancia) | t3.small (1 instancia) | t3.medium+ o ECS |
| RDS / DB | PostgreSQL en Docker | PostgreSQL en Docker o RDS micro | RDS (Multi-AZ recomendado) |
| SSL | — o self-signed | Let's Encrypt (Certbot) | ACM + ALB |
| Dominio | `dev.api.thorque.io` | `staging.api.thorque.io` / `staging.thorque.io` | `api.thorque.io` / `thorque.io` |
| ECR | Opcional | Opcional | Recomendado para cachear imágenes |

### Scripts de setup (ya en este repo)

```bash
# Crear usuario IAM con permisos mínimos
./scripts/aws/create_user.sh

# Crear par de claves SSH para cada entorno
./scripts/aws/create_keys.sh dev
./scripts/aws/create_keys.sh staging
./scripts/aws/create_keys.sh prod

# Crear bucket S3 para assets/backups
./scripts/aws/create_bucket.sh thorque-staging

# Crear ECR para imágenes Docker (opcional pero recomendado para prod)
./scripts/aws/create_ecr.sh thorque-back
./scripts/aws/create_ecr.sh thorque-front

# Crear alarmas CloudWatch
./scripts/aws/create_cloud_watch.sh
```

---

## 8. Setup rápido de un entorno nuevo

### Dev (5 minutos)

1. Levantar EC2 t3.micro con Ubuntu 24.04, abrir puertos 22 y 3000.
2. Instalar Docker en la instancia: `sudo apt install docker.io docker-compose-plugin -y`
3. Agregar el secret `DEV_SSH_KEY` y `DEV_ENV` en el repo backend.
4. Agregar la variable `DEV_SERVER_IP` en el repo backend.
5. Hacer push a `dev` → el workflow sube el código y levanta el contenedor automáticamente.

### Staging (15 minutos)

1. Levantar EC2 t3.small con Ubuntu 24.04, abrir puertos 22, 80 y 443.
2. Instalar Docker, Nginx y Certbot.
3. Configurar DNS: `staging.api.thorque.io` y `staging.thorque.io` apuntando a la IP.
4. Obtener certificados: `certbot --nginx -d staging.api.thorque.io -d staging.thorque.io`
5. Crear estructura de carpetas:
   ```bash
   mkdir -p /home/ubuntu/staging/{back,front,nginx}
   ```
6. Subir el `docker-compose.staging.yml` y `nginx/staging.conf` a `/home/ubuntu/staging/`.
7. Agregar los secrets y variables de staging en ambos repos (back y front).
8. Push a `staging` en cada repo → los workflows construyen y despliegan independientemente.

---

## 9. Flujo completo de trabajo

```
feat/nueva-feature
        │
        ▼ PR
       dev  ──── push ──→ [CI] deploy-dev.yml → EC2 dev (backend solo)
        │
        ▼ PR + review
     staging ──── push ──→ [CI] deploy-staging.yml (back) → EC2 staging
                      └──→ [CI] deploy-staging.yml (front) → EC2 staging
        │
        ▼ PR + aprobación
      main  ──── push ──→ [CI] deploy-prod.yml (back) → [APROBACIÓN MANUAL] → EC2 prod
                     └──→ [CI] deploy-prod.yml (front) → [APROBACIÓN MANUAL] → EC2 prod
```

---

## 10. Nginx — configuración staging

```nginx
# /home/ubuntu/staging/nginx/staging.conf

server {
    listen 80;
    server_name staging.api.thorque.io staging.thorque.io;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name staging.api.thorque.io;

    ssl_certificate     /etc/nginx/certs/staging.api.thorque.io/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/staging.api.thorque.io/privkey.pem;

    location / {
        proxy_pass http://back:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}

server {
    listen 443 ssl;
    server_name staging.thorque.io;

    ssl_certificate     /etc/nginx/certs/staging.thorque.io/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/staging.thorque.io/privkey.pem;

    location / {
        proxy_pass http://front:3001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

---

## 11. Checklist de implementación

- [ ] Crear las ramas `dev`, `staging`, `main` en ambos repos con branch protection
- [ ] Definir `output: 'standalone'` en `next.config.ts` del frontend
- [ ] Agregar endpoint `/api/health` en backend y frontend para healthchecks
- [ ] Levantar EC2 dev y configurar secrets en repo backend
- [ ] Levantar EC2 staging y configurar secrets en ambos repos
- [ ] Subir `docker-compose.staging.yml` y `nginx/staging.conf` al servidor staging
- [ ] Configurar DNS para los subdominios de staging
- [ ] Habilitar **GitHub Environments** con aprobación manual para `production`
- [ ] Ejecutar scripts de AWS para crear usuarios IAM, claves y CloudWatch
- [ ] Hacer primer push de prueba a `dev` y verificar que el CI despliega correctamente
