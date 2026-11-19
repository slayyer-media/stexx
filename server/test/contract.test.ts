/**
 * Wire contract with the iOS client. The zod schemas below mirror the Swift Codable models in
 * ios/Stexx/Models/*.swift field for field:
 *  - a Swift non-Optional property is a required key (synthesized Decodable ignores property defaults, so
 *    `var isMuted: Bool = false` is still required);
 *  - a Swift Optional may be absent or null (`swiftOptional`);
 *  - enums accept exactly the Swift raw values; Int fields must be integers; URL fields absolute URLs;
 *  - dates are ISO 8601 UTC with NO fractional seconds (docs/api.md, and our own rule).
 * On top of what Swift would accept, `emitsEveryKey` asserts the server's stricter promise: every key is
 * always present (optionals are emitted as null) and nothing extra is sent.
 */
import { describe, expect, test } from "bun:test";
import { z } from "zod";
import { addConnection, removeConnection, type Connection } from "../src/lib/realtime.ts";
import { as, createUser, expectJson, makeJpeg, near, post, randomCell, sql, uniq, type TestUser } from "./helpers.ts";

// ---- Swift model mirrors -------------------------------------------------------------------------

const ISO_DATE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
/** Swift `Date` via JSONDecoder.stexx(), held to the no-fractional-seconds wire rule. */
const SwiftDate = z.string().regex(ISO_DATE, "ISO 8601 UTC without fractional seconds");
/** Swift `Int`. */
const SwiftInt = z.number().int();
/** Swift `Double`. */
const SwiftDouble = z.number();
/** Swift `URL` (absolute). */
const SwiftURL = z.string().regex(/^https?:\/\/[^\s/]+\/\S+$/);
/** Swift `T?`: the key may be missing or null. */
const swiftOptional = <T extends z.ZodType>(t: T) => t.nullable().optional();

const ID = (prefix: string) => z.string().regex(new RegExp(`^${prefix}_[A-Za-z0-9]+$`));

// enum Position: String
const Position = z.enum(["top", "versTop", "versatile", "versBottom", "bottom", "side"]);
// enum LookingFor: String
const LookingFor = z.enum(["chat", "dates", "friends", "relationship", "networking", "rightNow"]);

// struct Photo { let id; var url: URL?; var isExplicit: Bool = false }
const Photo = z.strictObject({
  id: ID("ph"),
  url: swiftOptional(SwiftURL),
  isExplicit: z.boolean(),
});

// struct Profile
const Profile = z.strictObject({
  id: ID("p"),
  displayName: z.string(),
  age: swiftOptional(SwiftInt),
  pronouns: swiftOptional(z.string()),
  headline: swiftOptional(z.string()),
  about: swiftOptional(z.string()),
  heightCm: swiftOptional(SwiftInt),
  position: swiftOptional(Position),
  lookingFor: z.array(LookingFor),
  tags: z.array(z.string()),
  photos: z.array(Photo),
  distanceMeters: swiftOptional(SwiftDouble),
  isOnline: z.boolean(),
  lastActiveAt: swiftOptional(SwiftDate),
  isFavorite: z.boolean(),
});

// struct Message.Attachment { var kind: Kind; var url: URL?; var isViewOnce: Bool = false; var isEncrypted: Bool = false;
// var openedAt: Date? }
// (isEncrypted is decoded with decodeIfPresent, so older servers and the mock may omit it; this server always sends it.)
const Attachment = z.strictObject({
  kind: z.enum(["photo"]),
  url: swiftOptional(SwiftURL),
  isViewOnce: z.boolean(),
  isEncrypted: z.boolean(),
  openedAt: swiftOptional(SwiftDate),
});

// E2E envelope (docs/api.md "End-to-end encryption"). The Swift model doesn't decode it yet (iOS phase pending);
// synthesized Decodable ignores unknown keys, so today's app keeps working.
const Envelope = z.strictObject({ type: z.enum(["prekey", "signal"]), body: z.string().min(1) });

