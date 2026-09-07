import { createStore } from 'zustand/vanilla'

const SESSION_KEY = 'impostor.session'

export function loadLocalSession() {
  try {
    const raw = localStorage.getItem(SESSION_KEY)
    return raw ? JSON.parse(raw) : null
  } catch {
    return null
  }
}

export function saveLocalSession(session) {
  localStorage.setItem(SESSION_KEY, JSON.stringify(session))
}

export function clearLocalSession() {
  localStorage.removeItem(SESSION_KEY)
}

export const gameStore = createStore((set, get) => ({
  status: 'loading',
  error: null,
  room: null,
  players: [],
  me: null,
  isHost: false,
  poolCount: 0,
  card: null,
  reveal: null,

  setStatus(status) {
    set({ status, error: status === 'error' ? get().error : null })
  },

  setError(error) {
    set({ status: 'error', error })
  },

  setRoom(room) {
    const me = get().me
    set({
      room,
      isHost: Boolean(me && room && room.host_player_id === me.id),
    })
  },

  setPlayers(players) {
    set({ players })
  },

  setMe(me) {
    const room = get().room
    set({
      me,
      isHost: Boolean(me && room && room.host_player_id === me.id),
    })
  },

  setPoolCount(poolCount) {
    set({ poolCount })
  },

  setCard(card) {
    set({ card })
  },

  setReveal(reveal) {
    set({ reveal })
  },

  resetRoundUi() {
    set({ card: null, reveal: null })
  },
}))
