export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const { email, source } = req.body;
  if (!email) return res.status(400).json({ error: 'Email is required' });

  const token = process.env.AIRTABLE_TOKEN;
  const baseId = 'appnM2VHIk4AhGb2s';
  const tableId = 'tblH2j9VWeTpdWjSL';

  const response = await fetch(`https://api.airtable.com/v0/${baseId}/${tableId}`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      fields: {
        Email: email,
        Source: source || 'wallacehamilton.co',
        'Submitted At': new Date().toISOString(),
      }
    })
  });

  if (!response.ok) {
    const err = await response.json();
    console.error('Airtable error:', err);
    return res.status(500).json({ error: 'Failed to save' });
  }

  return res.status(200).json({ success: true });
}
