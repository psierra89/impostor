import { animate } from 'motion'
import { proposalSchema } from '../schemas/proposal.js'
import {
  addProposal,
  endRound,
  fetchRoomBundle,
  getMyCard,
  getReveal,
  joinRoom,
  leaveRoom,
  nextRound,
  startRound,
  subscribeRoom,
  suggestFromBank,
  touchPresence,
} from '../services/rooms.js'
import { ensureAnonymousSession } from '../services/supabase.js'
import {
  gameStore,
  loadLocalSession,
  saveLocalSession,
} from '../store/game.js'
import {
  hide,
  poolLabel,
  renderPlayerList,
  renderRevealList,
  setText,
  show,
  winnerLabel,
} from './ui.js'
import { initThemeToggle } from './theme.js'

initThemeToggle()

const els = {
  loading: document.getElementById('state-loading'),
  error: document.getElementById('state-error'),
  errorMessage: document.getElementById('error-message'),
  retry: document.getElementById('retry-btn'),
  lobby: document.getElementById('state-lobby'),
  playing: document.getElementById('state-playing'),
  revealed: document.getElementById('state-revealed'),
  navCode: document.getElementById('nav-code'),
  navStatus: document.getElementById('nav-status'),
  copyCode: document.getElementById('copy-code'),
  playerList: document.getElementById('player-list'),
  playersEmpty: document.getElementById('players-empty'),
  playerCount: document.getElementById('player-count'),
  poolCount: document.getElementById('pool-count'),
  proposalForm: document.getElementById('proposal-form'),
  proposalInput: document.getElementById('proposal-input'),
  proposalFeedback: document.getElementById('proposal-feedback'),
  suggestBtn: document.getElementById('suggest-btn'),
  hostControls: document.getElementById('host-controls'),
  startBtn: document.getElementById('start-btn'),
  startHint: document.getElementById('start-hint'),
  guestWait: document.getElementById('guest-wait'),
  roleCard: document.getElementById('role-card'),
  roleLabel: document.getElementById('role-label'),
  roleMain: document.getElementById('role-main'),
  roleHint: document.getElementById('role-hint'),
  hostEnd: document.getElementById('host-end-controls'),
  guestPlayingWait: document.getElementById('guest-playing-wait'),
  winCivilians: document.getElementById('win-civilians'),
  winImpostors: document.getElementById('win-impostors'),
  winnerTitle: document.getElementById('winner-title'),
  revealedWord: document.getElementById('revealed-word'),
  revealList: document.getElementById('reveal-list'),
  hostNext: document.getElementById('host-next-controls'),
  nextRoundBtn: document.getElementById('next-round-btn'),
  guestRevealedWait: document.getElementById('guest-revealed-wait'),
}

let unsubscribe = null
let presenceTimer = null
let lastRoomStatus = null

const params = new URLSearchParams(window.location.search)
const pathMatch = window.location.pathname.match(/\/s\/([A-Za-z0-9]{6})\/?$/i)
const codeFromQuery = (params.get('code') || pathMatch?.[1] || '').toUpperCase()

els.retry?.addEventListener('click', () => bootstrap())
els.copyCode?.addEventListener('click', async () => {
  const { room } = gameStore.getState()
  if (!room?.code) return
  try {
    await navigator.clipboard.writeText(room.code)
    setText(els.navStatus, 'Código copiado')
    setTimeout(() => renderChrome(gameStore.getState()), 1200)
  } catch {
    setText(els.navStatus, room.code)
  }
})

els.proposalForm?.addEventListener('submit', async (event) => {
  event.preventDefault()
  const parsed = proposalSchema.safeParse(els.proposalInput.value)
  if (!parsed.success) {
    setText(els.proposalFeedback, parsed.error.issues[0]?.message ?? 'Idea inválida')
    return
  }

  try {
    await addProposal(parsed.data)
    els.proposalInput.value = ''
    setText(els.proposalFeedback, 'Idea agregada al pozo')
    await refreshPool()
  } catch (error) {
    setText(els.proposalFeedback, humanizeError(error))
  }
})

els.suggestBtn?.addEventListener('click', async () => {
  els.suggestBtn.disabled = true
  try {
    const added = await suggestFromBank(3)
    setText(
      els.proposalFeedback,
      added === 1 ? 'Se agregó 1 sugerencia' : `Se agregaron ${added} sugerencias`,
    )
    await refreshPool()
  } catch (error) {
    setText(els.proposalFeedback, humanizeError(error))
  } finally {
    els.suggestBtn.disabled = false
  }
})

