import { createClient } from '@supabase/supabase-js'

/**
 * Vercel Cron fallback for room cleanup.
 * Requires SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY + CRON_SECRET in Vercel env.
 */
export default async function handler(req, res) {
  if (req.method !== 'GET' && req.method !== 'POST') {
    res.status(405).json({ error: 'method_not_allowed' })
    return
  }

  const auth = req.headers.authorization || ''
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : ''
  const cronHeader = req.headers['x-vercel-cron']
  const secret = process.env.CRON_SECRET

  const authorized =
    Boolean(cronHeader) || (secret && token && token === secret)

  if (!authorized) {
    res.status(401).json({ error: 'unauthorized' })
    return
  }

  const url = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY

  if (!url || !serviceKey) {
    res.status(500).json({ error: 'missing_supabase_service_env' })
    return
  }

  const supabase = createClient(url, serviceKey)
  const { data, error } = await supabase.rpc('cleanup_expired_rooms')

  if (error) {
    res.status(500).json({ error: error.message })
    return
  }

  res.status(200).json({ deleted: data ?? 0 })
}
