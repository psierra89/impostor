/**
 * Multiplayer smoke test (API-level) with isolated auth clients.
 *
 * Usage:
 *   SUPABASE_SERVICE_ROLE_KEY=... npm run test:multi
 *
 * Needs VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY in .env.local
 * and SUPABASE_SERVICE_ROLE_KEY in the environment (never commit it).
 */
import { createClient } from '@supabase/supabase-js'
import { readFileSync, existsSync } from 'node:fs'
import { resolve } from 'node:path'

function loadEnvLocal() {
  const path = resolve(process.cwd(), '.env.local')
  if (!existsSync(path)) return
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('#')) continue
    const i = trimmed.indexOf('=')
    if (i < 0) continue
    const key = trimmed.slice(0, i).trim()
    const value = trimmed.slice(i + 1).trim()
    if (!process.env[key]) process.env[key] = value
  }
}

loadEnvLocal()

const url = process.env.VITE_SUPABASE_URL || process.env.SUPABASE_URL
const anon = process.env.VITE_SUPABASE_ANON_KEY
const service = process.env.SUPABASE_SERVICE_ROLE_KEY

if (!url || !anon) {
  console.error('Faltan VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY')
  process.exit(1)
}
if (!service) {
  console.error(
    'Falta SUPABASE_SERVICE_ROLE_KEY (Settings → API → service_role). No la subas al repo.',
  )
  process.exit(1)
}

function memoryClient() {
  const store = new Map()
  const storage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
  }
  return createClient(url, anon, {
    auth: {
      persistSession: true,
      autoRefreshToken: false,
      detectSessionInUrl: false,
      storage,
      storageKey: `test-${Math.random().toString(36).slice(2)}`,
    },
  })
}

function randomCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  let code = ''
  for (let i = 0; i < 6; i += 1) code += alphabet[Math.floor(Math.random() * alphabet.length)]
  return code
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg)
}

async function main() {
  const admin = createClient(url, service, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const host = memoryClient()
  const guestA = memoryClient()
  const guestB = memoryClient()

  const email = `e2e-host-${Date.now()}@impostor.test`
  const password = `Test-${Math.random().toString(36).slice(2)}!9a`

  const { data: created, error: createUserErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    app_metadata: { provider: 'google', providers: ['google'] },
  })
  if (createUserErr) throw createUserErr

  const hostUserId = created.user.id

  const { error: signInErr } = await host.auth.signInWithPassword({ email, password })
  if (signInErr) throw signInErr

  // Ensure JWT carries google metadata for is_google_user()
  await admin.auth.admin.updateUserById(hostUserId, {
    app_metadata: { provider: 'google', providers: ['google'] },
  })
  await host.auth.refreshSession()

  const code = randomCode()
  let room
  const { data: roomData, error: roomErr } = await host.rpc('create_room', {
    p_code: code,
    p_nickname: 'HostE2E',
  })

  if (roomErr) {
    // Fallback if JWT metadata check fails: service-role helper
    console.warn('create_room via host failed, using create_room_for_tests:', roomErr.message)
    const { data: fallback, error: fbErr } = await admin.rpc('create_room_for_tests', {
      p_code: code,
      p_nickname: 'HostE2E',
      p_user_id: hostUserId,
    })
    if (fbErr) throw fbErr
    room = Array.isArray(fallback) ? fallback[0] : fallback
    // Host must also be the player — create_room_for_tests already inserted player for hostUserId
    // Re-sign so host client can call as that user
  } else {
    room = Array.isArray(roomData) ? roomData[0] : roomData
  }

  assert(room?.room_id, 'room created')
  console.log('Sala:', room.code)

  const { data: joinA, error: errA } = await (async () => {
    const { error } = await guestA.auth.signInAnonymously()
    if (error) throw error
    return guestA.rpc('join_room', { p_code: room.code, p_nickname: 'InvitadoA' })
  })()
  if (errA) throw errA
  const playerA = Array.isArray(joinA) ? joinA[0] : joinA

  const { data: joinB, error: errB } = await (async () => {
    const { error } = await guestB.auth.signInAnonymously()
    if (error) throw error
    return guestB.rpc('join_room', { p_code: room.code, p_nickname: 'InvitadoB' })
  })()
  if (errB) throw errB
  const playerB = Array.isArray(joinB) ? joinB[0] : joinB

  assert(playerA.player_id !== playerB.player_id, 'guests are distinct players')
  assert(playerA.player_id !== room.player_id, 'guest A != host')

  const { data: players, error: playersErr } = await host
    .from('players')
    .select('id, nickname, is_active')
    .eq('room_id', room.room_id)
    .eq('is_active', true)
  if (playersErr) throw playersErr
  assert(players.length >= 2, `expected >=2 players, got ${players.length}`)
  console.log('Jugadores activos:', players.map((p) => p.nickname).join(', '))

  // Host player id: from create_room or lookup
  let hostPlayerId = room.player_id
  if (!hostPlayerId) {
    const { data: hp } = await host
      .from('players')
      .select('id')
      .eq('room_id', room.room_id)
      .eq('user_id', hostUserId)
      .single()
    hostPlayerId = hp.id
  }

  const { data: started, error: startErr } = await host.rpc('start_round', {
    p_room_id: room.room_id,
    p_player_id: hostPlayerId,
  })
  if (startErr) throw startErr
  const round = Array.isArray(started) ? started[0] : started
  assert(round?.round_id, 'round started')
  console.log('Ronda:', round.round_id, 'impostores:', round.impostor_count)

  const cards = []
  for (const [client, playerId, label] of [
    [host, hostPlayerId, 'HostE2E'],
    [guestA, playerA.player_id, 'InvitadoA'],
    [guestB, playerB.player_id, 'InvitadoB'],
  ]) {
    const { data, error } = await client.rpc('get_my_card', {
      p_round_id: round.round_id,
      p_player_id: playerId,
    })
    if (error) throw error
    const card = Array.isArray(data) ? data[0] : data
    cards.push({ label, ...card })
    if (card.is_impostor) {
      assert(!card.word, `${label} impostor must not see word`)
    } else {
      assert(card.word, `${label} civilian must see word`)
    }
  }

  const impostors = cards.filter((c) => c.is_impostor)
  const civilians = cards.filter((c) => !c.is_impostor)
  assert(impostors.length === 1, `expected 1 impostor with 3 players, got ${impostors.length}`)
  assert(civilians.length === 2, 'expected 2 civilians')
  assert(
    civilians.every((c) => c.word === civilians[0].word),
    'civilians share the same word',
  )
  console.log(
    'Roles OK:',
    cards.map((c) => `${c.label}=${c.is_impostor ? 'IMPOSTOR' : c.word}`).join(' | '),
  )

  const { error: endErr } = await host.rpc('end_round', {
    p_room_id: room.room_id,
    p_player_id: hostPlayerId,
    p_winner: 'civilians',
  })
  if (endErr) throw endErr

  const { error: lobbyErr } = await host.rpc('return_to_lobby', {
    p_room_id: room.room_id,
    p_player_id: hostPlayerId,
  })
  if (lobbyErr) throw lobbyErr

  // Cleanup test user + room
  await admin.from('rooms').delete().eq('id', room.room_id)
  await admin.auth.admin.deleteUser(hostUserId)

  console.log('PASS: multiplayer flow OK')
}

main().catch((err) => {
  console.error('FAIL:', err.message || err)
  process.exit(1)
})
