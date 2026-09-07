# Impostor

Juego web de mesa: el celular es la carta secreta. Salas en vivo con Supabase, UI estilo Apple, deploy en Vercel.

## Stack

- Vite + HTML semántico + Tailwind CSS v4
- Vanilla JS (ES modules), `zustand/vanilla`, `zod`, `motion`
- Supabase (Postgres + RLS + Realtime + Anonymous Auth)
- Vercel (frontend estático)

## Setup local

> Si el proyecto de Supabase está **pausado** (capa gratuita), abrilo en el [dashboard](https://supabase.com/dashboard/project/gocunsnxmkhyciteqsoq) y tocá **Restore** antes de migrar.

1. **Supabase**
   - URL del proyecto: `https://gocunsnxmkhyciteqsoq.supabase.co`
   - En **Authentication → Providers**, habilitá **Anonymous Sign-Ins**.
   - En **SQL Editor**, corré en orden:
     - [`supabase/migrations/202603260001_impostor_schema.sql`](supabase/migrations/202603260001_impostor_schema.sql)
     - [`supabase/migrations/202603260002_realtime.sql`](supabase/migrations/202603260002_realtime.sql)
   - Alternativa con connection string (Database → URI):
     ```bash
     $env:SUPABASE_DB_URL="postgresql://postgres:...@db.gocunsnxmkhyciteqsoq.supabase.co:5432/postgres"
     npm run db:migrate
     ```
   - En **Project Settings → API**, copiá la key `anon` `public` a `.env.local`.

2. **Env**

```bash
cp .env.example .env.local
```

```
VITE_SUPABASE_URL=https://gocunsnxmkhyciteqsoq.supabase.co
VITE_SUPABASE_ANON_KEY=eyJhbGciOi...
```

3. **App**

```bash
npm install
npm run dev
```

Abrí `http://localhost:5173`. Links de sala: `/s/ABC123`.

## Deploy en Vercel

1. Importá el repo en Vercel.
2. Agregá las env vars `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY`.
3. Build: `npm run build` · Output: `dist`.
4. Los links `/s/ABC123` reescriben a `sala.html` vía [`vercel.json`](vercel.json).

## Cómo se juega

1. Un jugador crea la sala y comparte el código (o el link).
2. Todos entran con un apodo (sin cuenta).
3. En el lobby proponen ideas o piden sugerencias del banco (humor rosarino). Nadie ve el texto del pozo.
4. El admin (también juega) inicia: 1 impostor (3–6 jugadores) o 2 (7–12).
5. Civiles ven la palabra; impostores ven “Sos impostor”.
6. Se juega cara a cara. El admin declara el ganador y puede iniciar otra ronda.

## Estructura

```
js/modules/   UI (home, sala)
js/services/  Supabase + salas
js/store/     zustand/vanilla
js/schemas/   zod
supabase/migrations/
```
