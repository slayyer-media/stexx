# Stexx: OPTIONAL site block for the apex domain stexx.gay (the passkey relying party, WEBAUTHN_RP_ID, and the host of
# email sign-in links, APP_LINK_BASE).
#
# iOS only lets the app use passkeys for stexx.gay after Apple's CDN has fetched
# https://stexx.gay/.well-known/apple-app-site-association (JSON, HTTPS, no redirect). The API builds that file from
# APPLE_TEAM_ID + APPLE_BUNDLE_ID (src/lib/aasa.ts) and serves it on every host it answers.
#
# Install this ONLY when stexx.gay's DNS points at this box and nothing else serves stexx.gay:
#   sudo install -m 0644 Caddyfile.apex /etc/caddy/sites/stexx-apex.caddy
#   sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && sudo systemctl reload caddy
# deploy.sh --sync-config does not install or update it. If stexx.gay is hosted elsewhere (a website), make that host
# serve the same path instead (see deploy/README.md, "Apple app-site-association").
#
# Self-contained on purpose: snippets from stexx.caddy are not visible here (sites/*.caddy are imported in name order).
# PRIVACY: no `log` directive, so no access logs, like the other site blocks.
stexx.gay {
	header {
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		Strict-Transport-Security "max-age=31536000"
		-Server
	}

	@aasa {
		method GET HEAD
		path /.well-known/apple-app-site-association
	}

	# Email sign-in links (${APP_LINK_BASE}/auth/email?token=...) that did not open the app land here: the API answers with
	# a static page that never reads or uses the token. Query strings are not logged (no `log` directive at all).
	@emaillink {
		method GET HEAD
		path /auth/email
	}

	handle @aasa {
		reverse_proxy 127.0.0.1:8787 {
			header_up CF-Connecting-IP {client_ip}
			header_up -X-Real-IP
			header_up -True-Client-IP
		}
	}

	handle @emaillink {
		reverse_proxy 127.0.0.1:8787 {
			header_up CF-Connecting-IP {client_ip}
			header_up -X-Real-IP
			header_up -True-Client-IP
		}
	}

	# Nothing else lives on the apex on this box.
	handle {
		respond 404
	}
}