// struct Message (status raw values: sending | sent | delivered | read | failed; the server only sends the middle three)
const Message = z.strictObject({
  id: ID("m"),
  conversationID: ID("c"),
  senderID: ID("p"),
  text: swiftOptional(z.string()),
  envelope: swiftOptional(Envelope),
  attachment: swiftOptional(Attachment),
  sentAt: SwiftDate,
  status: z.enum(["sent", "delivered", "read"]),
  expiresAt: swiftOptional(SwiftDate),
  clientID: swiftOptional(z.string()),
});

// struct Conversation { ...; var isMuted: Bool = false }
const Conversation = z.strictObject({
  id: ID("c"),
  participant: Profile,
  lastMessage: swiftOptional(Message),
  unreadCount: SwiftInt,
  updatedAt: SwiftDate,
  isMuted: z.boolean(),
});

// struct Page<Item>
const Page = <T extends z.ZodType>(item: T) => z.strictObject({ items: z.array(item), nextCursor: swiftOptional(z.string()) });

// struct Session { let userID; var accessToken; var refreshToken: String?; var expiresAt: Date? }
const Session = z.strictObject({
  userID: ID("p"),
  accessToken: z.string().min(1),
  refreshToken: swiftOptional(z.string().min(1)),
  expiresAt: swiftOptional(SwiftDate),
});

// struct PrivacySettings (all Bool with defaults: all required for synthesized Decodable)
const PrivacySettings = z.strictObject({
  hideDistance: z.boolean(),
  showOnlineStatus: z.boolean(),
  sendReadReceipts: z.boolean(),
  expiringPhotosByDefault: z.boolean(),
  blurExplicitPhotos: z.boolean(),
  incognito: z.boolean(),
});

// struct Profile, own copy (GET/PATCH /me): `var travel: TravelStatus?` (struct TravelStatus { var isActive: Bool })
// and `var privacy: PrivacySettings?`. Other people's profiles never carry either (Profile is strict above).
const OwnProfile = Profile.extend({
  travel: swiftOptional(z.strictObject({ isActive: z.boolean() })),
  privacy: swiftOptional(PrivacySettings),
});

// struct SubscriptionStatus { var isActive: Bool; var expiresAt: Date?; var willRenew: Bool?; var boostEndsAt: Date? }
const SubscriptionStatus = z.strictObject({
  isActive: z.boolean(),
  expiresAt: swiftOptional(SwiftDate),
  willRenew: swiftOptional(z.boolean()),
  boostEndsAt: swiftOptional(SwiftDate),
});
// struct Boost { var endsAt: Date }
const Boost = z.strictObject({ endsAt: SwiftDate });
// HTTPAPIClient.ErrorBody { code: String?; message: String? } (docs/api.md: both always present)
const ErrorBody = z.strictObject({ code: z.string().min(1), message: z.string().min(1) });

// RealtimeEvent: { type, data | payload }. We always send `data`.
// ReadReceipt { conversationID; readerID?; readAt?; messageIDs? }
const ReadReceipt = z.strictObject({
  conversationID: ID("c"),
  readerID: swiftOptional(ID("p")),
  readAt: swiftOptional(SwiftDate),
  messageIDs: swiftOptional(z.array(ID("m"))),
});
// TapPayload { from: Profile; sentAt: Date? }
const TapPayload = z.strictObject({ from: Profile, sentAt: swiftOptional(SwiftDate) });
const Event = z.discriminatedUnion("type", [
  z.strictObject({ type: z.literal("message.created"), data: Message }),
  z.strictObject({ type: z.literal("message.updated"), data: Message }),
  z.strictObject({ type: z.literal("message.read"), data: ReadReceipt }),
  z.strictObject({ type: z.literal("conversation.updated"), data: Conversation }),
  z.strictObject({ type: z.literal("tap.received"), data: TapPayload }),
]);

// ---- helpers --------------------------------------------------------------------------------------

/** Every key of a strict object schema is present in `value` (optionals emitted as null), recursively. */
function emitsEveryKey(schema: unknown, value: unknown, path = "$"): void {
  let s: any = schema;
  // unwrap optional/nullable/array wrappers
  while (s instanceof z.ZodOptional || s instanceof z.ZodNullable) s = s.unwrap();
  if (value === null || value === undefined) return;
  if (s instanceof z.ZodArray) {
    (value as unknown[]).forEach((v, i) => emitsEveryKey(s.element, v, `${path}[${i}]`));
    return;
  }
  if (s instanceof z.ZodObject) {
    const shape = s.shape as Record<string, any>;
    for (const key of Object.keys(shape)) {
      if (!Object.hasOwn(value as object, key)) throw new Error(`${path}.${key} is missing (optionals must be emitted as null)`);
      emitsEveryKey(shape[key], (value as Record<string, unknown>)[key], `${path}.${key}`);
    }
  }
}

