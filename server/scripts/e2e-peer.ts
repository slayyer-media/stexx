#!/usr/bin/env bun
/**
 * DEV ONLY: a scriptable end-to-end encryption chat partner for testing the iOS app against a local dev server,
 * without a second phone. It's a second libsignal client (the server's Node bindings), so it also checks that the
 * Swift and Node libsignal builds interoperate. Never point it at production: it signs up with the dev-auth
 * shortcut and the `dev-bypass` attestation header, which only a dev server accepts.
 *
 *   bun scripts/e2e-peer.ts --server http://127.0.0.1:8791 --state /tmp/peer.json init --name Rowan
 *   bun scripts/e2e-peer.ts --state /tmp/peer.json send --to <profileID> --text "Museum this weekend?"
 *   bun scripts/e2e-peer.ts --state /tmp/peer.json send --to <profileID> --photo cat.jpg [--text "caption"] \
 *       [--expires <seconds>] [--view-once]          # encrypted photo (format v1, docs/api.md), needs E2E_MODE != off
 *   bun scripts/e2e-peer.ts --state /tmp/peer.json read --with <profileID> [--save-dir /tmp/photos]
 *   bun scripts/e2e-peer.ts --state /tmp/peer.json reinstall        # new identity key → identity.changed
 *   bun scripts/e2e-peer.ts --state /tmp/peer.json session          # prints the session JSON
 *
 * The server URL is chosen once, by `init --server <url>` (any local port, e.g. a branch server started with
 * `PORT=8791`); it's saved in the --state file and used by every later command. Use one state file per peer.
 * `read` prints `photo: ok <n> bytes` / `photo: tampered` / `photo: gone` for photo messages; `--save-dir` also writes
 * `<messageID>.jpg`. Photo keys are kept in the state file (a Signal message can only be decrypted once) so a later
 * `read` can retry a photo that wasn't downloadable yet.
 *
 * `init --no-keys` creates an account without keys (a "not upgraded yet" chat partner). State (session, private
 * keys, sessions) lives in the --state file, readable only by you; delete it when done.
 */
import {
  CiphertextMessage,
  CiphertextMessageType,
  Direction,
  IdentityChange,
  IdentityKeyPair,
  IdentityKeyStore,
  KEMKeyPair,
  KEMPublicKey,
  KyberPreKeyRecord,
  KyberPreKeyStore,
  PreKeyBundle,
  PreKeyRecord,
  PreKeySignalMessage,
  PreKeyStore,
  PrivateKey,
  ProtocolAddress,
  PublicKey,
  SessionRecord,
  SessionStore,
  SignalMessage,
  SignedPreKeyRecord,
  SignedPreKeyStore,
  processPreKeyBundle,
  signalDecrypt,
  signalDecryptPreKey,
  signalEncrypt,
} from "@signalapp/libsignal-client";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { AttachmentCryptoError, decryptAttachment, encryptAttachment, type AttachmentPointer } from "./e2e-media-crypto";
import { randomUUID } from "node:crypto";
import { parseArgs } from "node:util";

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    server: { type: "string" },
    state: { type: "string", default: "/tmp/stexx-e2e-peer.json" },
    name: { type: "string", default: "Rowan" },
    to: { type: "string" },
    with: { type: "string" },
    text: { type: "string" },
    photo: { type: "string" },
    expires: { type: "string" },
    "view-once": { type: "boolean", default: false },
    "save-dir": { type: "string" },
    help: { type: "boolean", default: false },
    "no-keys": { type: "boolean", default: false },
  },
});
const command = positionals[0];

interface State {
  server: string;
  session: { userID: string; accessToken: string; refreshToken: string };
  identity?: string;
  registrationID?: number;
  records: Record<string, string>; // key → base64
  seen: string[];
  /** Photo pointers of received messages (message ID → pointer), so `read` can retry a download. */
  photos?: Record<string, AttachmentPointer>;
}

