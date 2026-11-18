/**
 * A minimal Signal Protocol client for tests, built on libsignal's own Node bindings: it generates real keys,
 * uploads them in the docs/api.md wire format, builds a PreKeyBundle from GET /keys/bundle/:id exactly as the iOS
 * app will, and encrypts/decrypts message envelopes. If these tests pass, the server's wire format is something
 * libsignal can actually use.
 */
import * as S from "@signalapp/libsignal-client";

const b64 = (b: Uint8Array) => Buffer.from(b).toString("base64");
const unb64 = (s: string): Uint8Array<ArrayBuffer> => new Uint8Array(Buffer.from(s, "base64"));

class Stores {
  sessions = new Map<string, S.SessionRecord>();
  identities = new Map<string, S.PublicKey>();
  preKeys = new Map<number, S.PreKeyRecord>();
  signedPreKeys = new Map<number, S.SignedPreKeyRecord>();
  kyberPreKeys = new Map<number, S.KyberPreKeyRecord>();
  constructor(
    readonly identity: S.IdentityKeyPair,
    readonly registrationId: number,
  ) {}
}

class SessionStore extends S.SessionStore {
  constructor(private s: Stores) {
    super();
  }
  async saveSession(name: S.ProtocolAddress, record: S.SessionRecord) {
    this.s.sessions.set(name.toString(), record);
  }
  async getSession(name: S.ProtocolAddress) {
    return this.s.sessions.get(name.toString()) ?? null;
  }
  async getExistingSessions(addresses: S.ProtocolAddress[]) {
    return addresses.map((a) => this.s.sessions.get(a.toString())!).filter(Boolean);
  }
}

class IdentityStore extends S.IdentityKeyStore {
  constructor(private s: Stores) {
    super();
  }
  async getIdentityKey() {
    return this.s.identity.privateKey;
  }
  async getLocalRegistrationId() {
    return this.s.registrationId;
  }
  async saveIdentity(name: S.ProtocolAddress, key: S.PublicKey) {
    const prev = this.s.identities.get(name.name());
    this.s.identities.set(name.name(), key);
    return prev && !prev.equals(key) ? S.IdentityChange.ReplacedExisting : S.IdentityChange.NewOrUnchanged;
  }
  /** Trust on first use, like the app will (a changed key is a safety-number warning, not trusted silently). */
  async isTrustedIdentity(name: S.ProtocolAddress, key: S.PublicKey) {
    const known = this.s.identities.get(name.name());
    return !known || known.equals(key);
  }
  async getIdentity(name: S.ProtocolAddress) {
    return this.s.identities.get(name.name()) ?? null;
  }
}

class PreKeyStore extends S.PreKeyStore {
  constructor(private s: Stores) {
    super();
  }
  async savePreKey(id: number, record: S.PreKeyRecord) {
    this.s.preKeys.set(id, record);
  }
  async getPreKey(id: number) {
    const r = this.s.preKeys.get(id);
    if (!r) throw new Error(`no prekey ${id}`);
    return r;
  }
  async removePreKey(id: number) {
    this.s.preKeys.delete(id);
  }
}

class SignedPreKeyStore extends S.SignedPreKeyStore {
  constructor(private s: Stores) {
    super();
  }
  async saveSignedPreKey(id: number, record: S.SignedPreKeyRecord) {
    this.s.signedPreKeys.set(id, record);
  }
  async getSignedPreKey(id: number) {
    const r = this.s.signedPreKeys.get(id);
    if (!r) throw new Error(`no signed prekey ${id}`);
    return r;
  }
}

class KyberPreKeyStore extends S.KyberPreKeyStore {
  used = new Set<number>();
  constructor(private s: Stores) {
    super();
  }
  async saveKyberPreKey(id: number, record: S.KyberPreKeyRecord) {
    this.s.kyberPreKeys.set(id, record);
  }
  async getKyberPreKey(id: number) {
    const r = this.s.kyberPreKeys.get(id);
    if (!r) throw new Error(`no kyber prekey ${id}`);
    return r;
  }
  async markKyberPreKeyUsed(id: number) {
    this.used.add(id);
  }
}

export interface WirePreKey {
  keyID: number;
  publicKey: string;
}
export interface WireSignedKey extends WirePreKey {
  signature: string;
}
export interface Envelope {
  type: "prekey" | "signal";
  body: string;
}

let nextKeyId = 1;

export class SignalDevice {
  readonly stores: Stores;
  private sessionStore: SessionStore;
  private identityStore: IdentityStore;
  private preKeyStore: PreKeyStore;
  private signedStore: SignedPreKeyStore;
  private kyberStore: KyberPreKeyStore;
  signedPreKey!: WireSignedKey;
  pqLastResort!: WireSignedKey;