/** Parse with the Swift mirror (throws with the exact path on mismatch) and check the emit-all-keys promise. */
function conforms<T extends z.ZodType>(schema: T, value: unknown, label: string): z.infer<T> {
  const r = schema.safeParse(value);
  if (!r.success) {
    throw new Error(`${label} does not match the Swift model:\n${r.error.issues.map((i) => `  ${i.path.join(".")}: ${i.message}`).join("\n")}\n${JSON.stringify(value)}`);
  }
  emitsEveryKey(schema, value, label);
  return r.data;
}

async function body<T extends z.ZodType>(res: Response, schema: T, label: string, status = 200): Promise<z.infer<T>> {
  return conforms(schema, await expectJson(res, status), label);
}

function listen(user: TestUser) {
  const frames: unknown[] = [];
  const conn: Connection = { userId: user.id, sessionId: `s_${uniq()}`, send: (d) => frames.push(JSON.parse(d)), close() {} };
  addConnection(conn);
  return { frames, stop: () => removeConnection(conn) };
}

async function waitFor(frames: unknown[], pred: (f: any) => boolean, ms = 3000): Promise<any> {
  const end = Date.now() + ms;
  for (;;) {
    const hit = frames.find(pred);
    if (hit) return hit;
    if (Date.now() > end) throw new Error(`no matching frame; got ${JSON.stringify(frames)}`);
    await Bun.sleep(20);
  }
}

// ---- tests ----------------------------------------------------------------------------------------

describe("contract: schemas reject what Swift would reject", () => {
  test("self-check of the mirrors", () => {
    const profile = {
      id: "p_abc", displayName: "A", age: null, pronouns: null, headline: null, about: null, heightCm: null,
      position: null, lookingFor: [], tags: [], photos: [], distanceMeters: null, isOnline: false,
      lastActiveAt: null, isFavorite: false,
    };
    expect(Profile.safeParse(profile).success).toBe(true);
    expect(Profile.safeParse({ ...profile, lastActiveAt: "2026-11-17T20:30:00.000Z" }).success).toBe(false);
    expect(Profile.safeParse({ ...profile, age: 30.5 }).success).toBe(false);
    expect(Profile.safeParse({ ...profile, position: "Top" }).success).toBe(false);
    expect(Profile.safeParse({ ...profile, lookingFor: ["hookups"] }).success).toBe(false);
    const { isOnline: _, ...noOnline } = profile;
    expect(Profile.safeParse(noOnline).success).toBe(false); // non-Optional Bool is required
    const { age: __, ...noAge } = profile;
    expect(Profile.safeParse(noAge).success).toBe(true); // Swift accepts a missing Optional...
    expect(() => emitsEveryKey(Profile, noAge)).toThrow(/age is missing/); // ...but we always emit it
    expect(Photo.safeParse({ id: "ph_1", url: "not a url", isExplicit: false }).success).toBe(false);
    expect(Photo.safeParse({ id: "ph_1", url: null }).success).toBe(false); // isExplicit required despite default
  });
});

