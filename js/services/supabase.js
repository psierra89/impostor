import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

let client = null

export function getSupabase() {
  if (client) return client

  if (!url || !anonKey) {
    throw new Error(
      'Faltan VITE_SUPABASE_URL o VITE_SUPABASE_ANON_KEY. Copiá .env.example a .env.local y completá las keys de Supabase.',
    )
  }

  client = createClient(url, anonKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: false,
    },
  })
  return client
}

/** @deprecated use getSupabase() */
export const supabase = new Proxy(
  {},
  {
    get(_target, prop) {
      const value = getSupabase()[prop]
      return typeof value === 'function' ? value.bind(getSupabase()) : value
    },
  },
)

export async function ensureAnonymousSession() {
  const sb = getSupabase()
  const {
    data: { session },
  } = await sb.auth.getSession()

  if (session) return session

  const { data, error } = await sb.auth.signInAnonymously()
  if (error) throw error
  return data.session
}

export async function getUserId() {
  const session = await ensureAnonymousSession()
  return session.user.id
}
