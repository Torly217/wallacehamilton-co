/**
 * The Way — email signup endpoint
 *
 * Calls the SECURITY DEFINER RPC `submit_way_subscribe` on the shared
 * Neothink Supabase project. The RPC validates the email, inserts a row
 * into way_subscribers, and fires a trigger that emails wallace@neothink.com
 * via Resend.
 *
 * Anon key is publishable. The anon role only has EXECUTE on the RPC,
 * no direct table access. See supabase-migration.sql in this repo.
 */

const SUPABASE_URL =
  process.env.NEXT_PUBLIC_SUPABASE_URL ||
  process.env.SUPABASE_URL ||
  'https://oiajckhzuhdiokhjkjnc.supabase.co';

const SUPABASE_ANON_KEY =
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ||
  process.env.SUPABASE_ANON_KEY ||
  'sb_publishable_knfy1uTJeUp86WfV_waDeA_VGAiDmtj';

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const { email, source } = req.body || {};
  if (!email || typeof email !== 'string') {
    return res.status(400).json({ error: 'Email is required' });
  }

  try {
    const response = await fetch(
      `${SUPABASE_URL}/rest/v1/rpc/submit_way_subscribe`,
      {
        method: 'POST',
        headers: {
          apikey: SUPABASE_ANON_KEY,
          Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
          'Content-Type': 'application/json',
          Accept: 'application/json',
        },
        body: JSON.stringify({
          p_email: email.trim(),
          p_source: source || 'theway.world',
        }),
      }
    );

    if (!response.ok) {
      const text = await response.text().catch(() => '');
      console.error('Supabase subscribe error:', response.status, text);
      return res.status(500).json({ error: 'Failed to save' });
    }

    return res.status(200).json({ success: true });
  } catch (err) {
    console.error('Subscribe handler error:', err);
    return res.status(500).json({ error: 'Failed to save' });
  }
}
