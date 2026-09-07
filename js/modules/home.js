import { nicknameSchema, roomCodeSchema } from '../schemas/proposal.js'
import { createRoom, joinRoom } from '../services/rooms.js'
import { ensureAnonymousSession } from '../services/supabase.js'
import { hide, show, setText } from './ui.js'
import { initThemeToggle } from './theme.js'

initThemeToggle()

const form = document.getElementById('home-form')
const errorEl = document.getElementById('home-error')
const loadingEl = document.getElementById('home-loading')
const nicknameInput = document.getElementById('nickname')
const codeInput = document.getElementById('room-code')

const savedNickname = localStorage.getItem('impostor.nickname')
if (savedNickname && nicknameInput) nicknameInput.value = savedNickname

const params = new URLSearchParams(window.location.search)
const prefillCode = params.get('code')
if (prefillCode && codeInput) codeInput.value = prefillCode.toUpperCase()

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
    await ensureAnonymousSession()

    if (action === 'create') {
      const room = await createRoom(nickname)
      window.location.href = `/s/${room.code}`
      return
    }

    const codeResult = roomCodeSchema.safeParse(codeInput.value)
    if (!codeResult.success) {
      showError(codeResult.error.issues[0]?.message ?? 'Código inválido')
      return
    }

    const room = await joinRoom(codeResult.data, nickname)
    window.location.href = `/s/${room.code}`
  } catch (error) {
    console.error(error)
    showError(humanizeError(error))
  }
})

function showError(message) {
  hide(loadingEl)
  setText(errorEl, message)
  show(errorEl)
}

function humanizeError(error) {
  const message = error?.message || String(error)
  if (message.includes('ROOM_NOT_FOUND')) return 'No encontramos esa sala.'
  if (message.includes('ROOM_FULL')) return 'La sala está llena (máx. 12).'
  if (message.includes('ROOM_STARTED')) return 'La partida ya empezó.'
  if (message.includes('Anonymous sign-ins are disabled')) {
    return 'Falta habilitar Anonymous Auth en Supabase (Authentication → Providers).'
  }
  if (message.includes('Failed to fetch') || message.includes('Invalid API key')) {
    return 'Revisá VITE_SUPABASE_URL y VITE_SUPABASE_ANON_KEY en .env.local'
  }
  return message
}
