export async function onRequest(context) {
  const { request, env } = context;
  const cors = { 'access-control-allow-origin': '*', 'access-control-allow-methods': 'GET,PUT,POST,OPTIONS', 'access-control-allow-headers': 'content-type' };
  if (request.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (!env.PLANNER_KV) return json({ error: 'KV not bound' }, 500, cors);
  const url = new URL(request.url);
  const key = (url.searchParams.get('key') || '').trim();
  if (key.length < 8) return json({ error: 'bad key' }, 400, cors);
  const kvKey = 'planner:' + key;
  try {
    if (request.method === 'GET') {
      const v = await env.PLANNER_KV.get(kvKey);
      return new Response(v || JSON.stringify({ data: null, ts: 0 }), { headers: Object.assign({ 'content-type': 'application/json' }, cors) });
    }
    if (request.method === 'PUT' || request.method === 'POST') {
      const body = await request.text();
        if (body.length > 5000000) return json({ error: 'too large' }, 413, cors);
        try { JSON.parse(body); } catch (e) { return json({ error: 'bad json' }, 400, cors); }
      await env.PLANNER_KV.put(kvKey, body);
      return json({ ok: true }, 200, cors);
    }
  } catch (e) {
    return json({ error: String(e) }, 500, cors);
  }
  return json({ error: 'method not allowed' }, 405, cors);
}

function json(obj, status, cors) {
  return new Response(JSON.stringify(obj), { status, headers: Object.assign({ 'content-type': 'application/json' }, cors) });
}
