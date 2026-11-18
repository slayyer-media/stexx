import { DeviceCheckError, type DeviceCheckClient } from "../src/lib/abuse/devicecheck.ts";

/** In-memory DeviceCheck for tests: tokens are "device names"; "bad" tokens are rejected. */
export class FakeDeviceCheck implements DeviceCheckClient {
  bits = new Map<string, { bit0: boolean; bit1: boolean }>();
  calls: string[] = [];
  async validate(token: string) {
    this.calls.push(`validate:${token}`);
    return !token.startsWith("bad");
  }
  async query(token: string) {
    this.calls.push(`query:${token}`);
    if (token.startsWith("bad")) throw new DeviceCheckError("bad token", true);
    const b = this.bits.get(token);
    return b ? { ...b, lastUpdate: "2026-11" } : { bit0: false, bit1: false, lastUpdate: null };
  }
  async update(token: string, bits: { bit0: boolean; bit1: boolean }) {
    this.calls.push(`update:${token}:${+bits.bit0}${+bits.bit1}`);
    if (token.startsWith("bad")) throw new DeviceCheckError("bad token", true);
    this.bits.set(token, { ...bits });
  }
}
