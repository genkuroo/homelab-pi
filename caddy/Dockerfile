# Caddy with the replace-response module compiled in.
#
# Why a custom image instead of caddy:2-alpine: the only "jump to another app"
# affordance in this stack is the launcher page at the apex domain, and none of
# the four apps links back to it from its own templates — they live in four
# separate repos. Rather than editing all four, Caddy rewrites each proxied
# HTML response on the way out and injects one small link just before </body>
# (see the (homelink) snippet in the Caddyfile). That needs the replace-response
# handler, which is not in the stock image.
#
# https://github.com/caddyserver/replace-response

FROM caddy:2-builder-alpine AS builder
RUN xcaddy build --with github.com/caddyserver/replace-response

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
