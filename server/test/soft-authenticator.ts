/**
 * Minimal software WebAuthn authenticator for tests (ES256, "none" attestation, user verification on unless a call
 * passes `uv: false`). Used by test/auth.test.ts (app passkeys) and test/admin-auth.test.ts (staff passkeys).
 */
import { createHash, generateKeyPairSync, randomBytes, sign, type KeyObject } from "node:crypto";
import { isoCBOR } from "@simplewebauthn/server/helpers";
import { config } from "../src/config.ts";

/** Minimal software WebAuthn authenticator (ES256, "none" attestation, UV on). */
export class SoftAuthenticator {
  readonly credentialId = randomBytes(32);
  private readonly keys = generateKeyPairSync("ec", { namedCurve: "P-256" });
  counter = 0;
  /** Mutable so a test can replay the same credential against another relying party or origin. */
  constructor(
    public rpId = config.webauthn.rpId,
    public origin = config.webauthn.origins[0]!,
  ) {}

  private rpIdHash() {
    return createHash("sha256").update(this.rpId).digest();
  }

  private cose(): Uint8Array {
    const jwk = this.keys.publicKey.export({ format: "jwk" }) as { x: string; y: string };
    return isoCBOR.encode(
      new Map<number, number | Uint8Array>([
        [1, 2],
        [3, -7],
        [-1, 1],
        [-2, Buffer.from(jwk.x, "base64url")],
        [-3, Buffer.from(jwk.y, "base64url")],
      ]),
    );
  }

  private clientData(type: string, challenge: string, origin = this.origin) {
    return Buffer.from(JSON.stringify({ type, challenge, origin, crossOrigin: false }));
  }

  register(options: { challenge: string }, over: { origin?: string; uv?: boolean } = {}) {
    const counter = Buffer.alloc(4);
    const credIdLen = Buffer.alloc(2);
    credIdLen.writeUInt16BE(this.credentialId.length);
    const authData = Buffer.concat([
      this.rpIdHash(),
      Buffer.from([over.uv === false ? 0x41 : 0x45]), // UP | UV | AT (UV off: UP | AT)
      counter,
      Buffer.alloc(16), // aaguid
      credIdLen,
      this.credentialId,
      Buffer.from(this.cose()),
    ]);
    const attestationObject = Buffer.from(
      isoCBOR.encode(new Map<string, unknown>([["fmt", "none"], ["attStmt", new Map()], ["authData", authData]]) as never),
    );
    const id = this.credentialId.toString("base64url");
    return {
      id,
      rawId: id,
      type: "public-key" as const,
      clientExtensionResults: {},
      response: {
        clientDataJSON: this.clientData("webauthn.create", options.challenge, over.origin).toString("base64url"),
        attestationObject: attestationObject.toString("base64url"),
        transports: ["internal"],
      },
    };
  }

  assert(options: { challenge: string }, over: { counter?: number; key?: KeyObject; uv?: boolean; userHandle?: string } = {}) {
    this.counter = over.counter ?? this.counter + 1;
    const ctr = Buffer.alloc(4);
    ctr.writeUInt32BE(this.counter);
    const authData = Buffer.concat([this.rpIdHash(), Buffer.from([over.uv === false ? 0x01 : 0x05]), ctr]);
    const cdj = this.clientData("webauthn.get", options.challenge);
    const signature = sign(
      "sha256",
      Buffer.concat([authData, createHash("sha256").update(cdj).digest()]),
      over.key ?? this.keys.privateKey,
    );
    const id = this.credentialId.toString("base64url");
    return {
      id,
      rawId: id,
      type: "public-key" as const,
      clientExtensionResults: {},
      response: {
        clientDataJSON: cdj.toString("base64url"),
        authenticatorData: authData.toString("base64url"),
        signature: signature.toString("base64url"),
        ...(over.userHandle ? { userHandle: over.userHandle } : {}),
      },
    };
  }
}