describe("contract: REST responses match the Swift models", () => {
  test("auth: register and refresh return Session", async () => {
    const reg = await post("/v1/auth/register", {
      json: { displayName: `C${uniq()}`.slice(0, 30), method: "email", email: `c-${uniq()}@example.com`, confirmedAdult: true },
    });
    const session = await body(reg, Session, "Session");
    expect(session.refreshToken).toBeString();
    expect(session.expiresAt).toBeString();
    await body(await post("/v1/auth/refresh", { json: { refreshToken: session.refreshToken } }), Session, "Session(refresh)");
    conforms(ErrorBody, await (await post("/v1/auth/refresh", { json: { refreshToken: "x".repeat(43) } })).json(), "Error(401)");
  });

  test("me: Profile, Photo, [Photo], PrivacySettings, viewers, errors", async () => {
    const home = randomCell();
    const me = await createUser({ location: home });
    const api = as(me);

    // ProfileUpdate exactly as Swift encodes it (nil optionals omitted).
    const updated = await body(
      await api.patch("/v1/me", {
        json: { displayName: "Contract", age: 33, heightCm: 178, position: "versBottom", lookingFor: ["chat", "rightNow"], tags: ["Books"] },
      }),
      OwnProfile,
      "Profile(PATCH /me)",
    );
    expect(updated.pronouns).toBeNull();
    expect(updated.distanceMeters).toBeNull();

    const p1 = await body(await api.post("/v1/me/photos", { body: await makeJpeg(), contentType: "image/jpeg" }), Photo, "Photo", 201);
    const p2 = await body(await api.post("/v1/me/photos", { body: await makeJpeg(), contentType: "image/jpeg" }), Photo, "Photo", 201);
    const order = await body(await api.put("/v1/me/photos/order", { json: { photoIDs: [p2.id, p1.id] } }), z.array(Photo), "[Photo]");
    expect(order.map((p) => p.id)).toEqual([p2.id, p1.id]);
    const full = await body(await api.get("/v1/me"), OwnProfile, "Profile(GET /me)");
    expect(full.travel).toBeNull();
    expect(full.photos).toHaveLength(2);
    expect(full.lastActiveAt).toBeString();

    const privacy = {
      hideDistance: false, showOnlineStatus: true, sendReadReceipts: true,
      expiringPhotosByDefault: false, blurExplicitPhotos: true, incognito: false,
    };
    expect(await body(await api.put("/v1/me/privacy", { json: privacy }), PrivacySettings, "PrivacySettings")).toEqual(privacy);
    expect((await body(await api.get("/v1/me"), OwnProfile, "Profile(GET /me)")).privacy).toEqual(privacy);
    conforms(ErrorBody, await (await api.get("/v1/me/viewers")).json(), "Error(402)");

    const plus = await createUser({ location: home, plusDays: 5 });
    await as(me).get(`/v1/profiles/${plus.id}`); // me views plus
    const viewers = await body(await as(plus).get("/v1/me/viewers"), z.array(Profile), "[Profile](viewers)");
    expect(viewers.map((v) => v.id)).toContain(me.id);
  });

  test("discovery: Page<Profile> with a cursor, Profile, 404 error body", async () => {
    const home = randomCell();
    const me = await createUser({ location: home, plusDays: 2 });
    const others = await Promise.all(
      [150, 700, 2600, 9000].map((m, i) =>
        createUser({ location: near(home, m), age: 25 + i, position: "side", lookingFor: ["friends"], tags: ["Tea"],
          privacy: i === 3 ? { hide_distance: true, show_online_status: false } : {} }),
      ),
    );
    const first = await body(await as(me).get("/v1/nearby?limit=2"), Page(Profile), "Page<Profile>");
    expect(first.items).toHaveLength(2);
    expect(first.nextCursor).toBeString();
    const rest = await body(await as(me).get(`/v1/nearby?limit=100&cursor=${encodeURIComponent(first.nextCursor!)}`), Page(Profile), "Page<Profile>(2)");
    const all = [...first.items, ...rest.items];
    for (const o of others) expect(all.map((p) => p.id)).toContain(o.id);
    const hidden = all.find((p) => p.id === others[3]!.id)!;
    expect(hidden.distanceMeters).toBeNull();
    expect(hidden.lastActiveAt).toBeNull();

    // the Swift client's advanced-filter query encoding
    await body(
      await as(me).get("/v1/nearby?limit=60&onlineOnly=true&lookingFor=friends&minAge=18&maxAge=99&maxDistanceMeters=5000&position=side&tag=Tea"),
      Page(Profile),
      "Page<Profile>(filters)",
    );
    await body(await as(me).get(`/v1/profiles/${others[0]!.id}`), Profile, "Profile(GET /profiles/:id)");
    conforms(ErrorBody, await (await as(me).get("/v1/profiles/p_doesnotexist")).json(), "Error(404)");
  });

  test("chat: Conversation, Message (text, attachment, expiring, read), Page<Message> with cursor", async () => {
    const a = await createUser();
    const b = await createUser();
    const conv = await body(await as(a).post("/v1/conversations", { json: { participantID: b.id } }), Conversation, "Conversation(open)");
    expect(conv.lastMessage).toBeNull();
    const url = `/v1/conversations/${conv.id}/messages`;

    const photo = await body(await as(a).post("/v1/me/photos", { body: await makeJpeg(), contentType: "image/jpeg" }), Photo, "Photo", 201);
    const sent: z.infer<typeof Message>[] = [];
    // MessageDraft exactly as Swift encodes it (nil optionals omitted).
    sent.push(await body(await as(a).post(url, { json: { clientID: crypto.randomUUID().toUpperCase(), text: "hi" } }), Message, "Message(text)"));
    sent.push(await body(await as(a).post(url, { json: { clientID: crypto.randomUUID().toUpperCase(), attachmentPhotoID: photo.id } }), Message, "Message(photo)"));
    sent.push(await body(await as(a).post(url, { json: { clientID: crypto.randomUUID().toUpperCase(), text: "poof", expiresAfterSeconds: 600 } }), Message, "Message(expiring)"));
    expect(sent[1]!.attachment).toMatchObject({ kind: "photo" });
    // A view-once photo, opened by the recipient (POST .../open → Message).
    sent.push(await body(await as(a).post(url, { json: { clientID: crypto.randomUUID().toUpperCase(), attachmentPhotoID: photo.id, isViewOnce: true } }), Message, "Message(view-once)"));
    expect(sent.every((m) => m.status === "sent" && m.clientID)).toBe(true);
    const opened = await body(await as(b).post(`${url}/${sent[3]!.id}/open`), Message, "Message(opened)");
    expect(opened.attachment?.isViewOnce).toBe(true);
    expect(opened.attachment?.openedAt).toMatch(ISO_DATE);
    // POST /me/attachments: a Photo plus isEncrypted (Swift's Photo decoding ignores the extra key).
    await body(
      await as(a).post("/v1/me/attachments", { body: await makeJpeg(), contentType: "image/jpeg" }),
      Photo.extend({ isEncrypted: z.literal(false) }),
      "Photo(attachment upload)",
      201,
    );

    const page1 = await body(await as(b).get(`${url}?limit=2`), Page(Message), "Page<Message>");
    expect(page1.nextCursor).toBeString();
    expect(page1.items.every((m) => m.clientID === null)).toBe(true); // recipient never sees the sender's key
    await body(await as(b).get(`${url}?limit=50&before=${page1.nextCursor}`), Page(Message), "Page<Message>(before)");

    const convsB = await body(await as(b).get("/v1/conversations"), z.array(Conversation), "[Conversation]");
    const mine = convsB.find((c) => c.id === conv.id)!;
    expect(mine.unreadCount).toBe(4);
    expect(mine.lastMessage?.id).toBe(sent[3]!.id);
    expect(mine.lastMessage?.attachment?.url).toBeNull(); // a view-once URL is never in the conversation list

    const res = await as(b).post(`/v1/conversations/${conv.id}/read`);
    expect(res.status).toBe(204);
    const afterRead = await body(await as(a).get(`${url}?limit=50`), Page(Message), "Page<Message>(after read)");
    const expiring = afterRead.items.find((m) => m.id === sent[2]!.id)!;
    expect(expiring.status).toBe("read");
    expect(expiring.expiresAt).toMatch(ISO_DATE);
  });

  test("Stexx+: SubscriptionStatus, Boost, dev grant", async () => {
    const u = await createUser();
    expect(await body(await as(u).get("/v1/subscriptions/status"), SubscriptionStatus, "SubscriptionStatus")).toEqual({
      isActive: false,
      expiresAt: null,
      willRenew: null,
      boostEndsAt: null,
    });
    conforms(ErrorBody, await (await as(u).post("/v1/boosts")).json(), "Error(402)");
    // debugGrantPlus() posts an empty JSON object
    expect((await as(u).post("/v1/dev/plus", { json: {} })).ok).toBe(true);
    const st = await body(await as(u).get("/v1/subscriptions/status"), SubscriptionStatus, "SubscriptionStatus(active)");
    expect(st.isActive).toBe(true);
    const boost = await body(await as(u).post("/v1/boosts"), Boost, "Boost");
    const boosted = await body(await as(u).get("/v1/subscriptions/status"), SubscriptionStatus, "SubscriptionStatus(boosted)");
    expect(boosted.boostEndsAt).toBe(boost.endsAt);
  });

  test("safety: [Profile] blocks list", async () => {
    const u = await createUser();
    const v = await createUser();
    expect((await as(u).put(`/v1/blocks/${v.id}`)).status).toBe(204);
    const list = await body(await as(u).get("/v1/blocks"), z.array(Profile), "[Profile](blocks)");
    expect(list.map((p) => p.id)).toEqual([v.id]);
  });
});

