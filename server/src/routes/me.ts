import { Hono } from "hono";
import { z } from "zod";
import { sql, type Sql } from "../db/sql.ts";
import { requireAuth } from "../lib/auth.ts";
import { snapToCell } from "../lib/distance.ts";
import { ApiError, badRequest, conflict, notFound } from "../lib/errors.ts";
import { newId } from "../lib/ids.ts";
import {
  drainMediaTrash,
  MAX_UPLOAD_BYTES,
  mediaUrl,
  MIN_ENCRYPTED_BYTES,
  sanitizeImage,
  storeBlob,
  storeJpeg,
  unlinkMedia,
} from "../lib/media.ts";
import { requirePlus } from "../lib/plus.ts";
import { rateLimit } from "../lib/ratelimit.ts";
import {
  photoColumns,
  photoJson,
  privacyJson,
  profileColumns,
  profilesFor,
  type PhotoRow,
  type PrivacyRow,
  type ProfileRow,
} from "../lib/serialize.ts";
import { DAY, isoDate } from "../lib/time.ts";
import { cleanText, idParam, locationSchema, lookingForSchema, multilineText, parseJson, positionSchema, privacySchema, tagsSchema } from "../lib/validation.ts";
import { col, notBlocked, notModerated, val, visibleToViewer } from "../lib/visibility.ts";
import { afterAccountDeleted, attest, deviceOf } from "../lib/abuse/attestation.ts";
import { deleteAccountRows, forgetDeletedAccount } from "../lib/account.ts";
import { hitAbuseLimits, subjectOf } from "../lib/abuse/limits.ts";
import { envelopeJson } from "../lib/e2e/envelope.ts";
import { e2eMode, keyStatus } from "../lib/e2e/keys.ts";
import { checkColumns, checkPhoto, flagPhotoMatches, storedPhash } from "../lib/photocheck/index.ts";
import { phashToHex } from "../lib/photocheck/phash.ts";
import type { AppEnv } from "../types.ts";

/**
 * me routes, mounted at /v1. Paths are written in full relative to /v1 (e.g. "/me", not "/").
 * Owns: GET/PATCH/DELETE /me, /me/photos*, /me/privacy, /me/location, /me/travel, /me/viewers, /me/export
 */
export const meRoutes = new Hono<AppEnv>();

meRoutes.use("/me", requireAuth);
meRoutes.use("/me/*", requireAuth);

export const MAX_PHOTOS = 6;
export const VIEWERS_WINDOW_MS = 7 * DAY;
const VIEWERS_LIMIT = 200;

// ---- GET /me ---------------------------------------------------------------------

meRoutes.get("/me", async (c) => {
  const me = c.get("userId");
  const [profile] = await profilesFor(me, [me]);
  if (!profile) throw notFound();
  return c.json(profile);
});

// ---- PATCH /me -------------------------------------------------------------------

/** Optional nullable text; empty/whitespace strings are stored as null. */
const optionalText = <S extends z.ZodType<string>>(schema: S) => schema.nullable().optional();

const patchSchema = z.strictObject({
  displayName: cleanText(30).optional(),
  age: z.number().int().min(18, "must be at least 18").max(99, "must be at most 99").nullable().optional(),
  pronouns: optionalText(cleanText(40, 0)),
  headline: optionalText(cleanText(120, 0)),
  about: optionalText(multilineText(1000)),
  heightCm: z.number().int().min(100, "must be at least 100").max(250, "must be at most 250").nullable().optional(),
  position: positionSchema.nullable().optional(),
  lookingFor: z.array(lookingForSchema).max(6).optional(),
  tags: tagsSchema.optional(),
});

interface OwnRow {
  display_name: string;
  age: number | null;
  pronouns: string | null;
  headline: string | null;
  about: string | null;
  height_cm: number | null;
  position: string | null;
  looking_for: string[];
  tags: string[];
}

/**
 * The Swift client sends a full `ProfileUpdate` and omits nil optionals to mean "cleared". So when
 * `displayName` is present the body is a full replacement (omitted nullable fields become null);
 * without it the body is a partial update (omitted fields are untouched, explicit null clears).
 */
