import { ensureGoogleSession, ensureGuestSession, getUserId, getSupabase } from './supabase.js'
import {
  clearLocalSession,
  loadLocalSession,
  saveLocalSession,
} from '../store/game.js'

const supabase = new Proxy(
  {},
  {
    get(_target, prop) {
      const sb = getSupabase()
      const value = sb[prop]
      return typeof value === 'function' ? value.bind(sb) : value
    },
  },
)

function randomCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  let code = ''
  for (let i = 0; i < 6; i += 1) {
    code += alphabet[Math.floor(Math.random() * alphabet.length)]
  }
  return code
}

export async function createRoom(nickname, theme = 'rosario') {
  await ensureGoogleSession()
  const userId = await getUserId()

  for (let attempt = 0; attempt < 5; attempt += 1) {
    const code = randomCode()
    const { data, error } = await supabase.rpc('create_room', {
      p_code: code,
      p_nickname: nickname,
      p_theme: theme,
    })

    if (!error) {
      const result = Array.isArray(data) ? data[0] : data
      saveLocalSession({
        roomId: result.room_id,
        playerId: result.player_id,
        code: result.code,
        nickname,
        userId,
      })
      return result
    }

    if (!String(error.message || '').includes('duplicate')) {
      throw error
    }
  }

  throw new Error('No pudimos crear la sala. Probá de nuevo.')
}

export async function joinRoom(code, nickname) {
  await ensureGuestSession()
  const userId = await getUserId()

  const { data, error } = await supabase.rpc('join_room', {
    p_code: code.toUpperCase(),
    p_nickname: nickname,
  })

  if (error) throw error

  const result = Array.isArray(data) ? data[0] : data
  saveLocalSession({
    roomId: result.room_id,
    playerId: result.player_id,
    code: result.code,
    nickname,
    userId,
  })
  return result
}

export async function leaveRoom() {
  const session = loadLocalSession()
  if (session?.playerId) {
    await supabase.rpc('leave_room', { p_player_id: session.playerId })
  }
  clearLocalSession()
}

export async function kickPlayer(targetPlayerId) {
  const session = loadLocalSession()
  if (!session) throw new Error('Sesión no encontrada')

  const { error } = await supabase.rpc('kick_player', {
    p_room_id: session.roomId,
    p_host_player_id: session.playerId,
    p_target_player_id: targetPlayerId,
  })
  if (error) throw error
}

export async function setRoomTheme(theme) {
  const session = loadLocalSession()
  if (!session) throw new Error('Sesión no encontrada')

  const { error } = await supabase.rpc('set_room_theme', {
    p_room_id: session.roomId,
    p_player_id: session.playerId,
    p_theme: theme,
  })
  if (error) throw error
}

export async function fetchRoomBundle(roomId) {
  const [{ data: room, error: roomError }, { data: players, error: playersError }] =
    await Promise.all([
      supabase.from('rooms').select('*').eq('id', roomId).single(),
      supabase
        .from('players')
        .select('*')
        .eq('room_id', roomId)
        .eq('is_active', true)
        .order('joined_at', { ascending: true }),
    ])

  if (roomError) throw roomError
  if (playersError) throw playersError

  const { data: poolCount, error: poolError } = await supabase.rpc('get_pool_count', {
    p_room_id: roomId,
  })
  if (poolError) throw poolError

  return { room, players, poolCount: poolCount ?? 0 }
}

export async function addProposal(text) {
  const session = loadLocalSession()
  if (!session) throw new Error('Sesión no encontrada')

  const { error } = await supabase.rpc('add_proposal', {
    p_room_id: session.roomId,
    p_player_id: session.playerId,
    p_text: text,
  })
  if (error) throw error
}

export async function suggestFromBank(count = 3) {
  const session = loadLocalSession()
  if (!session) throw new Error('Sesión no encontrada')

  const { data, error } = await supabase.rpc('suggest_from_bank', {
    p_room_id: session.roomId,
    p_player_id: session.playerId,
    p_count: count,
  })
  if (error) throw error
  return data
}

export async function startRound() {
  const session = loadLocalSession()
  if (!session) throw new Error('Sesión no encontrada')

  const { data, error } = await supabase.rpc('start_round', {
    p_room_id: session.roomId,
    p_player_id: session.playerId,
  })
  if (error) throw error
  return Array.isArray(data) ? data[0] : data
}

export async function endRound(winner) {
  const session = loadLocalSession()
  if (!session) throw new Error('Sesión no encontrada')

  const { error } = await supabase.rpc('end_round', {
    p_room_id: session.roomId,
    p_player_id: session.playerId,
    p_winner: winner,
  })
  if (error) throw error
}

export async function nextRound() {
  const session = loadLocalSession()
  if (!session) throw new Error('Sesión no encontrada')

  const { error } = await supabase.rpc('return_to_lobby', {
    p_room_id: session.roomId,
    p_player_id: session.playerId,
  })
  if (error) throw error
}

/** Start another round immediately from revealed (skips lobby). */
export async function rematchRound() {
  return startRound()
}

export async function getMyCard(roundId) {
  const session = loadLocalSession()
  if (!session) throw new Error('Sesión no encontrada')

  const { data, error } = await supabase.rpc('get_my_card', {
    p_round_id: roundId,
    p_player_id: session.playerId,
  })
  if (error) throw error
  return Array.isArray(data) ? data[0] : data
}

export async function getReveal(roundId) {
  const { data: round, error: roundError } = await supabase
    .from('rounds')
    .select('id, word, winner')
    .eq('id', roundId)
    .single()
  if (roundError) throw roundError

  const { data: roles, error: rolesError } = await supabase
    .from('round_roles')
    .select('player_id, is_impostor, players(nickname)')
    .eq('round_id', roundId)
  if (rolesError) throw rolesError

  return {
    word: round.word,
    winner: round.winner,
    roles: (roles ?? []).map((role) => ({
      playerId: role.player_id,
      isImpostor: role.is_impostor,
      nickname: role.players?.nickname ?? 'Jugador',
    })),
  }
}

export function subscribeRoom(roomId, handlers) {
  const channel = supabase
    .channel(`room:${roomId}`)
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'rooms', filter: `id=eq.${roomId}` },
      (payload) => handlers.onRoom?.(payload.new),
    )
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'players', filter: `room_id=eq.${roomId}` },
      () => handlers.onPlayers?.(),
    )
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'proposals', filter: `room_id=eq.${roomId}` },
      () => handlers.onPool?.(),
    )
    .subscribe()

  return () => {
    supabase.removeChannel(channel)
  }
}

export async function touchPresence(playerId) {
  await supabase
    .from('players')
    .update({ last_seen: new Date().toISOString() })
    .eq('id', playerId)
}
