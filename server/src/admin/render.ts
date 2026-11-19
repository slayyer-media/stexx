import type { Context } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import type { JSX } from "hono/jsx/jsx-runtime";

/** Render a page component as a full HTML document. */
export async function render(c: Context, page: JSX.Element, status: ContentfulStatusCode = 200): Promise<Response> {
  const html = await page.toString();
  return c.html(`<!doctype html>${html}`, status);
}