meRoutes.patch("/me", async (c) => {
  const me = c.get("userId");
  const body = await parseJson(c, patchSchema);
  const full = body.displayName !== undefined;

  await sql.begin(async (tx) => {
    const [cur] = await tx<OwnRow[]>`
      SELECT display_name, age, pronouns, headline, about, height_cm, position, looking_for, tags
        FROM users WHERE id = ${me} FOR UPDATE`;
    if (!cur) throw notFound();
    const pick = <T>(incoming: T | null | undefined, current: T | null): T | null =>
      incoming === undefined ? (full ? null : current) : incoming;
    const blankToNull = (s: string | null) => (s === null || s === "" ? null : s);

    const next = {
      display_name: body.displayName ?? cur.display_name,
      age: pick(body.age, cur.age),
      pronouns: blankToNull(pick(body.pronouns, cur.pronouns)),
      headline: blankToNull(pick(body.headline, cur.headline)),
      about: blankToNull(pick(body.about, cur.about)),
      height_cm: pick(body.heightCm, cur.height_cm),
      position: pick(body.position, cur.position),
      looking_for: body.lookingFor ? [...new Set(body.lookingFor)] : cur.looking_for,
      tags: body.tags ? [...new Set(body.tags)] : cur.tags,
    };
    await tx`
      UPDATE users SET display_name = ${next.display_name}, age = ${next.age}, pronouns = ${next.pronouns},
             headline = ${next.headline}, about = ${next.about}, height_cm = ${next.height_cm},
             position = ${next.position}, looking_for = ${next.looking_for}, tags = ${next.tags}
       WHERE id = ${me}`;
  });

  const [profile] = await profilesFor(me, [me]);
  if (!profile) throw notFound();
  return c.json(profile);
});

// ---- DELETE /me ------------------------------------------------------------------

/**
 * Real, immediate deletion. One transaction deletes the user row; every table cascades from it
 * (sessions, photos, locations, favorites, taps, blocks, views, conversations + messages, ...), except
 * `reports`, whose reporter/reported FKs are SET NULL (reports filed are anonymized, not erased, so
 * moderation history survives). DB triggers queue every photo/attachment file into media_trash in the same
 * transaction; we then unlink them. Anything that fails to unlink stays queued for the purge job.
 * The same code (lib/account.ts) purges banned accounts after their review window.
 */
meRoutes.delete("/me", attest("optional"), async (c) => {
  const me = c.get("userId");
  await sql.begin(async (tx) => {
    if (!(await deleteAccountRows(tx, me))) throw notFound();
  });
  forgetDeletedAccount(me);
  await drainMediaTrash();
  // Frees this phone's DeviceCheck "has an account" bit once no account is left on it (never a ban bit).
  await afterAccountDeleted(deviceOf(c));
  return c.body(null, 204);
});

// ---- Photos ----------------------------------------------------------------------

async function ownPhotos(userId: string): Promise<PhotoRow[]> {
  return sql<PhotoRow[]>`
    SELECT ${photoColumns} FROM photos WHERE owner_id = ${userId} ORDER BY position`;
}

