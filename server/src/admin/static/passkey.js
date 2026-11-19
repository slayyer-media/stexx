// Stexx staff console: passkey ceremonies (sign-in, enrollment, step-up). Hand-written, no dependencies, served by
// the console itself (CSP script-src 'self'). Talks only to this origin.
"use strict";
(() => {
  const b64 = {
    toBytes(s) {
      const pad = "=".repeat((4 - (s.length % 4)) % 4);
      const bin = atob((s + pad).replace(/-/g, "+").replace(/_/g, "/"));
      return Uint8Array.from(bin, (ch) => ch.charCodeAt(0));
    },
    from(buf) {
      let bin = "";
      for (const b of new Uint8Array(buf)) bin += String.fromCharCode(b);
      return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    },
  };
  const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content ?? "";
  const showError = (msg) => {
    const el = document.getElementById("passkey-error");
    if (el) { el.textContent = msg; el.hidden = false; } else { alert(msg); }
  };

  async function post(url, body) {
    const res = await fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf() },
      body: JSON.stringify(body ?? {}),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.message || "Something went wrong. Try again.");
    return data;
  }

  const creds = (list) => (list ?? []).map((c) => ({ ...c, id: b64.toBytes(c.id) }));

  async function assertion(options) {
    const cred = await navigator.credentials.get({
      publicKey: { ...options, challenge: b64.toBytes(options.challenge), allowCredentials: creds(options.allowCredentials) },
    });
    const r = cred.response;
    return {
      id: cred.id, rawId: b64.from(cred.rawId), type: cred.type, clientExtensionResults: cred.getClientExtensionResults(),
      response: {
        clientDataJSON: b64.from(r.clientDataJSON), authenticatorData: b64.from(r.authenticatorData),
        signature: b64.from(r.signature), ...(r.userHandle ? { userHandle: b64.from(r.userHandle) } : {}),
      },
    };
  }

  async function registration(options) {
    const cred = await navigator.credentials.create({
      publicKey: {
        ...options, challenge: b64.toBytes(options.challenge),
        user: { ...options.user, id: b64.toBytes(options.user.id) }, excludeCredentials: creds(options.excludeCredentials),
      },
    });
    const r = cred.response;
    return {
      id: cred.id, rawId: b64.from(cred.rawId), type: cred.type, clientExtensionResults: cred.getClientExtensionResults(),
      response: {
        clientDataJSON: b64.from(r.clientDataJSON), attestationObject: b64.from(r.attestationObject),
        transports: typeof r.getTransports === "function" ? r.getTransports() : [],
      },
    };
  }

  const guarded = (fn) => async (event) => {
    event.preventDefault();
    try { await fn(event); } catch (err) {
      showError(err && err.name === "NotAllowedError" ? "Passkey request cancelled or timed out." : (err.message || String(err)));
    }
  };

  document.addEventListener("DOMContentLoaded", () => {
    document.getElementById("passkey-login")?.addEventListener("click", guarded(async () => {
      const res = await post("/login/verify", await assertion(await post("/login/options")));
      location.assign(res.redirect || "/");
    }));

    const enroll = document.getElementById("passkey-enroll");
    enroll?.addEventListener("click", guarded(async () => {
      const token = enroll.dataset.token;
      const credential = await registration(await post("/enroll/options", { token }));
      const res = await post("/enroll/verify", { token, credential });
      location.assign(res.redirect || "/login");
    }));

    // Forms that need a fresh passkey check: data-step-up="recent" (skipped while data-step-up-fresh is set), or
    // "action" (bound to data-step-up-action + data-step-up-target; the proof goes into the `step_up` field).
    for (const form of document.querySelectorAll("form[data-step-up]")) {
      form.addEventListener("submit", guarded(async () => {
        const d = form.dataset;
        if (d.confirm && !confirm(d.confirm)) return;
        if (d.stepUp === "recent" && d.stepUpFresh === "1") return form.submit();
        const bound = d.stepUp === "action" ? { action: d.stepUpAction, target: d.stepUpTarget } : {};
        const res = await post("/step-up/verify", await assertion(await post("/step-up/options", bound)));
        if (res.token && form.elements.step_up) form.elements.step_up.value = res.token;
        form.submit();
      }));
    }
  });
})();