const USAGE = `DEV ONLY: scriptable end-to-end encryption chat partner (local dev servers only).

  bun scripts/e2e-peer.ts --server <http://127.0.0.1:PORT> [--state <file>] init [--name <n>] [--no-keys]
  bun scripts/e2e-peer.ts --state <file> send --to <id> [--text <t>]
  bun scripts/e2e-peer.ts --state <file> send --to <id> --photo <file.jpg> [--text <caption>] [--expires <sec>] [--view-once]
  bun scripts/e2e-peer.ts --state <file> plain --to <id> --text <t>
  bun scripts/e2e-peer.ts --state <file> read --with <id> [--save-dir <dir>]
  bun scripts/e2e-peer.ts --state <file> reinstall | session

The server URL is set by \`init --server\` (e.g. http://127.0.0.1:8791) and stored in the state file
(default /tmp/stexx-e2e-peer.json); other commands don't take --server.`;

/** Width/height from a JPEG's SOF marker (layout hint only); undefined if it can't be read. */
function jpegSize(b: Uint8Array): { width: number; height: number } | undefined {
  let i = 2;
  while (i + 9 < b.length) {
    if (b[i] !== 0xff) return undefined;
    const marker = b[i + 1]!;
    if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
      return { height: (b[i + 5]! << 8) | b[i + 6]!, width: (b[i + 7]! << 8) | b[i + 8]! };
    }
    i += 2 + ((b[i + 2]! << 8) | b[i + 3]!);
  }
  return undefined;
}

const b64 = (bytes: Uint8Array) => Buffer.from(bytes).toString("base64");
const unb64 = (s: string): Uint8Array<ArrayBuffer> => new Uint8Array(Buffer.from(s, "base64"));

function load(): State {
  if (!existsSync(opts.state!)) throw new Error(`No state at ${opts.state}; run init first.`);
  return JSON.parse(readFileSync(opts.state!, "utf8"));
}
function save(state: State) {
  // Created owner-only (tokens and private keys); chmod covers a file that already existed.
  writeFileSync(opts.state!, JSON.stringify(state, null, 2), { mode: 0o600 });
  chmodSync(opts.state!, 0o600);
}

/** Dev servers only: refuse anything that isn't this machine. */
function assertLocal(server: string) {
  const host = new URL(server).hostname;
  if (!["127.0.0.1", "localhost", "::1", "[::1]"].includes(host)) {
    throw new Error(`e2e-peer is for local dev servers only, not ${host}`);
  }
}

