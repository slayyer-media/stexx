/**
 * Minimal DER (ASN.1) reader: just enough to walk an X.509 certificate to its extensions and read the
 * App Attest nonce extension. Rejects indefinite lengths and anything that runs past its parent.
 */

export interface DerNode {
  /** Full identifier octet (class + constructed bit + tag number < 31). */
  tag: number;
  /** Content octets. */
  value: Uint8Array;
}

export class DerError extends Error {
  override name = "DerError";
}

/** Read one TLV at `offset`. Returns the node and the offset just past it. */
export function readNode(buf: Uint8Array, offset = 0): { node: DerNode; next: number } {
  if (offset + 2 > buf.length) throw new DerError("truncated header");
  const tag = buf[offset]!;
  if ((tag & 0x1f) === 0x1f) throw new DerError("high tag numbers are not supported");
  let len = buf[offset + 1]!;
  let pos = offset + 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n === 0 || n > 4) throw new DerError("unsupported length");
    if (pos + n > buf.length) throw new DerError("truncated length");
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + buf[pos + i]!;
    pos += n;
  }
  const end = pos + len;
  if (end > buf.length) throw new DerError("value runs past the buffer");
  return { node: { tag, value: buf.subarray(pos, end) }, next: end };
}

/** Children of a constructed node. */
export function children(node: DerNode): DerNode[] {
  if (!(node.tag & 0x20)) throw new DerError("not a constructed node");
  const out: DerNode[] = [];
  let pos = 0;
  while (pos < node.value.length) {
    const { node: child, next } = readNode(node.value, pos);
    out.push(child);
    pos = next;
  }
  return out;
}

/** Parse a whole buffer as exactly one node. */
export function parseOne(buf: Uint8Array): DerNode {
  const { node, next } = readNode(buf, 0);
  if (next !== buf.length) throw new DerError("trailing bytes");
  return node;
}

/** DER encoding of an OBJECT IDENTIFIER's content octets, e.g. "1.2.840.113635.100.8.2". */
export function encodeOid(oid: string): Uint8Array {
  const parts = oid.split(".").map((p) => Number(p));
  if (parts.length < 2 || parts.some((p) => !Number.isInteger(p) || p < 0)) throw new DerError("bad oid");
  const bytes: number[] = [parts[0]! * 40 + parts[1]!];
  for (const part of parts.slice(2)) {
    const stack: number[] = [part & 0x7f];
    let v = Math.floor(part / 128);
    while (v > 0) {
      stack.unshift((v & 0x7f) | 0x80);
      v = Math.floor(v / 128);
    }
    bytes.push(...stack);
  }
  return Uint8Array.from(bytes);
}

const SEQUENCE = 0x30;
const OID = 0x06;
const BOOLEAN = 0x01;
const OCTET_STRING = 0x04;
const EXTENSIONS = 0xa3; // [3] EXPLICIT in TBSCertificate

function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

/**
 * The extnValue (content of the OCTET STRING) of the extension `oid` in a DER certificate, or null if absent.
 * Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }; extensions are [3] in the TBS.
 */
export function certificateExtension(certDer: Uint8Array, oid: string): Uint8Array | null {
  const cert = parseOne(certDer);
  if (cert.tag !== SEQUENCE) throw new DerError("certificate is not a SEQUENCE");
  const tbs = children(cert)[0];
  if (!tbs || tbs.tag !== SEQUENCE) throw new DerError("missing tbsCertificate");
  const extWrapper = children(tbs).find((n) => n.tag === EXTENSIONS);
  if (!extWrapper) return null;
  const extList = children(extWrapper)[0];
  if (!extList || extList.tag !== SEQUENCE) throw new DerError("bad extensions");
  const want = encodeOid(oid);
  for (const ext of children(extList)) {
    if (ext.tag !== SEQUENCE) throw new DerError("bad extension");
    const parts = children(ext);
    const id = parts[0];
    if (!id || id.tag !== OID || !equalBytes(id.value, want)) continue;
    const valueNode = parts[1]?.tag === BOOLEAN ? parts[2] : parts[1];
    if (!valueNode || valueNode.tag !== OCTET_STRING) throw new DerError("bad extension value");
    return valueNode.value;
  }
  return null;
}
