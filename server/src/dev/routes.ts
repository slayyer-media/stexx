import { Hono } from "hono";
import { publishReadOutsideRoute, publishStoredMessage } from "../routes/chat.ts";
import type { AppEnv } from "../types.ts";
import { setDevBotPublisher } from "./bots.ts";
import { devPlusRoutes } from "./plus.ts";

/**
 * Dev-only routes (e.g. POST /v1/dev/plus). Mounted by app.ts ONLY when config.devAuth, via dynamic
 * import, so this module is never loaded in production.
 */
export const devRoutes = new Hono<AppEnv>();
devRoutes.route("/", devPlusRoutes);

// Bot replies/reads go out over the websocket like any other message.
setDevBotPublisher(async (event) => {
  if (event.type === "message.created") await publishStoredMessage(event.messageId, event.recipientId);
  else await publishReadOutsideRoute(event.conversationId, event.readerId, event.senderId);
});
