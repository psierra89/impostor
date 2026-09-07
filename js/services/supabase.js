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
      detectSessionInUrl: true,
      flowType: 'pkce',
    },
  })
  return client
}

export const supabase = new Proxy(
  {},
  {
    get(_target, prop) {
      const value = getSupabase()[prop]
      return typeof value === 'function' ? value.bind(getSupabase()) : value
    },
  },
)

export function isGoogleUser(user) {
  if (!user) return false
  const providers = user.app_metadata?.providers
  if (Array.isArray(providers) && providers.includes('google')) return true
  if (user.app_metadata?.provider === 'google') return true
  if (Array.isArray(user.identities)) {
    return user.identities.some((identity) => identity.provider === 'google')
  }
  return false
}

export async function getSession() {
  const sb = getSupabase()
  const {
    data: { session },
  } = await sb.auth.getSession()
  return session
}

export async function getGoogleSession() {
  const session = await getSession()
  if (session && isGoogleUser(session.user)) return session
  return null
}

/** Guest/join path: reuse current session or create anonymous. */
export async function ensureGuestSession() {
  const sb = getSupabase()
  const {
    data: { session },
  } = await sb.auth.getSession()
  if (session) return session

  const { data, error } = await sb.auth.signInAnonymously()
  if (error) throw error
  return data.session
}

/** Create-room path: must be Google. */
export async function ensureGoogleSession() {
  const session = await getGoogleSession()
  if (session) return session
  throw new Error('GOOGLE_AUTH_REQUIRED')
}

export async function signInWithGoogle(nextPath = '/') {
  const sb = getSupabase()
  const redirectTo = `${window.location.origin}${nextPath}`
  const { error } = await sb.auth.signInWithOAuth({
    provider: 'google',
    options: {
      redirectTo,
      queryParams: {
        access_type: 'offline',
        prompt: 'select_account',
      },
    },
  })
  if (error) throw error
}

export async function signOut() {
  const sb = getSupabase()
  const { error } = await sb.auth.signOut()
  if (error) throw error
}

export async function getUserId() {
  const session = await getSession()
  if (!session) throw new Error('NOT_AUTHENTICATED')
  return session.user.id
}

/** @deprecated use ensureGuestSession / ensureGoogleSession */
export async function ensureAnonymousSession() {
  return ensureGuestSession()
}
