#!/usr/bin/env node
import crypto from 'node:crypto';

const DEFAULT_NOSTR_TOOLS = new URL('../../autopilot/node_modules/nostr-tools/lib/esm/index.js', import.meta.url).href;

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (!value.startsWith('--')) continue;
    const key = value.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    const next = argv[i + 1];
    if (!next || next.startsWith('--')) {
      args[key] = true;
    } else {
      args[key] = next;
      i += 1;
    }
  }
  return args;
}

function usage() {
  return `Usage: tools/tower_drive_smoke.mjs --workspace-id <id> [--scope-id <id>] [--channel-id <id>] [--file-id <id>]

Environment:
  TOWER_URL              Tower base URL, default http://127.0.0.1:3100
  FLIGHTDECK_APP_NPUB   Flight Deck app npub
  WINGMAN_NSEC          Hex or nsec key used for NIP-98 signing
  NOSTR_TOOLS_ESM       Optional nostr-tools ESM path or URL
`;
}

async function loadNostrTools() {
  const ref = process.env.NOSTR_TOOLS_ESM || DEFAULT_NOSTR_TOOLS;
  return import(ref);
}

function secretFromEnv(nip19) {
  const raw = (process.env.WINGMAN_NSEC || process.env.WINGMAN_PRIV || process.env.AGENT_NSEC || '').trim();
  if (!raw) {
    throw new Error('Missing WINGMAN_NSEC, WINGMAN_PRIV, or AGENT_NSEC');
  }
  if (raw.startsWith('nsec')) {
    return Buffer.from(nip19.decode(raw).data);
  }
  return Buffer.from(raw, 'hex');
}

function cursorZero() {
  return Buffer.from(JSON.stringify({ version: 1, rowVersion: 0 }), 'utf8').toString('base64url');
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || !args.workspaceId) {
    console.log(usage());
    process.exit(args.help ? 0 : 1);
  }

  const towerUrl = String(args.towerUrl || process.env.TOWER_URL || 'http://127.0.0.1:3100').replace(/\/$/, '');
  const appNpub = String(args.appNpub || process.env.FLIGHTDECK_APP_NPUB || '').trim();
  if (!appNpub) throw new Error('Missing FLIGHTDECK_APP_NPUB or --app-npub');

  const { finalizeEvent, getPublicKey, nip19 } = await loadNostrTools();
  const secret = secretFromEnv(nip19);
  const signerPubkey = getPublicKey(secret);
  const signerNpub = nip19.npubEncode(signerPubkey);
  const checks = [];

  async function request(name, method, path, body) {
    const url = `${towerUrl}${path}`;
    const bodyText = body === undefined ? '' : JSON.stringify(body);
    const tags = [['u', url], ['method', method.toUpperCase()]];
    if (bodyText) tags.push(['payload', crypto.createHash('sha256').update(bodyText).digest('hex')]);
    const event = finalizeEvent({
      kind: 27235,
      created_at: Math.floor(Date.now() / 1000),
      tags,
      content: '',
    }, secret);
    const headers = {
      Accept: 'application/json',
      Authorization: `Nostr ${Buffer.from(JSON.stringify(event)).toString('base64')}`,
      'x-flightdeck-pg-app-npub': appNpub,
    };
    if (bodyText) headers['Content-Type'] = 'application/json';
    const response = await fetch(url, {
      method,
      headers,
      body: bodyText || undefined,
    });
    const text = await response.text();
    let json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = { raw: text };
    }
    const check = { name, method, path, status: response.status, ok: response.ok };
    if (!response.ok) check.error = json?.error || json?.message || text.slice(0, 200);
    checks.push(check);
    if (!response.ok) throw Object.assign(new Error(`${name} failed with ${response.status}`), { check, json });
    return json;
  }

  const workspaceId = encodeURIComponent(args.workspaceId);
  await request('workspaces', 'GET', '/api/v4/flightdeck-pg/workspaces');
  await request('workspace_descriptor', 'GET', `/api/v4/flightdeck-pg/workspaces/${workspaceId}/descriptor`);
  await request('workspace_me', 'GET', `/api/v4/flightdeck-pg/workspaces/${workspaceId}/me`);
  const scopes = await request('scopes', 'GET', `/api/v4/flightdeck-pg/workspaces/${workspaceId}/scopes`);
  checks.at(-1).count = scopes.scopes?.length ?? scopes.items?.length ?? null;

  if (args.scopeId) {
    const scopeId = encodeURIComponent(args.scopeId);
    const channels = await request('channels', 'GET', `/api/v4/flightdeck-pg/workspaces/${workspaceId}/scopes/${scopeId}/channels?limit=200`);
    checks.at(-1).count = channels.channels?.length ?? channels.items?.length ?? null;
  }

  if (args.channelId) {
    const channelId = encodeURIComponent(args.channelId);
    const folders = await request('file_folders', 'GET', `/api/v4/flightdeck-pg/workspaces/${workspaceId}/channels/${channelId}/file-folders?limit=200`);
    checks.at(-1).count = folders.folders?.length ?? folders.items?.length ?? null;
    const files = await request('files', 'GET', `/api/v4/flightdeck-pg/workspaces/${workspaceId}/channels/${channelId}/files?limit=200`);
    checks.at(-1).count = files.files?.length ?? files.items?.length ?? null;
  }

  await request('events', 'GET', `/api/v4/flightdeck-pg/workspaces/${workspaceId}/events?cursor=${cursorZero()}&limit=50`);

  if (args.fileId) {
    const fileId = encodeURIComponent(args.fileId);
    const object = await request('file_object', 'GET', `/api/v4/flightdeck-pg/workspaces/${workspaceId}/files/${fileId}/object`);
    checks.at(-1).size_bytes = object.body?.size_bytes ?? object.object?.size_bytes ?? null;
  }

  console.log(JSON.stringify({ ok: true, signer_npub: signerNpub, tower_url: towerUrl, checks }, null, 2));
}

main().catch((error) => {
  const output = {
    ok: false,
    error: error instanceof Error ? error.message : String(error),
    check: error?.check ?? null,
  };
  console.error(JSON.stringify(output, null, 2));
  process.exit(1);
});
