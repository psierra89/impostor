#!/usr/bin/env node
/**
 * Aplica las migraciones SQL contra la base de Supabase.
 * Uso:
 *   SUPABASE_DB_URL="postgresql://postgres:...@db.xxx.supabase.co:5432/postgres" node scripts/apply-migrations.mjs
 *
 * La URL está en Supabase → Project Settings → Database → Connection string (URI).
 */
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import pg from 'pg'

const __dirname = dirname(fileURLToPath(import.meta.url))
const dbUrl = process.env.SUPABASE_DB_URL

if (!dbUrl) {
  console.error('Falta SUPABASE_DB_URL')
  process.exit(1)
}

const dir = join(__dirname, '..', 'supabase', 'migrations')
const files = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort()
const client = new pg.Client({ connectionString: dbUrl, ssl: { rejectUnauthorized: false } })

await client.connect()
try {
  for (const file of files) {
    const sql = readFileSync(join(dir, file), 'utf8')
    console.log(`Aplicando ${file}…`)
    await client.query(sql)
    console.log(`OK ${file}`)
  }
} finally {
  await client.end()
}