describe("contract: realtime frames match RealtimeEvent", () => {
  test("message.created, message.updated, conversation.updated, message.read and tap.received decode", async () => {
    const home = randomCell();
    const a = await createUser({ location: home });
    const b = await createUser({ location: near(home, 900) });
    const la = listen(a);
    const lb = listen(b);
    try {
      const conv = await body(await as(a).post("/v1/conversations", { json: { participantID: b.id } }), Conversation, "Conversation");
      const msg = await body(
        await as(a).post(`/v1/conversations/${conv.id}/messages`, { json: { clientID: crypto.randomUUID(), text: "rt" } }),
        Message,
        "Message",
      );
      await waitFor(lb.frames, (f) => f.type === "message.created");
      await waitFor(lb.frames, (f) => f.type === "conversation.updated");
      await waitFor(la.frames, (f) => f.type === "message.created");
      expect((await as(b).post(`/v1/conversations/${conv.id}/read`)).status).toBe(204);
      const read = await waitFor(la.frames, (f) => f.type === "message.read");
      expect(read.data).toMatchObject({ conversationID: conv.id, readerID: b.id, messageIDs: [msg.id] });
      // A view-once photo opened by b: a (who gets b's receipts) is told with message.updated.
      const photo = await body(await as(a).post("/v1/me/photos", { body: await makeJpeg(), contentType: "image/jpeg" }), Photo, "Photo", 201);
      const once = await body(
        await as(a).post(`/v1/conversations/${conv.id}/messages`, {
          json: { clientID: crypto.randomUUID(), attachmentPhotoID: photo.id, isViewOnce: true },
        }),
        Message,
        "Message(view-once)",
      );
      expect((await as(b).post(`/v1/conversations/${conv.id}/messages/${once.id}/open`)).status).toBe(200);
      const updated = await waitFor(la.frames, (f) => f.type === "message.updated");
      // (Plain checks: toMatchObject with asymmetric matchers would write the matchers into the frame.)
      expect(updated.data.id).toBe(once.id);
      expect(updated.data.attachment.url).toBeNull();
      expect(updated.data.attachment.openedAt).toMatch(ISO_DATE);
      expect((await as(a).post(`/v1/profiles/${b.id}/tap`)).status).toBe(204);
      await waitFor(lb.frames, (f) => f.type === "tap.received");
      await Bun.sleep(50);

      const all = [...la.frames, ...lb.frames];
      const types = new Set(all.map((f: any) => f.type));
      for (const t of ["message.created", "message.updated", "message.read", "conversation.updated", "tap.received"]) {
        expect(types).toContain(t);
      }
      for (const f of all) conforms(Event, f, `event(${(f as any).type})`);
      expect(JSON.stringify(all)).not.toMatch(/\d{2}:\d{2}:\d{2}\.\d+/);
    } finally {
      la.stop();
      lb.stop();
    }
  });
});

// Keep the shared DB tidy-ish: nothing to clean up (unique data only), but make sure we never wrote fractions.
test("contract: database timestamps are serialized without fractions even when stored with them", async () => {
  const u = await createUser({ lastActiveAt: new Date(Date.UTC(2026, 10, 17, 20, 30, 0, 987)) });
  await sql`UPDATE users SET show_online_status = true WHERE id = ${u.id}`;
  const me = await body(await as(u).get("/v1/me"), OwnProfile, "Profile");
  expect(me.lastActiveAt).toMatch(ISO_DATE);
});