els.startBtn?.addEventListener('click', async () => {
  els.startBtn.disabled = true
  try {
    await startRound()
    await refreshAll()
  } catch (error) {
    setText(els.startHint, humanizeError(error))
    els.startBtn.disabled = false
  }
})

els.winCivilians?.addEventListener('click', () => declareWinner('civilians'))
els.winImpostors?.addEventListener('click', () => declareWinner('impostors'))
els.nextRoundBtn?.addEventListener('click', async () => {
  els.nextRoundBtn.disabled = true
  try {
    await nextRound()
    gameStore.getState().resetRoundUi()
    await refreshAll()
  } catch (error) {
    alert(humanizeError(error))
  } finally {
    els.nextRoundBtn.disabled = false
  }
})

document.querySelector('a[href="/"]')?.addEventListener('click', async (event) => {
  event.preventDefault()
  try {
    await leaveRoom()
  } catch {
    // ignore
  }
  window.location.href = '/'
})

gameStore.subscribe(render)

bootstrap()

async function bootstrap() {
  hide(els.error)
  show(els.loading)
  hide(els.lobby)
  hide(els.playing)
  hide(els.revealed)

  try {
    await ensureAnonymousSession()
    const session = await resolveSession()
    if (!session) {
      window.location.href = codeFromQuery ? `/?code=${codeFromQuery}` : '/'
      return
    }

    await refreshAll()
    wireRealtime(session.roomId)
    startPresence(session.playerId)
  } catch (error) {
    console.error(error)
    gameStore.getState().setError(humanizeError(error))
  }
}

async function resolveSession() {
  let session = loadLocalSession()
  const nickname = localStorage.getItem('impostor.nickname') || session?.nickname

  if (session?.roomId) {
    try {
      const bundle = await fetchRoomBundle(session.roomId)
      if (bundle.room && (!codeFromQuery || bundle.room.code === codeFromQuery)) {
        return session
      }
    } catch {
      // fall through to join by code
    }
  }

  if (!codeFromQuery || !nickname) return null

  const joined = await joinRoom(codeFromQuery, nickname)
  session = {
    roomId: joined.room_id,
    playerId: joined.player_id,
    code: joined.code,
    nickname,
  }
  saveLocalSession(session)
  return session
}

async function refreshAll() {
  const session = loadLocalSession()
  if (!session) throw new Error('Sesión no encontrada')

  const bundle = await fetchRoomBundle(session.roomId)
  const me = bundle.players.find((p) => p.id === session.playerId) ?? null

  gameStore.getState().setMe(me)
  gameStore.getState().setRoom(bundle.room)
  gameStore.getState().setPlayers(bundle.players)
  gameStore.getState().setPoolCount(bundle.poolCount)

  if (bundle.room.status === 'playing' && bundle.room.current_round_id) {
    const card = await getMyCard(bundle.room.current_round_id)
    gameStore.getState().setCard(card)
    gameStore.getState().setReveal(null)
  } else if (bundle.room.status === 'revealed' && bundle.room.current_round_id) {
    const reveal = await getReveal(bundle.room.current_round_id)
    gameStore.getState().setReveal(reveal)
  } else {
    gameStore.getState().resetRoundUi()
  }

  gameStore.getState().setStatus(bundle.room.status)
}

async function refreshPlayers() {
  const session = loadLocalSession()
  if (!session) return
  const bundle = await fetchRoomBundle(session.roomId)
  gameStore.getState().setPlayers(bundle.players)
  gameStore.getState().setRoom(bundle.room)
  gameStore.getState().setMe(
    bundle.players.find((p) => p.id === session.playerId) ?? null,
  )
}

async function refreshPool() {
  const session = loadLocalSession()
  if (!session) return
  const bundle = await fetchRoomBundle(session.roomId)
  gameStore.getState().setPoolCount(bundle.poolCount)
}

async function declareWinner(winner) {
  try {
    await endRound(winner)
    await refreshAll()
  } catch (error) {
    alert(humanizeError(error))
  }
}

function wireRealtime(roomId) {
  unsubscribe?.()
  unsubscribe = subscribeRoom(roomId, {
    onRoom: async () => {
      await refreshAll()
    },
    onPlayers: async () => {
      await refreshPlayers()
    },
    onPool: async () => {
      await refreshPool()
    },
  })
}

