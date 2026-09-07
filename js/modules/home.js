import { nicknameSchema, roomCodeSchema } from '../schemas/proposal.js'
import { createRoom, joinRoom } from '../services/rooms.js'
import {
  ensureGoogleSession,
  ensureGuestSession,
  getGoogleSession,
  getSession,
  isGoogleUser,
  signInWithGoogle,
  signOut,
} from '../services/supabase.js'
import { hide, show, setText } from './ui.js'
import { initThemeToggle } from './theme.js'

initThemeToggle()

const form = document.getElementById('home-form')
const errorEl = document.getElementById('home-error')
const loadingEl = document.getElementById('home-loading')
const nicknameInput = document.getElementById('nickname')
const codeInput = document.getElementById('room-code')
const authBar = document.getElementById('auth-bar')
const authLabel = document.getElementById('auth-label')
const googleBtn = document.getElementById('google-btn')
const logoutBtn = document.getElementById('logout-btn')
const createBtn = document.getElementById('create-btn')
const createHint = document.getElementById('create-hint')

const savedNickname = localStorage.getItem('impostor.nickname')
if (savedNickname && nicknameInput) nicknameInput.value = savedNickname

const params = new URLSearchParams(window.location.search)
const prefillCode = params.get('code')
if (prefillCode && codeInput) codeInput.value = prefillCode.toUpperCase()

const pendingCreate = localStorage.getItem('impostor.pendingCreate') === '1'

bootstrapAuth()

googleBtn?.addEventListener('click', async () => {
  hide(errorEl)
  try {
    localStorage.setItem('impostor.pendingCreate', nicknameInput?.value?.trim() ? '1' : '0')
    if (nicknameInput?.value?.trim()) {
      localStorage.setItem('impostor.nickname', nicknameInput.value.trim())
    }
    await signInWithGoogle('/')
  } catch (error) {
    showError(humanizeError(error))
  }
})

logoutBtn?.addEventListener('click', async () => {
  try {
    await signOut()
    localStorage.removeItem('impostor.pendingCreate')
    await renderAuth()
  } catch (error) {
    showError(humanizeError(error))
  }
})

form?.addEventListener('submit', async (event) => {
  event.preventDefault()
  hide(errorEl)
  show(loadingEl)

  const submitter = event.submitter
  const action = submitter?.value || 'create'
  const nicknameResult = nicknameSchema.safeParse(nicknameInput.value)

  if (!nicknameResult.success) {
    showError(nicknameResult.error.issues[0]?.message ?? 'Apodo inválido')
    return
  }

  const nickname = nicknameResult.data
  localStorage.setItem('impostor.nickname', nickname)

  try {
    if (action === 'create') {
      try {
        await ensureGoogleSession()
      } catch {
        localStorage.setItem('impostor.pendingCreate', '1')
        await signInWithGoogle('/')
        return
      }

      const room = await createRoom(nickname)
      localStorage.removeItem('impostor.pendingCreate')
      window.location.href = `/s/${room.code}`
      return
    }

    const codeResult = roomCodeSchema.safeParse(codeInput.value)
    if (!codeResult.success) {
      showError(codeResult.error.issues[0]?.message ?? 'Código inválido')
      return
    }

    await ensureGuestSession()
    const room = await joinRoom(codeResult.data, nickname)
    window.location.href = `/s/${room.code}`
  } catch (error) {
    console.error(error)
    showError(humanizeError(error))
  }
})

async function bootstrapAuth() {
  try {
    await getSession()
    await renderAuth()

    if (pendingCreate) {
      const google = await getGoogleSession()
      if (google && nicknameInput?.value?.trim()) {
        localStorage.removeItem('impostor.pendingCreate')
        hide(errorEl)
        show(loadingEl)
        try {
          const nickname = nicknameSchema.parse(nicknameInput.value)
          localStorage.setItem('impostor.nickname', nickname)
          const room = await createRoom(nickname)
          window.location.href = `/s/${room.code}`
          return
        } catch (error) {
          showError(humanizeError(error))
        }
      }
    }
  } catch (error) {
    console.error(error)
  }
}

async function renderAuth() {
  const session = await getSession()
  const google = session && isGoogleUser(session.user)

  if (!authBar) return

  if (google) {
    show(authBar)
    const email = session.user.email || 'Cuenta Google'
    setText(authLabel, email)
    hide(googleBtn)
    show(logoutBtn)
    if (createBtn) createBtn.textContent = 'Crear sala'
    if (createHint) {
      setText(createHint, 'Vas a crear la sala con tu cuenta de Google.')
      show(createHint)
    }
  } else {
    show(authBar)
    setText(authLabel, 'Para crear una sala necesitás Google')
    show(googleBtn)
    hide(logoutBtn)
    if (createBtn) createBtn.textContent = 'Entrar con Google y crear'
    if (createHint) {
      setText(createHint, 'Unirse a una sala no requiere cuenta.')
      show(createHint)
    }
  }
}

function showError(message) {
  hide(loadingEl)
  setText(errorEl, message)
  show(errorEl)
}

function humanizeError(error) {
  const message = error?.message || String(error)
  if (message.includes('GOOGLE_AUTH_REQUIRED')) {
    return 'Para crear una sala tenés que entrar con Google.'
  }
  if (message.includes('NOT_GOOGLE')) {
    return 'Solo cuentas de Google pueden crear salas.'
  }
  if (message.includes('ROOM_LIMIT')) {
    return 'Llegaste al límite de salas (máx. 5 en 24 h).'
  }
  if (message.includes('ACTIVE_ROOM_EXISTS')) {
    return 'Ya tenés una sala activa. Usala o esperá a que expire.'
  }
  if (message.includes('ROOM_EXPIRED')) return 'Esa sala ya expiró.'
  if (message.includes('ROOM_NOT_FOUND')) return 'No encontramos esa sala.'
  if (message.includes('ROOM_FULL')) return 'La sala está llena (máx. 12).'
  if (message.includes('ROOM_STARTED')) return 'La partida ya empezó.'
  if (message.includes('Anonymous sign-ins are disabled')) {
    return 'Falta habilitar Anonymous Auth en Supabase (para unirse).'
  }
  if (message.includes('provider is not enabled') || message.includes('Unsupported provider')) {
    return 'Falta habilitar el provider Google en Supabase Auth.'
  }
  if (message.includes('Failed to fetch') || message.includes('Invalid API key')) {
    return 'Revisá VITE_SUPABASE_URL y VITE_SUPABASE_ANON_KEY en .env.local'
  }
  return message
}