  constructor(
    readonly userId: string,
    identity = S.IdentityKeyPair.generate(),
    registrationId = 1 + Math.floor(Math.random() * 16000),
  ) {
    this.stores = new Stores(identity, registrationId);
    this.sessionStore = new SessionStore(this.stores);
    this.identityStore = new IdentityStore(this.stores);
    this.preKeyStore = new PreKeyStore(this.stores);
    this.signedStore = new SignedPreKeyStore(this.stores);
    this.kyberStore = new KyberPreKeyStore(this.stores);
    this.signedPreKey = this.newSignedPreKey();
    this.pqLastResort = this.newKyberPreKey();
  }

  get identityKey(): string {
    return b64(this.stores.identity.publicKey.serialize());
  }
  get address(): S.ProtocolAddress {
    return S.ProtocolAddress.new(this.userId, 1);
  }

  newSignedPreKey(): WireSignedKey {
    const id = nextKeyId++;
    const key = S.PrivateKey.generate();
    const pub = key.getPublicKey().serialize();
    const signature = this.stores.identity.privateKey.sign(pub);
    this.stores.signedPreKeys.set(id, S.SignedPreKeyRecord.new(id, Date.now(), key.getPublicKey(), key, signature));
    return { keyID: id, publicKey: b64(pub), signature: b64(signature) };
  }

  newKyberPreKey(): WireSignedKey {
    const id = nextKeyId++;
    const pair = S.KEMKeyPair.generate();
    const pub = pair.getPublicKey().serialize();
    const signature = this.stores.identity.privateKey.sign(pub);
    this.stores.kyberPreKeys.set(id, S.KyberPreKeyRecord.new(id, Date.now(), pair, signature));
    return { keyID: id, publicKey: b64(pub), signature: b64(signature) };
  }

  newPreKeys(n: number): WirePreKey[] {
    return Array.from({ length: n }, () => {
      const id = nextKeyId++;
      const key = S.PrivateKey.generate();
      this.stores.preKeys.set(id, S.PreKeyRecord.new(id, key.getPublicKey(), key));
      return { keyID: id, publicKey: b64(key.getPublicKey().serialize()) };
    });
  }

  newKyberPreKeys(n: number): WireSignedKey[] {
    return Array.from({ length: n }, () => this.newKyberPreKey());
  }

  /** PUT /keys body. */
  registration(opts: { preKeys?: number; pqPreKeys?: number } = {}) {
    return {
      registrationID: this.stores.registrationId,
      identityKey: this.identityKey,
      signedPreKey: this.signedPreKey,
      pqLastResortPreKey: this.pqLastResort,
      preKeys: this.newPreKeys(opts.preKeys ?? 5),
      pqPreKeys: this.newKyberPreKeys(opts.pqPreKeys ?? 2),
    };
  }

  /** Start a session from a GET /keys/bundle/:id response, exactly as the app would. */
  async processBundle(json: any): Promise<void> {
    const d = json.devices[0];
    const bundle = S.PreKeyBundle.new(
      d.registrationID,
      d.deviceID,
      d.preKey ? d.preKey.keyID : null,
      d.preKey ? S.PublicKey.deserialize(unb64(d.preKey.publicKey)) : null,
      d.signedPreKey.keyID,
      S.PublicKey.deserialize(unb64(d.signedPreKey.publicKey)),
      unb64(d.signedPreKey.signature),
      S.PublicKey.deserialize(unb64(json.identityKey)),
      d.pqPreKey.keyID,
      S.KEMPublicKey.deserialize(unb64(d.pqPreKey.publicKey)),
      unb64(d.pqPreKey.signature),
    );
    await S.processPreKeyBundle(
      bundle,
      S.ProtocolAddress.new(json.userID, d.deviceID),
      this.address,
      this.sessionStore,
      this.identityStore,
    );
  }

  async encrypt(text: string, toUserId: string): Promise<Envelope> {
    const msg = await S.signalEncrypt(
      new Uint8Array(Buffer.from(text, "utf8")),
      S.ProtocolAddress.new(toUserId, 1),
      this.address,
      this.sessionStore,
      this.identityStore,
    );
    const type = msg.type() === S.CiphertextMessageType.PreKey ? "prekey" : "signal";
    return { type, body: b64(msg.serialize()) };
  }

  async decrypt(env: Envelope, fromUserId: string): Promise<string> {
    const from = S.ProtocolAddress.new(fromUserId, 1);
    const body = unb64(env.body);
    const plain =
      env.type === "prekey"
        ? await S.signalDecryptPreKey(
            S.PreKeySignalMessage.deserialize(body),
            from,
            this.address,
            this.sessionStore,
            this.identityStore,
            this.preKeyStore,
            this.signedStore,
            this.kyberStore,
          )
        : await S.signalDecrypt(S.SignalMessage.deserialize(body), from, this.address, this.sessionStore, this.identityStore);
    return Buffer.from(plain).toString("utf8");
  }
}

/** A connection stub for lib/realtime that records every event it is sent. */
export function captureRealtime(userId: string) {
  const events: { type: string; data: any }[] = [];
  return {
    events,
    conn: {
      userId,
      sessionId: `s_test_${userId}`,
      send: (frame: string) => events.push(JSON.parse(frame)),
      close: () => {},
    },
  };
}

export { b64, unb64 };
