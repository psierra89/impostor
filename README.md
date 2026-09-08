# Impostor

Juego web de mesa: el celular es la carta secreta. Salas en vivo con Supabase, UI estilo Apple, deploy en Vercel.

## Stack

- Vite + HTML semántico + Tailwind CSS v4
- Vanilla JS (ES modules), `zustand/vanilla`, `zod`, `motion`
- Supabase (Postgres + RLS + Realtime + Auth)
- Vercel (frontend estático)

## Auth

- **Crear sala:** requiere **Google** (Supabase Auth).
- **Unirse:** solo apodo + código (sesión anónima **por pestaña**, en `sessionStorage`).

### Probar varios jugadores en el mismo PC

El error de ID duplicado pasaba porque la misma sesión (misma cuenta) no puede ser dos jugadores. Ahora:

1. **Pestaña 1 (host):** entrá con Google y creá la sala.
2. **Pestaña 2 / ventana de incógnito (invitado):** abrí la web, poné otro apodo y el código. Cada pestaña de invitado tiene su propia sesión anónima.

O corré el test automático:

```bash
# service_role solo en tu máquina, nunca en el repo
$env:SUPABASE_SERVICE_ROLE_KEY="eyJ..."
npm run test:multi
```

### Configurar Google en Supabase

1. En [Google Cloud Console](https://console.cloud.google.com/) creá un OAuth Client (Web).
2. Authorized redirect URI:
   - `https://gocunsnxmkhyciteqsoq.supabase.co/auth/v1/callback`
3. En Supabase → **Authentication → Providers → Google**: pegá Client ID y Secret.
4. En **Authentication → URL Configuration**:
   - Site URL: `https://impostor-tau-five.vercel.app` (y local `http://localhost:5173` en dev)
   - Redirect URLs:
     - `http://localhost:5173/**`
     - `https://impostor-tau-five.vercel.app/**`
5. Habilitá también **Anonymous** (solo para invitados que se unen).

## Límites y expiración

- Máx. **5 salas creadas / usuario Google / 24 h**
- Máx. **1 sala activa** por usuario
- Salas expiran a las **4 horas**
- Cleanup automático cada 15 min con `pg_cron` (`cleanup_expired_rooms`)
- Fallback diario en Vercel: `/api/cleanup` (requiere `SUPABASE_SERVICE_ROLE_KEY` + `CRON_SECRET`)

## Setup local

1. Copiá env:

```bash
cp .env.example .env.local
```

```
VITE_SUPABASE_URL=https://gocunsnxmkhyciteqsoq.supabase.co
VITE_SUPABASE_ANON_KEY=eyJ...
```

2. Aplicá migraciones en SQL Editor (o `npm run db:migrate` con `SUPABASE_DB_URL`):

- `supabase/migrations/202603260001_impostor_schema.sql`
- `supabase/migrations/202603260002_realtime.sql`
- `supabase/migrations/202603270001_auth_limits_expiry.sql`
- `supabase/migrations/202603270002_cleanup_cron.sql`
- `supabase/migrations/202603280001_security_min2_players.sql`
- `supabase/migrations/202603280002_themes_kick_rematch.sql`

3. App:

```bash
npm install
npm run dev
```

## Deploy

- Repo: https://github.com/psierra89/impostor
- Prod: https://impostor-tau-five.vercel.app
- Env en Vercel: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`
- Opcional cleanup API: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `CRON_SECRET`

## Cómo se juega

1. El admin entra con Google, pone apodo y crea la sala.
2. Los demás se unen con el código (sin cuenta).
3. Proponen ideas o piden del banco. Nadie ve el texto del pozo.
4. Admin inicia: 1 impostor (2–6) o 2 (7–12). Mínimo **2** jugadores.
5. Temáticas: Rosario, fútbol AR actual/histórico, mundial, marcas (con pista del tipo).
6. Cara a cara. Admin declara ganador → **Otra ronda ya** (sin lobby) o volver al lobby.

## Estructura

```
js/modules/   UI (home, sala, theme)
js/services/  Supabase + salas
js/store/     zustand/vanilla
js/schemas/   zod
api/          cleanup cron (Vercel)
supabase/migrations/
```
