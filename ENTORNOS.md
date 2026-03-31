# Entornos de deploy — Thorque

Este documento explica cómo están organizados los entornos donde corre la aplicación, qué URL corresponde a cada uno y cómo se relacionan con el trabajo diario del equipo.

---

## Los tres entornos

| Entorno | Para qué sirve |
|---------|----------------|
| **dev** | Integración continua del equipo de backend. Se actualiza automáticamente con cada cambio. |
| **staging** | Validación antes de producción. El front y el back funcionan juntos como si fuera producción real. |
| **prod** | Producción. Lo que usan los clientes. Requiere aprobación manual para deployar. |

---

## Dominios por entorno

| Entorno | Backend (API) | Frontend |
|---------|--------------|----------|
| **dev** | `dev.api.thorque.io` | — *(no tiene frontend propio)* |
| **staging** | `staging.api.thorque.io` | `staging.thorque.io` |
| **prod** | `api.thorque.io` | `thorque.io` |

---

## Qué rama de GitHub dispara cada deploy

| Rama | Entorno | Backend | Frontend |
|------|---------|---------|----------|
| `dev` | Dev | Se deploya automaticamente | No se deploya |
| `staging` | Staging | Se deploya automaticamente | Se deploya automaticamente |
| `main` | Prod | Se deploya con aprobacion manual | Se deploya con aprobacion manual |

El flujo normal de trabajo es:

```
feature/xxx  →  dev  →  staging  →  main (prod)
```

Cada flecha implica un Pull Request con revisión antes de avanzar. En el paso a producción además se requiere aprobación explícita de una persona del equipo dentro de GitHub.

---

## CORS: quién puede hablar con quién

CORS es un mecanismo de seguridad que controla desde qué lugares se puede consumir la API. Cada entorno de la API solo acepta pedidos desde su frontend correspondiente.

### Durante el desarrollo del frontend

Cuando el equipo de frontend desarrolla en su computadora local, **debe apuntar su aplicación a la API de dev** (`dev.api.thorque.io`).

Si intenta hacer pedidos desde otro origen (por ejemplo, desde `localhost` apuntando a la API de staging o de prod), obtendrá un **error de CORS** y la aplicación no funcionará.

### En staging

El backend de staging (`staging.api.thorque.io`) solo acepta pedidos provenientes del frontend de staging (`staging.thorque.io`). Ambos están diseñados para funcionar juntos como un sistema cerrado.

Si alguien intenta consumir la API de staging directamente —por ejemplo, desde Postman, Insomnia, o cualquier herramienta externa— recibirá un **error de CORS** y no podrá obtener respuesta.

> Esto es intencional: staging simula producción y no está pensado para ser consumido de forma aislada.

---

## Seeders: datos de prueba

Los seeders son scripts que cargan datos de ejemplo en la base de datos (usuarios de prueba, registros iniciales, etc.).

| Entorno | Ejecuta seeders en cada deploy |
|---------|-------------------------------|
| **dev** | Sí — la base de datos se reinicia con datos frescos en cada deploy |
| **staging** | No — los datos persisten entre deploys |
| **prod** | No |

Esto significa que **dev siempre arranca con un estado conocido y predecible**, ideal para pruebas del equipo de backend. En staging, en cambio, los datos que se cargan manualmente se conservan entre versiones, lo que permite hacer pruebas más largas o flujos que requieren datos acumulados.