async function api(state: State, method: string, path: string, body?: unknown, retry = true): Promise<any> {
  const res = await fetch(`${state.server}/v1/${path}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${state.session.accessToken}`,
      "X-Stexx-Attestation": "dev-bypass",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (res.status === 401 && retry) {
    const fresh = await fetch(`${state.server}/v1/auth/refresh`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ refreshToken: state.session.refreshToken }),
    });
    if (!fresh.ok) throw new Error(`refresh failed: ${fresh.status}`);
    state.session = (await fresh.json()) as State["session"];
    save(state);
    return api(state, method, path, body, false);
  }
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status} ${text}`);
  return text ? JSON.parse(text) : null;
}

/** POST an opaque encrypted blob to /me/attachments (same dev-bypass attestation as `api`). */
async function uploadBlob(state: State, blob: Uint8Array, retry = true): Promise<{ id: string }> {
  const res = await fetch(`${state.server}/v1/me/attachments`, {
    method: "POST",
    headers: {
      "Content-Type": "application/octet-stream",
      Authorization: `Bearer ${state.session.accessToken}`,
      "X-Stexx-Attestation": "dev-bypass",
    },
    body: blob,
  });
  if (res.status === 401 && retry) {
    await api(state, "GET", "me"); // refreshes the session on 401
    return uploadBlob(state, blob, false);
  }
  const text = await res.text();
  if (!res.ok) throw new Error(`POST me/attachments → ${res.status} ${text}`);
  return JSON.parse(text);
}

/** Download, verify and decrypt a photo; "gone" for 404 / a spent or expired photo. */
async function fetchPhoto(url: string | null | undefined, pointer: AttachmentPointer): Promise<Buffer | "gone" | "tampered"> {
  if (!url) return "gone";
  const res = await fetch(url);
  if (res.status === 404) return "gone";
  if (!res.ok) throw new Error(`GET ${url} → ${res.status}`);
  try {
    return decryptAttachment(new Uint8Array(await res.arrayBuffer()), pointer);
  } catch (e) {
    if (e instanceof AttachmentCryptoError) return "tampered";
    throw e;
  }
}

/** All libsignal stores over `state.records`, persisted by `save`. */
class Stores implements SessionStore, IdentityKeyStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore {
  constructor(private state: State) {}
  private get(key: string) {
    const v = this.state.records[key];
    return v === undefined ? null : unb64(v);
  }
  private put(key: string, bytes: Uint8Array) {
    this.state.records[key] = b64(bytes);
  }
  async saveSession(a: ProtocolAddress, r: SessionRecord) { this.put(`session.${a.name()}`, r.serialize()); }
  async getSession(a: ProtocolAddress) { const v = this.get(`session.${a.name()}`); return v ? SessionRecord.deserialize(v) : null; }
  async getExistingSessions(as: ProtocolAddress[]) { return Promise.all(as.map(async (a) => (await this.getSession(a))!)); }
  async getIdentityKey() { return IdentityKeyPair.deserialize(unb64(this.state.identity!)).privateKey; }
  async getIdentityKeyPair() { return IdentityKeyPair.deserialize(unb64(this.state.identity!)); }
  async getLocalRegistrationId() { return this.state.registrationID!; }
  async saveIdentity(a: ProtocolAddress, k: PublicKey) {
    const old = this.get(`trusted.${a.name()}`);
    this.put(`trusted.${a.name()}`, k.serialize());
    return old && Buffer.compare(Buffer.from(old), Buffer.from(k.serialize())) !== 0
      ? IdentityChange.ReplacedExisting
      : IdentityChange.NewOrUnchanged;
  }
  // A test peer trusts whatever key it sees (it plays the honest partner).
  async isTrustedIdentity(_a: ProtocolAddress, _k: PublicKey, _d: Direction) { return true; }
  async getIdentity(a: ProtocolAddress) { const v = this.get(`trusted.${a.name()}`); return v ? PublicKey.deserialize(v) : null; }
  async recordReceivedIdentity() {}
  async savePreKey(id: number, r: PreKeyRecord) { this.put(`prekey.${id}`, r.serialize()); }
  async getPreKey(id: number) { return PreKeyRecord.deserialize(this.get(`prekey.${id}`)!); }
  async removePreKey(id: number) { delete this.state.records[`prekey.${id}`]; }
  async saveSignedPreKey(id: number, r: SignedPreKeyRecord) { this.put(`signed.${id}`, r.serialize()); }
  async getSignedPreKey(id: number) { return SignedPreKeyRecord.deserialize(this.get(`signed.${id}`)!); }
  async saveKyberPreKey(id: number, r: KyberPreKeyRecord) { this.put(`kyber.${id}`, r.serialize()); }
  async getKyberPreKey(id: number) { return KyberPreKeyRecord.deserialize(this.get(`kyber.${id}`)!); }
  async markKyberPreKeyUsed() {}
}

/** Fresh identity + full key set, uploaded with PUT /keys. */
async function registerKeys(state: State) {
  const identity = IdentityKeyPair.generate();
  state.identity = b64(identity.serialize());
  state.registrationID = 1 + Math.floor(Math.random() * 16380);
  state.records = Object.fromEntries(Object.entries(state.records).filter(([k]) => k.startsWith("trusted.")));
  const stores = new Stores(state);
  const base = 1 + Math.floor(Math.random() * 1_000_000);
  const sign = (pub: Uint8Array) => identity.privateKey.sign(new Uint8Array(pub));

  const signedPriv = PrivateKey.generate();
  const signedPub = signedPriv.getPublicKey().serialize();
  const signedSig = sign(signedPub);
  await stores.saveSignedPreKey(base, SignedPreKeyRecord.new(base, Date.now(), signedPriv.getPublicKey(), signedPriv, signedSig));

  const kyber = (id: number) => {
    const kp = KEMKeyPair.generate();
    const pub = kp.getPublicKey().serialize();
    const sig = sign(pub);
    void stores.saveKyberPreKey(id, KyberPreKeyRecord.new(id, Date.now(), kp, sig));
    return { keyID: id, publicKey: b64(pub), signature: b64(sig) };
  };
  const preKeys = [];
  for (let i = 1; i <= 20; i++) {
    const priv = PrivateKey.generate();
    await stores.savePreKey(base + i, PreKeyRecord.new(base + i, priv.getPublicKey(), priv));
    preKeys.push({ keyID: base + i, publicKey: b64(priv.getPublicKey().serialize()) });
  }
  const status = await api(state, "PUT", "keys", {
    registrationID: state.registrationID,
    deviceID: 1,
    identityKey: b64(identity.publicKey.serialize()),
    signedPreKey: { keyID: base, publicKey: b64(signedPub), signature: b64(signedSig) },
    pqLastResortPreKey: kyber(base + 100),
    preKeys,
    pqPreKeys: [kyber(base + 101), kyber(base + 102), kyber(base + 103)],
  });
  save(state);
  console.log(`keys registered (preKeyCount ${status.preKeyCount}, pqPreKeyCount ${status.pqPreKeyCount})`);
}

const address = (id: string) => ProtocolAddress.new(id, 1);

async function conversationWith(state: State, other: string): Promise<string> {
  return (await api(state, "POST", "conversations", { participantID: other })).id;
}

async function main() {
  if (opts.help || !command) {
    console.log(USAGE);
    process.exit(opts.help ? 0 : 1);
  }
  if (command === "init") {
    if (!opts.server) throw new Error("--server is required for init");
    assertLocal(opts.server);
    const res = await fetch(`${opts.server}/v1/auth/register`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Stexx-Attestation": "dev-bypass" },
      body: JSON.stringify({ displayName: opts.name, method: "passkey", confirmedAdult: true }),
    });
    if (!res.ok) throw new Error(`register → ${res.status} ${await res.text()}`);
    const state: State = { server: opts.server, session: (await res.json()) as State["session"], records: {}, seen: [] };
    save(state);
    if (!opts["no-keys"]) await registerKeys(state);
    console.log(state.session.userID);
    return;
  }
  const state = load();
  assertLocal(state.server);
  const stores = new Stores(state);
  const me = address(state.session.userID);
  switch (command) {
    case "session":
      console.log(JSON.stringify(state.session));
      return;
    case "reinstall":
      await registerKeys(state);
      return;
    case "send": {
      const to = opts.to!;
      const conv = await conversationWith(state, to);
      if (!(await stores.getSession(address(to)))?.hasCurrentState()) {
        const b = await api(state, "GET", `keys/bundle/${to}`);
        const d = b.devices[0];
        const bundle = PreKeyBundle.new(
          d.registrationID, d.deviceID,
          d.preKey ? d.preKey.keyID : null, d.preKey ? PublicKey.deserialize(unb64(d.preKey.publicKey)) : null,
          d.signedPreKey.keyID, PublicKey.deserialize(unb64(d.signedPreKey.publicKey)), unb64(d.signedPreKey.signature),
          PublicKey.deserialize(unb64(b.identityKey)),
          d.pqPreKey.keyID, KEMPublicKey.deserialize(unb64(d.pqPreKey.publicKey)), unb64(d.pqPreKey.signature),
        );
        await processPreKeyBundle(bundle, address(to), me, stores, stores);
      }
      let attachment: AttachmentPointer | undefined;
      let photoID: string | undefined;
      if (opts.photo) {
        const jpeg = readFileSync(opts.photo);
        const enc = encryptAttachment(jpeg, jpegSize(jpeg));
        attachment = enc.pointer;
        photoID = (await uploadBlob(state, enc.blob)).id;
      } else if (opts.text === undefined) {
        throw new Error("send needs --text or --photo");
      }
      // Photos with a timer also carry it in the payload (integer seconds, 1...2592000), the recipient's key deadline.
      // The server never learns it from the envelope; older builds ignore the unknown field.
      const timer = photoID && opts.expires ? Number(opts.expires) : undefined;
      if (timer !== undefined && !(Number.isInteger(timer) && timer >= 1 && timer <= 2_592_000)) {
        throw new Error("--expires must be an integer from 1 to 2592000");
      }
      const payload = new TextEncoder().encode(
        JSON.stringify({ text: opts.text, attachment, ...(timer !== undefined && { expiresAfterSeconds: timer }) }),
      );
      const ct: CiphertextMessage = await signalEncrypt(payload, address(to), me, stores, stores);
      const type = ct.type() === CiphertextMessageType.PreKey ? "prekey" : "signal";
      const msg = await api(state, "POST", `conversations/${conv}/messages`, {
        clientID: randomUUID(),
        envelope: { type, body: b64(ct.serialize()) },
        ...(photoID && {
          attachmentPhotoID: photoID,
          isViewOnce: opts["view-once"],
          ...(timer !== undefined && { expiresAfterSeconds: timer }),
        }),
      });
      save(state);
      console.log(`sent ${msg.id} (${type}${photoID ? ", photo" : ""})`);
      return;
    }
    case "plain": {
      const conv = await conversationWith(state, opts.to!);
      const msg = await api(state, "POST", `conversations/${conv}/messages`, { clientID: randomUUID(), text: opts.text });
      console.log(`sent ${msg.id} (plaintext)`);
      return;
    }
    case "read": {
      const other = opts.with!;
      const conv = await conversationWith(state, other);
      const page = await api(state, "GET", `conversations/${conv}/messages?limit=100`);
      for (const m of page.items) {
        const who = m.senderID === state.session.userID ? "me" : "them";
        if (!m.envelope) {
          console.log(`${who} [plaintext] ${m.text ?? "(photo)"}`);
          continue;
        }
        if (who === "me") continue;
        let payload: { text?: string; attachment?: AttachmentPointer; expiresAfterSeconds?: number } | undefined;
        if (!state.seen.includes(m.id)) {
          const body = unb64(m.envelope.body);
          const plain =
            m.envelope.type === "prekey"
              ? await signalDecryptPreKey(PreKeySignalMessage.deserialize(body), address(other), me, stores, stores, stores, stores, stores)
              : await signalDecrypt(SignalMessage.deserialize(body), address(other), me, stores, stores);
          state.seen.push(m.id);
          payload = JSON.parse(new TextDecoder().decode(plain));
          if (payload?.attachment) (state.photos ??= {})[m.id] = payload.attachment;
          save(state); // a message decrypts once; persist before anything else can fail
          const t = payload?.expiresAfterSeconds;
          const timerNote = typeof t === "number" && Number.isInteger(t) && t >= 1 && t <= 2_592_000 ? ` (timer ${t}s)` : "";
          console.log(`${who} [${m.envelope.type}] ${payload?.text ?? "(no text)"}${timerNote}`);
        }
        const pointer = state.photos?.[m.id];
        if (pointer && m.attachment) {
          const photo = await fetchPhoto(m.attachment.url, pointer);
          if (photo === "gone" || photo === "tampered") {
            console.log(`  photo: ${photo}`);
          } else {
            console.log(`  photo: ok ${photo.length} bytes${m.attachment.isViewOnce ? " (view once)" : ""}`);
            if (opts["save-dir"]) {
              mkdirSync(opts["save-dir"], { recursive: true });
              writeFileSync(join(opts["save-dir"], `${m.id}.jpg`), photo);
            }
          }
        }
      }
      save(state);
      return;
    }
    default:
      throw new Error("commands: init | session | send | plain | read | reinstall");
  }
}

await main();
