/**
 * src/lib/e2e/crypto.ts: strict base64, key formats, and the built-in XEdDSA fallback verifier checked against
 * libsignal itself (the fallback only runs if the native module can't load on a host).
 */
import { describe, expect, test } from "bun:test";
import * as S from "@signalapp/libsignal-client";
import {
  decodeBase64,
  forceBuiltinVerifierForTests,
  parseEcPublicKey,
  parseKemPublicKey,
  verifierName,
  verifyIdentitySignature,
  xeddsaVerify,
} from "../src/lib/e2e/crypto.ts";

const u8 = (b: Uint8Array) => new Uint8Array(b);

describe("built-in XEdDSA verifier", () => {
  test("agrees with libsignal on valid and tampered signatures", () => {
    let checked = 0;
    for (let i = 0; i < 150; i++) {
      const key = S.PrivateKey.generate();
      const pub = key.getPublicKey();
      // Messages like the ones we verify: serialized EC (33 B) and Kyber (1569 B) public keys, plus odd sizes.
      const msg = i % 3 === 0 ? S.KEMKeyPair.generate().getPublicKey().serialize() : crypto.getRandomValues(new Uint8Array(1 + i));
      const sig = key.sign(msg);
      expect(xeddsaVerify(pub.getPublicKeyBytes(), msg, sig)).toBe(pub.verify(msg, sig));
      expect(xeddsaVerify(pub.getPublicKeyBytes(), msg, sig)).toBe(true);
      const badSig = u8(sig);
      badSig[i % 64]! ^= 1 << (i % 8);
      expect(xeddsaVerify(pub.getPublicKeyBytes(), msg, badSig)).toBe(pub.verify(msg, badSig));
      const badMsg = u8(msg);
      badMsg[i % badMsg.length]! ^= 0x80;
      expect(xeddsaVerify(pub.getPublicKeyBytes(), badMsg, sig)).toBe(false);
      const otherKey = S.PrivateKey.generate().getPublicKey();
      expect(xeddsaVerify(otherKey.getPublicKeyBytes(), msg, sig)).toBe(false);
      checked += 1;
    }
    expect(checked).toBe(150);
  });

  test("rejects malformed inputs instead of throwing", () => {
    expect(xeddsaVerify(new Uint8Array(31), new Uint8Array(1), new Uint8Array(64))).toBe(false);
    expect(xeddsaVerify(new Uint8Array(32), new Uint8Array(1), new Uint8Array(63))).toBe(false);
    // u = p - 1 has no Edwards point.
    const pMinus1 = new Uint8Array(32).fill(0xff);
    pMinus1[0] = 0xec;
    pMinus1[31] = 0x7f;
    expect(xeddsaVerify(pMinus1, new Uint8Array(1), new Uint8Array(64))).toBe(false);
    // Top bits of s set: refused like libsignal.
    const sig = new Uint8Array(64);
    sig[63] = 0x60;
    expect(xeddsaVerify(new Uint8Array(32).fill(9), new Uint8Array(1), sig)).toBe(false);
  });

  test("verifyIdentitySignature uses libsignal here, and the fallback when forced", async () => {
    expect(await verifierName()).toBe("libsignal");
    const id = S.IdentityKeyPair.generate();
    const spk = S.PrivateKey.generate().getPublicKey().serialize();
    const sig = id.privateKey.sign(spk);
    const identity = id.publicKey.serialize();
    expect(await verifyIdentitySignature(identity, spk, sig)).toBe(true);
    const restore = forceBuiltinVerifierForTests();
    try {
      expect(await verifierName()).toBe("builtin");
      expect(await verifyIdentitySignature(identity, spk, sig)).toBe(true);
      expect(await verifyIdentitySignature(identity, spk, u8(sig).fill(0, 0, 8))).toBe(false);
    } finally {
      restore();
    }
  });
});

describe("formats", () => {
  test("decodeBase64 is strict standard base64", () => {
    expect([...decodeBase64("AAEC", "f", 10)]).toEqual([0, 1, 2]);
    for (const bad of ["", "AAE", "AA==AA==", "AA E", "AAEC\n", "AA-_", "AB==", "A==="]) {
      expect(() => decodeBase64(bad, "f", 10)).toThrow();
    }
    expect(() => decodeBase64("AAAAAAAA", "f", 5)).toThrow(); // over the size cap before decoding
  });

  test("EC and KEM keys: type byte and length (libsignal and fallback)", async () => {
    const ec = Buffer.from(S.PrivateKey.generate().getPublicKey().serialize()).toString("base64");
    const kem = Buffer.from(S.KEMKeyPair.generate().getPublicKey().serialize()).toString("base64");
    for (const forced of [false, true]) {
      const restore = forceBuiltinVerifierForTests(forced);
      try {
        expect((await parseEcPublicKey(ec, "k")).length).toBe(33);
        expect((await parseKemPublicKey(kem, "k")).length).toBe(1569);
        await expect(parseEcPublicKey(kem, "k")).rejects.toThrow();
        await expect(parseKemPublicKey(ec, "k")).rejects.toThrow();
        const wrongKemType = Buffer.from(kem, "base64");
        wrongKemType[0] = 0x07;
        await expect(parseKemPublicKey(wrongKemType.toString("base64"), "k")).rejects.toThrow();
      } finally {
        restore();
      }
    }
  });
});
