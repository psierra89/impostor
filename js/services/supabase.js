import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

const MODE_KEY = 'impostor.mode'
const MAIN_STORAGE_KEY = 'impostor-auth-main'
const GUEST_STORAGE_KEY = 'impostor-auth-guest'

let mainClient = null
let guestClient = null

function assertEnv() {
  if (!url || !anonKey) {
    throw new Error(
      'Faltan VITE_SUPABASE_URL o VITE_SUPABASE_ANON_KEY. Copiá .env.example a .env.local y completá las keys de Supabase.',
    )
  }
}

function createAuthClient(storage, storageKey) {
  assertEnv()
  return createClient(url, anonKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
      flowType: 'pkce',
      storage,
      storageKey,
    },
  })
}

export function getMainSupabase() {
  if (!mainClient) {
    mainClient = createAuthClient(window.localStorage, MAIN_STORAGE_KEY)
  }
  return mainClient
}

export function getGuestSupabase() {
  if (!guestClient) {
    guestClient = createAuthClient(window.sessionStorage, GUEST_STORAGE_KEY)
  }
  return guestClient
}

/** Active client for this tab: guest (sessionStorage) or host (localStorage). */
export function getSupabase() {
  try {
    if (sessionStorage.getItem(MODE_KEY) === 'guest') {
      return getGuestSupabase()
    }
  } catch {
    // ignore
  }
  return getMainSupabase()
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

export function setTabMode(mode) {
  try {
    sessionStorage.setItem(MODE_KEY, mode === 'guest' ? 'guest' : 'host')
  } catch {
    // ignore
  }
}

export function getTabMode() {
  try {
    return sessionStorage.getItem(MODE_KEY) === 'guest' ? 'guest' : 'host'
  } catch {
    return 'host'
  }
}

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
  setTabMode('host')
  const sb = getMainSupabase()
  const {
    data: { session },
  } = await sb.auth.getSession()
  if (session && isGoogleUser(session.user)) return session
  return null
}

/** Guest/join path: isolated per browser tab via sessionStorage. */
export async function ensureGuestSession() {
  setTabMode('guest')
  const sb = getGuestSupabase()
  const {
    data: { session },
  } = await sb.auth.getSession()
  if (session) return session

  const { data, error } = await sb.auth.signInAnonymously()
  if (error) throw error
  return data.session
}

/** Create-room path: must be Google on the host client. */
export async function ensureGoogleSession() {
  setTabMode('host')
  const session = await getGoogleSession()
  if (session) return session
  throw new Error('GOOGLE_AUTH_REQUIRED')
}

export async function signInWithGoogle(nextPath = '/') {
  setTabMode('host')
  const sb = getMainSupabase()
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
  const sb = getMainSupabase()
  const { error } = await sb.auth.signOut()
  if (error) throw error
  setTabMode('host')
}

export async function getUserId() {
  const session = await getSession()
  if (!session) throw new Error('NOT_AUTHENTICATED')
  return session.user.id
}

/** @deprecated */
export async function ensureAnonymousSession() {
  return ensureGuestSession()
}