/** Raw image body (jpeg, png, webp). Re-encoded server-side: orientation applied, ALL metadata stripped. */
meRoutes.post("/me/photos", rateLimit("photoUploads"), attest("photo"), async (c) => {
  const me = c.get("userId");
  await hitAbuseLimits("photo", subjectOf(c, { deviceId: deviceOf(c).deviceId, userId: me }));
  const type = (c.req.header("Content-Type") ?? "").toLowerCase();
  if (!type.startsWith("image/")) throw badRequest("Send the photo as an image body.", "invalid_image");

  const [counted] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM photos WHERE owner_id = ${me}`;
  if ((counted?.n ?? 0) >= MAX_PHOTOS) throw conflict(`You can have at most ${MAX_PHOTOS} photos.`, "photo_limit");

  const bytes = new Uint8Array(await c.req.arrayBuffer());
  const jpeg = await sanitizeImage(bytes);
  // Label, don't reject: an explicit photo is stored (isExplicit: true) but never shown to others. If the
  // classifier is unavailable the photo stays unchecked and the background job retries (lib/photocheck).
  const check = await checkPhoto(jpeg);
  const key = await storeJpeg(jpeg);

  try {
    const row = await sql.begin(async (tx) => {
      await tx`SELECT id FROM users WHERE id = ${me} FOR UPDATE`; // serialize concurrent uploads
      const [counted] = await tx<{ n: number }[]>`SELECT count(*)::int AS n FROM photos WHERE owner_id = ${me}`;
      const n = counted?.n ?? 0;
      if (n >= MAX_PHOTOS) throw conflict(`You can have at most ${MAX_PHOTOS} photos.`, "photo_limit");
      const v = checkColumns(check);
      const [photo] = await tx<PhotoRow[]>`
        INSERT INTO photos (id, owner_id, storage_key, position, phash, is_explicit,
                            nsfw_checked_at, nsfw_model, nsfw_score, nsfw_labels)
        VALUES (${newId("photo")}, ${me}, ${key}, ${n}, ${v.phash}::bigint, ${v.is_explicit},
                ${v.nsfw_checked_at}, ${v.nsfw_model}, ${v.nsfw_score}, ${v.nsfw_labels})
        RETURNING ${photoColumns}`;
      await flagPhotoMatches(tx, { id: photo!.id, ownerId: me, phash: check.phash });
      return photo!;
    });
    return c.json(photoJson(row), 201);
  } catch (err) {
    await unlinkMedia(key).catch(() => {});
    throw err;
  }
});

// ---- Chat attachment uploads -------------------------------------------------------

/** Unsent chat uploads a user may hold at once (each expires after ATTACHMENT_UPLOAD_TTL_MS). */
export const MAX_PENDING_ATTACHMENTS = 10;

/**
 * Private upload for a photo MESSAGE, stored as a short-lived attachment upload, NOT a profile photo. So it is never
 * visible on the profile, doesn't count against the 6-photo limit or the profile upload limit, and needs no clean-up
 * delete. Returns a Photo-shaped object (plus `isEncrypted`) whose `id` is passed as `attachmentPhotoID` to
 * POST /conversations/:id/messages, or as an evidence `photoID` to POST /reports (either consumes it). Unsent uploads
 * are deleted after an hour.
 *
 * Two kinds of body, sharing the limits and the pending cap:
 *  - `image/*`: a plaintext photo, sanitized exactly like a profile photo (`.jpg`).
 *  - `application/octet-stream`: an end-to-end encrypted photo (docs/api.md "Encrypted photos"). The server can't read
 *    it, so it is stored verbatim (`.bin`): no decode, no classifier, no hash. Moderation of encrypted photos happens on
 *    the recipient's phone; the server's part is the size cap, the rate limits and attestation.
 */
meRoutes.post("/me/attachments", rateLimit("attachments"), attest("photo"), async (c) => {
  const me = c.get("userId");
  await hitAbuseLimits("photo", subjectOf(c, { deviceId: deviceOf(c).deviceId, userId: me }));
  const type = (c.req.header("Content-Type") ?? "").split(";")[0]!.trim().toLowerCase();
  const encrypted = type === "application/octet-stream";
  if (!encrypted && !type.startsWith("image/")) throw badRequest("Send the photo as an image body.", "invalid_image");
  if (encrypted && e2eMode() === "off") {
    throw badRequest("End-to-end encryption isn't switched on for this server yet.", "e2e_disabled");
  }

  const pending = async (db: Sql) => {
    const [r] = await db<{ n: number }[]>`SELECT count(*)::int AS n FROM attachment_uploads WHERE owner_id = ${me}`;
    return r?.n ?? 0;
  };
  const tooMany = () =>
    conflict(`You have too many photos waiting to be sent (max ${MAX_PENDING_ATTACHMENTS}).`, "attachment_limit");
  if ((await pending(sql)) >= MAX_PENDING_ATTACHMENTS) throw tooMany();

  const body = new Uint8Array(await c.req.arrayBuffer());
  let key: string;
  if (encrypted) {
    // The route's body limit already refuses more than MAX_UPLOAD_BYTES (413); this is the backstop.
    if (body.byteLength > MAX_UPLOAD_BYTES) throw new ApiError(413, "payload_too_large", "That upload is too large.");
    if (body.byteLength < MIN_ENCRYPTED_BYTES) throw badRequest("That encrypted photo is empty.", "invalid_attachment");
    key = await storeBlob(body);
  } else {
    key = await storeJpeg(await sanitizeImage(body));
  }
  try {
    const id = await sql.begin(async (tx) => {
      await tx`SELECT id FROM users WHERE id = ${me} FOR UPDATE`;
      if ((await pending(tx)) >= MAX_PENDING_ATTACHMENTS) throw tooMany();
      const [row] = await tx<{ id: string }[]>`
        INSERT INTO attachment_uploads (id, owner_id, storage_key, encrypted)
        VALUES (${newId("photo")}, ${me}, ${key}, ${encrypted})
        RETURNING id`;
      return row!.id;
    });
    return c.json({ id, url: mediaUrl(key), isExplicit: false, isEncrypted: encrypted }, 201);
  } catch (err) {
    await unlinkMedia(key).catch(() => {});
    throw err;
  }
});

meRoutes.delete("/me/photos/:id", async (c) => {
  const me = c.get("userId");
  const id = idParam(c, "id", "photo");
  await sql.begin(async (tx) => {
    await tx`SELECT id FROM users WHERE id = ${me} FOR UPDATE`;
    const deleted = await tx`DELETE FROM photos WHERE id = ${id} AND owner_id = ${me} RETURNING id`;
    if (deleted.length === 0) throw notFound();
    // Close the gap so positions stay 0..n-1 (unique constraint is deferred).
    await tx`
      UPDATE photos p SET position = r.rn
        FROM (SELECT id, (row_number() OVER (ORDER BY position) - 1)::smallint AS rn
                FROM photos WHERE owner_id = ${me}) r
       WHERE p.id = r.id AND p.position <> r.rn`;
  });
  await drainMediaTrash();
  return c.body(null, 204);
});

const orderSchema = z.strictObject({ photoIDs: z.array(z.string()).max(MAX_PHOTOS) });

meRoutes.put("/me/photos/order", async (c) => {
  const me = c.get("userId");
  const { photoIDs } = await parseJson(c, orderSchema);
  const rows = await sql.begin(async (tx) => {
    await tx`SELECT id FROM users WHERE id = ${me} FOR UPDATE`;
    const current = await tx<{ id: string }[]>`SELECT id FROM photos WHERE owner_id = ${me}`;
    const have = new Set(current.map((r) => r.id));
    if (new Set(photoIDs).size !== photoIDs.length || photoIDs.length !== have.size || !photoIDs.every((i) => have.has(i))) {
      throw badRequest("photoIDs must list each of your photos exactly once.");
    }
    for (const [position, id] of photoIDs.entries()) {
      await tx`UPDATE photos SET position = ${position} WHERE id = ${id} AND owner_id = ${me}`;
    }
    return tx<PhotoRow[]>`
      SELECT ${photoColumns} FROM photos WHERE owner_id = ${me} ORDER BY position`;
  });
  return c.json(rows.map(photoJson));
});

// ---- Privacy ---------------------------------------------------------------------

meRoutes.put("/me/privacy", async (c) => {
  const me = c.get("userId");
  const p = await parseJson(c, privacySchema);
  const row = await sql.begin(async (tx) => {
    const [cur] = await tx<{ incognito: boolean; plus_active: boolean }[]>`
      SELECT incognito, coalesce(plus_expires_at > now(), false) AS plus_active FROM users WHERE id = ${me} FOR UPDATE`;
    if (!cur) throw notFound();
    let incognito = p.incognito;
    if (incognito && !cur.plus_active) {
      // Turning it ON requires Stexx+. A lapsed subscriber whose stored flag is still on (and who echoes
      // the whole settings object back) just has it switched off instead of being locked out of every toggle.
      if (!cur.incognito) await requirePlus(me, tx); // throws 402
      incognito = false;
    }
    const [updated] = await tx<PrivacyRow[]>`
      UPDATE users SET hide_distance = ${p.hideDistance}, show_online_status = ${p.showOnlineStatus},
             send_read_receipts = ${p.sendReadReceipts}, expiring_photos_by_default = ${p.expiringPhotosByDefault},
             blur_explicit_photos = ${p.blurExplicitPhotos}, incognito = ${incognito}
       WHERE id = ${me}
       RETURNING hide_distance, show_online_status, send_read_receipts, expiring_photos_by_default,
                 blur_explicit_photos, incognito`;
    return updated!;
  });
  return c.json(privacyJson(row));
});

// ---- Location --------------------------------------------------------------------

/** Never trust the client's snapping: re-snap to our own 500 m grid, overwrite, keep no history. */
meRoutes.put("/me/location", async (c) => {
  const me = c.get("userId");
  const loc = await parseJson(c, locationSchema);
  const cell = snapToCell(loc.latitude, loc.longitude);
  await sql`
    INSERT INTO locations (user_id, cell_lat, cell_lon, updated_at)
    VALUES (${me}, ${cell.latitude}, ${cell.longitude}, now())
    ON CONFLICT (user_id) DO UPDATE
      SET cell_lat = EXCLUDED.cell_lat, cell_lon = EXCLUDED.cell_lon, updated_at = EXCLUDED.updated_at`;
  return c.body(null, 204);
});

/** Stexx+ travel mode: `{latitude, longitude, precisionMeters}` sets the travel cell, `null` clears it. */
meRoutes.put("/me/travel", async (c) => {
  const me = c.get("userId");
  const loc = await parseJson(c, locationSchema.nullable());
  if (loc === null) {
    // Clearing is always allowed, so a lapsed subscriber can still turn travel mode off.
    await sql`DELETE FROM travel_locations WHERE user_id = ${me}`;
    return c.body(null, 204);
  }
  await requirePlus(me);
  const cell = snapToCell(loc.latitude, loc.longitude);
  await sql`
    INSERT INTO travel_locations (user_id, cell_lat, cell_lon, updated_at)
    VALUES (${me}, ${cell.latitude}, ${cell.longitude}, now())
    ON CONFLICT (user_id) DO UPDATE
      SET cell_lat = EXCLUDED.cell_lat, cell_lon = EXCLUDED.cell_lon, updated_at = EXCLUDED.updated_at`;
  return c.body(null, 204);
});

// ---- Viewers (Stexx+) --------------------------------------------------------------

meRoutes.get("/me/viewers", async (c) => {
  const me = c.get("userId");
  await requirePlus(me);
  const rows = await sql<ProfileRow[]>`
    SELECT ${profileColumns(me)}
      FROM profile_views pv
      JOIN users u ON u.id = pv.viewer_id
      LEFT JOIN effective_locations el ON el.user_id = u.id
     WHERE pv.viewed_id = ${me}
       AND pv.viewed_at > ${new Date(Date.now() - VIEWERS_WINDOW_MS)}
       AND ${notBlocked(val(me), col("u.id"))}
       AND ${visibleToViewer(val(me), "u")}
       AND ${notModerated("u")}
     ORDER BY pv.viewed_at DESC
     LIMIT ${VIEWERS_LIMIT}`;
  return c.json(await profilesFor(me, rows.map((r) => r.id), { rows }));
});

// ---- Export ----------------------------------------------------------------------

/**
 * GDPR-style archive of everything we hold about the caller. Other people appear only as opaque ids; no
 * other user's profile, location, blocks-against-you, views-of-you or reports-about-you are included, nor
 * when they read your messages unless they send read receipts. Expired messages are left out, and incoming
 * view-once photos carry no URL (as everywhere outside the messages listing).
 * Secrets (token hashes, passkey public keys) are never included.
 */
meRoutes.get("/me/export", async (c) => {
  const me = c.get("userId");

  const [user] = await sql<
    (OwnRow &
      PrivacyRow & {
        id: string;
        confirmed_adult: boolean;
        has_email: boolean;
        plus_expires_at: Date | null;
        boost_ends_at: Date | null;
        last_active_at: Date;
        created_at: Date;
        hidden_at: Date | null;
      })[]
  >`
    SELECT id, display_name, age, pronouns, headline, about, height_cm, position, looking_for, tags,
           confirmed_adult, (email_hmac IS NOT NULL) AS has_email,
           hide_distance, show_online_status, send_read_receipts, expiring_photos_by_default,
           blur_explicit_photos, incognito, plus_expires_at, boost_ends_at, last_active_at, created_at, hidden_at
      FROM users WHERE id = ${me}`;
  if (!user) throw notFound();

  const [photos, uploads, home, travel, favorites, tapsSent, tapsReceived, blocks, views, reports, sessions, passkeys, subs, convs] =
    await Promise.all([
      ownPhotos(me),
      sql<{ id: string; storage_key: string; encrypted: boolean; created_at: Date }[]>`
        SELECT id, storage_key, encrypted, created_at FROM attachment_uploads WHERE owner_id = ${me} ORDER BY created_at`,
      sql<{ cell_lat: number; cell_lon: number; updated_at: Date }[]>`SELECT cell_lat, cell_lon, updated_at FROM locations WHERE user_id = ${me}`,
      sql<{ cell_lat: number; cell_lon: number; updated_at: Date }[]>`SELECT cell_lat, cell_lon, updated_at FROM travel_locations WHERE user_id = ${me}`,
      sql<{ target_id: string; created_at: Date }[]>`SELECT target_id, created_at FROM favorites WHERE user_id = ${me} ORDER BY created_at`,
      sql<{ to_id: string; created_at: Date }[]>`SELECT to_id, created_at FROM taps WHERE from_id = ${me} ORDER BY created_at`,
      sql<{ from_id: string; created_at: Date }[]>`SELECT from_id, created_at FROM taps WHERE to_id = ${me} ORDER BY created_at`,
      sql<{ blocked_id: string; created_at: Date }[]>`SELECT blocked_id, created_at FROM blocks WHERE blocker_id = ${me} ORDER BY created_at`,
      sql<{ viewed_id: string; viewed_at: Date }[]>`SELECT viewed_id, viewed_at FROM profile_views WHERE viewer_id = ${me} ORDER BY viewed_at`,
      sql<{ id: string; reported_id: string | null; reason: string; details: string | null; conversation_id: string | null; priority: string; status: string; created_at: Date }[]>`
        SELECT id, reported_id, reason, details, conversation_id, priority, status, created_at
          FROM reports WHERE reporter_id = ${me} ORDER BY created_at`,
      sql<{ created_at: Date; access_expires_at: Date; refresh_expires_at: Date; revoked_at: Date | null }[]>`
        SELECT created_at, access_expires_at, refresh_expires_at, revoked_at FROM sessions WHERE user_id = ${me} ORDER BY created_at`,
      sql<{ id: string; transports: string[]; created_at: Date; last_used_at: Date | null }[]>`
        SELECT id, transports, created_at, last_used_at FROM passkey_credentials WHERE user_id = ${me} ORDER BY created_at`,
      sql<{ product_id: string; expires_at: Date; environment: string }[]>`
        SELECT product_id, expires_at, environment FROM subscriptions WHERE user_id = ${me} ORDER BY expires_at`,
      sql<{ id: string; other_id: string; created_at: Date; updated_at: Date; muted: boolean; hidden: boolean; cleared_before: Date | null; last_read_at: Date | null }[]>`
        SELECT c.id, CASE WHEN c.user_a = ${me} THEN c.user_b ELSE c.user_a END AS other_id,
               c.created_at, c.updated_at, cm.muted, cm.hidden, cm.cleared_before, cm.last_read_at
          FROM conversations c JOIN conversation_members cm ON cm.conversation_id = c.id AND cm.user_id = ${me}
         WHERE c.user_a = ${me} OR c.user_b = ${me} ORDER BY c.created_at`,
    ]);

  // What the photo checks stored about each photo (docs/security.md "Photo checks"). Moderation flags are not
  // included, like reports filed against the account.
  const checks = new Map(
    (
      await sql<
        { id: string; phash: string | null; nsfw_checked_at: Date | null; nsfw_model: string | null; nsfw_score: number | null; nsfw_labels: Record<string, number> | null }[]
      >`SELECT id, phash, nsfw_checked_at, nsfw_model, nsfw_score, nsfw_labels FROM photos WHERE owner_id = ${me}`
    ).map((r) => [r.id, r]),
  );

  const msgRows = convs.length
    ? await sql<
        {
          id: string;
          conversation_id: string;
          sender_id: string;
          client_id: string;
          text: string | null;
          envelope_type: string | null;
          envelope_body: Buffer | null;
          attachment_kind: string | null;
          attachment_key: string | null;
          attachment_view_once: boolean;
          attachment_encrypted: boolean;
          sent_at: Date;
          read_at: Date | null;
          read_receipt: boolean;
          expires_at: Date | null;
        }[]
      >`
        SELECT m.id, m.conversation_id, m.sender_id, m.client_id, m.text, m.envelope_type, m.envelope_body,
               m.attachment_kind, m.attachment_key,
               m.attachment_view_once, m.attachment_encrypted, m.sent_at, m.read_at, m.read_receipt, m.expires_at
          FROM messages m
          JOIN conversation_members cm ON cm.conversation_id = m.conversation_id AND cm.user_id = ${me}
         WHERE m.conversation_id = ANY(${convs.map((x) => x.id)})
           AND (cm.cleared_before IS NULL OR m.sent_at > cm.cleared_before)
           AND (m.expires_at IS NULL OR m.expires_at > now())
           AND (m.held_at IS NULL OR m.sender_id = ${me})
         ORDER BY m.sent_at, m.id`
    : [];
  const byConv = new Map<string, (typeof msgRows)[number][]>();
  for (const m of msgRows) {
    const list = byConv.get(m.conversation_id) ?? [];
    list.push(m);
    byConv.set(m.conversation_id, list);
  }

  // Public keys only (the private keys never leave the phone).
  const encryptionKeys = await keyStatus(me);

  type EvidenceRow = { report_id: string; message_id: string | null; from_reported: boolean; sent_at: Date | null; text: string | null; has_photo: boolean };
  const evidenceRows: EvidenceRow[] = reports.length
    ? await sql<EvidenceRow[]>`
        SELECT report_id, message_id, from_reported, sent_at, text, has_photo FROM report_evidence
         WHERE report_id = ANY(${reports.map((r) => r.id)}) ORDER BY report_id, position`
    : [];
  const evidenceBy = new Map<string, EvidenceRow[]>();
  for (const e of evidenceRows) {
    const list = evidenceBy.get(e.report_id) ?? [];
    list.push(e);
    evidenceBy.set(e.report_id, list);
  }

  const archive = {
    exportedAt: isoDate(new Date()),
    notes: [
      "This is everything Stexx stores about your account.",
      "Other members appear only as opaque ids. Your email address is never stored, only a one-way hash, so it is not part of this archive.",
      "Locations are the 500 m grid cell centre we keep, never a precise position. We keep no location history.",
    ],
    account: {
      id: user.id,
      createdAt: isoDate(user.created_at),
      lastActiveAt: isoDate(user.last_active_at),
      confirmedAdult: user.confirmed_adult,
      hasEmailSignIn: user.has_email,
      stexxPlusExpiresAt: isoDate(user.plus_expires_at),
      boostEndsAt: isoDate(user.boost_ends_at),
      // Set while the account is hidden pending a moderator's review (never who reported it).
      hiddenPendingReviewSince: isoDate(user.hidden_at),
    },
    profile: {
      displayName: user.display_name,
      age: user.age,
      pronouns: user.pronouns,
      headline: user.headline,
      about: user.about,
      heightCm: user.height_cm,
      position: user.position,
      lookingFor: user.looking_for,
      tags: user.tags,
    },
    privacy: privacyJson(user),
    photos: photos.map((p) => {
      const ck = checks.get(p.id);
      const hash = storedPhash(ck?.phash ?? null);
      return {
        ...photoJson(p),
        position: p.position,
        checks: {
          perceptualHash: hash === null ? null : phashToHex(hash),
          checkedAt: isoDate(ck?.nsfw_checked_at ?? null),
          model: ck?.nsfw_model ?? null,
          explicitScore: ck?.nsfw_score ?? null,
          labels: ck?.nsfw_labels ?? null,
        },
      };
    }),
    pendingChatUploads: uploads.map((u) => ({
      id: u.id,
      url: mediaUrl(u.storage_key),
      isEncrypted: u.encrypted,
      createdAt: isoDate(u.created_at),
    })),
    location: {
      home: home[0] ? { latitude: home[0].cell_lat, longitude: home[0].cell_lon, updatedAt: isoDate(home[0].updated_at) } : null,
      travel: travel[0] ? { latitude: travel[0].cell_lat, longitude: travel[0].cell_lon, updatedAt: isoDate(travel[0].updated_at) } : null,
    },
    favorites: favorites.map((r) => ({ profileID: r.target_id, createdAt: isoDate(r.created_at) })),
    tapsSent: tapsSent.map((r) => ({ profileID: r.to_id, createdAt: isoDate(r.created_at) })),
    tapsReceived: tapsReceived.map((r) => ({ profileID: r.from_id, createdAt: isoDate(r.created_at) })),
    blocked: blocks.map((r) => ({ profileID: r.blocked_id, createdAt: isoDate(r.created_at) })),
    profilesViewed: views.map((r) => ({ profileID: r.viewed_id, viewedAt: isoDate(r.viewed_at) })),
    reportsFiled: reports.map((r) => ({
      id: r.id,
      profileID: r.reported_id,
      reason: r.reason,
      details: r.details,
      conversationID: r.conversation_id,
      priority: r.priority,
      status: r.status,
      createdAt: isoDate(r.created_at),
      // Messages you chose to share with moderators (deleted after the report is closed).
      evidence: (evidenceBy.get(r.id) ?? []).map((e) => ({
        messageID: e.message_id,
        fromReported: e.from_reported,
        sentAt: isoDate(e.sent_at),
        text: e.text,
        hasPhoto: e.has_photo,
      })),
    })),
    conversations: convs.map((cv) => ({
      id: cv.id,
      participantID: cv.other_id,
      createdAt: isoDate(cv.created_at),
      updatedAt: isoDate(cv.updated_at),
      isMuted: cv.muted,
      isHidden: cv.hidden,
      clearedBefore: isoDate(cv.cleared_before),
      lastReadAt: isoDate(cv.last_read_at),
      messages: (byConv.get(cv.id) ?? []).map((m) => {
        const mine = m.sender_id === me;
        // Same rules as the chat views: the other person's read time (and the expiry it starts) is theirs, not
        // ours, unless they send read receipts; a view-once photo is only released (and marked opened) by
        // GET /conversations/:id/messages, never by the archive.
        const hideRead = mine && m.read_at !== null && !m.read_receipt;
        return {
          id: m.id,
          senderID: m.sender_id,
          clientID: m.client_id,
          text: m.text,
          // End-to-end encrypted: the server holds only this ciphertext; the text lives in the apps.
          envelope: envelopeJson(m.envelope_type, m.envelope_body),
          attachment: m.attachment_kind
            ? {
                kind: m.attachment_kind,
                url: !mine && m.attachment_view_once ? null : mediaUrl(m.attachment_key),
                isViewOnce: m.attachment_view_once,
                // The key to an encrypted photo is inside `envelope`; the archive holds only the opaque blob's URL.
                isEncrypted: m.attachment_encrypted,
              }
            : null,
          sentAt: isoDate(m.sent_at),
          readAt: hideRead ? null : isoDate(m.read_at),
          expiresAt: hideRead ? null : isoDate(m.expires_at),
        };
      }),
    })),
    encryptionKeys,
    subscriptions: subs.map((s) => ({ productID: s.product_id, expiresAt: isoDate(s.expires_at), environment: s.environment })),
    signIn: {
      passkeys: passkeys.map((p) => ({
        credentialID: p.id,
        transports: p.transports,
        createdAt: isoDate(p.created_at),
        lastUsedAt: isoDate(p.last_used_at),
      })),
      sessions: sessions.map((s) => ({
        createdAt: isoDate(s.created_at),
        accessExpiresAt: isoDate(s.access_expires_at),
        refreshExpiresAt: isoDate(s.refresh_expires_at),
        revokedAt: isoDate(s.revoked_at),
      })),
    },
  };

  c.header("Content-Disposition", 'attachment; filename="stexx-export.json"');
  return c.json(archive);
});