function startPresence(playerId) {
  clearInterval(presenceTimer)
  touchPresence(playerId)
  presenceTimer = setInterval(() => touchPresence(playerId), 20000)
}

function render(state) {
  if (state.status === 'loading') {
    show(els.loading)
    hide(els.error)
    hide(els.lobby)
    hide(els.playing)
    hide(els.revealed)
    return
  }

  if (state.status === 'error') {
    hide(els.loading)
    show(els.error)
    setText(els.errorMessage, state.error || 'Error desconocido')
    return
  }

  hide(els.loading)
  hide(els.error)
  renderChrome(state)

  if (state.status === 'lobby') renderLobby(state)
  if (state.status === 'playing') renderPlaying(state)
  if (state.status === 'revealed') renderRevealed(state)
}

function renderChrome(state) {
  setText(els.navCode, state.room?.code || '······')
  const labels = {
    lobby: 'Lobby',
    playing: 'En juego',
    revealed: 'Revelación',
  }
  setText(els.navStatus, labels[state.status] || state.status)
}

function renderLobby(state) {
  show(els.lobby)
  hide(els.playing)
  hide(els.revealed)

  renderPlayerList(
    els.playerList,
    els.playersEmpty,
    state.players,
    state.room?.host_player_id,
    state.me?.id,
  )
  setText(els.playerCount, `${state.players.length} / 12`)
  setText(els.poolCount, poolLabel(state.poolCount))

  const canStart = state.players.length >= 3 && state.players.length <= 12

  if (state.isHost) {
    show(els.hostControls)
    hide(els.guestWait)
    els.startBtn.disabled = !canStart
    setText(
      els.startHint,
      canStart
        ? state.poolCount === 0
          ? 'El pozo está vacío: se elegirá del banco al iniciar.'
          : 'Listo para iniciar.'
        : 'Hacen falta al menos 3 jugadores.',
    )
  } else {
    hide(els.hostControls)
    show(els.guestWait)
  }
}

function renderPlaying(state) {
  show(els.playing)
  hide(els.lobby)
  hide(els.revealed)

  const card = state.card
  if (!card) {
    setText(els.roleMain, 'Cargando carta…')
    setText(els.roleHint, '')
    return
  }

  if (card.is_impostor) {
    els.roleCard.className = 'role-card-impostor'
    setText(els.roleLabel, 'Tu rol')
    setText(els.roleMain, 'Sos impostor')
    setText(
      els.roleHint,
      'No conocés la palabra. Bluffear, acusar y sobrevivir. No muestres la pantalla.',
    )
  } else {
    els.roleCard.className = 'role-card-civilian'
    setText(els.roleLabel, 'La palabra')
    setText(els.roleMain, card.word || '—')
    setText(
      els.roleHint,
      'Sos civil. Descubrí al impostor sin delatar la palabra demasiado.',
    )
  }

  if (state.status !== lastRoomStatus) {
    animate(els.roleCard, { opacity: [0, 1], y: [12, 0] }, { duration: 0.35 })
    lastRoomStatus = state.status
  }

  if (state.isHost) {
    show(els.hostEnd)
    hide(els.guestPlayingWait)
  } else {
    hide(els.hostEnd)
    show(els.guestPlayingWait)
  }
}

function renderRevealed(state) {
  show(els.revealed)
  hide(els.lobby)
  hide(els.playing)

  const reveal = state.reveal
  setText(els.winnerTitle, winnerLabel(reveal?.winner))
  setText(els.revealedWord, reveal?.word || '—')
  renderRevealList(els.revealList, reveal?.roles || [])

  if (state.isHost) {
    show(els.hostNext)
    hide(els.guestRevealedWait)
  } else {
    hide(els.hostNext)
    show(els.guestRevealedWait)
  }
}

function humanizeError(error) {
  const message = error?.message || String(error)
  if (message.includes('NOT_HOST')) return 'Solo el admin puede hacer eso.'
  if (message.includes('NEED_PLAYERS')) return 'Hacen falta al menos 3 jugadores.'
  if (message.includes('ROOM_FULL')) return 'La sala está llena.'
  if (message.includes('ROOM_NOT_FOUND')) return 'Sala no encontrada.'
  if (message.includes('WRONG_STATUS')) return 'La sala no está en el estado esperado.'
  if (message.includes('EMPTY_BANK')) return 'El banco de palabras está vacío.'
  return message
}

window.addEventListener('beforeunload', () => {
  unsubscribe?.()
  clearInterval(presenceTimer)
})
