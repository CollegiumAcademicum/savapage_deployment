#!/usr/bin/env bash
# Runs cupsd and the SavaPage server in one container, configured from env.
#   serve    (default) start CUPS + SavaPage, stream the server log
#   db-init  create the SavaPage schema in the configured (empty!) database
set -euo pipefail

SP=/opt/savapage
BIN=$SP/server/bin/linux-x64
DATA=$SP/server/data
PROPS=$DATA/server.properties

info() { echo "[entrypoint] $*"; }

# ── 1. seed volumes on first start ─────────────────────────────────────────
# data/ holds encryption.properties — losing it makes stored secrets unreadable.
[ -e "$DATA/internal" ] || { info "Seeding $DATA"; cp -a "$SP/server/data.dist/." "$DATA/"; }
[ -e /etc/cups/cupsd.conf ] || { info "Seeding /etc/cups"; cp -a /etc/cups.dist/. /etc/cups/; }
chown -R savapage:savapage "$DATA"

# ── 2. server.properties from env ──────────────────────────────────────────
set_prop() {
    touch "$PROPS"
    if grep -q "^$1=" "$PROPS"; then
        sed -i "s|^$1=.*|$1=$(printf '%s' "$2" | sed 's/[|&\\]/\\&/g')|" "$PROPS"
    else
        printf '%s=%s\n' "$1" "$2" >> "$PROPS"
    fi
}

# Plain HTTP on 8631; TLS terminates at Caddy. The installer ships no
# server.properties and SavaPage crashes if a file without the ports exists.
set_prop server.port 8631
set_prop server.ssl.port 8632
set_prop server.html.redirect.ssl false
set_prop webserver.http.header.xff.enable Y
set_prop webserver.http.header.xff.proxies.allowed "${XFF_PROXIES:-10.0.0.0/8}"

if [ -n "${DB_HOST:-}" ]; then
    sed -i 's/^database.type=Internal/#&/' "$PROPS"
    set_prop database.type PostgreSQL
    set_prop database.driver org.postgresql.Driver
    set_prop database.url "jdbc:postgresql://$DB_HOST/${DB_NAME:-savapage}"
    set_prop database.user "${DB_USER:-savapage}"
    set_prop database.password "$DB_PASSWORD"
    # The Postgres instance is shared with CArtei — stay well below max_connections.
    set_prop database.connection.pool.max "${DB_POOL_MAX:-20}"
fi
chown savapage:savapage "$PROPS"
chmod 600 "$PROPS"

# ── 3. Keycloak login plug-in ──────────────────────────────────────────────
KC_PLUGIN=$SP/server/ext/savapage-ext-oauth-keycloak.properties
if [ -n "${KEYCLOAK_CLIENT_SECRET:-}" ]; then
    cat > "$KC_PLUGIN" <<EOF
savapage.plugin.id=keycloak-oauth
savapage.plugin.name=Keycloak OAuth
savapage.plugin.class=org.savapage.ext.oauth.KeycloakOAuthPlugin
savapage.plugin.enable=true
savapage.plugin.online=true
savapage.plugin.live=true
keycloak.savapage.usersource=true
keycloak.login.btn.text=${KEYCLOAK_BUTTON_TEXT:-Login}
keycloak.oauth.client-id=${KEYCLOAK_CLIENT_ID:-savapage}
keycloak.oauth.client-secret=$KEYCLOAK_CLIENT_SECRET
keycloak.oauth.base-url=$KEYCLOAK_BASE_URL
keycloak.oauth.realm=$KEYCLOAK_REALM
keycloak.oauth.callback-url=$PUBLIC_URL/user?sp-oauth=keycloak
EOF
    chown savapage:savapage "$KC_PLUGIN"
    chmod 600 "$KC_PLUGIN"
else
    rm -f "$KC_PLUGIN"
fi

case "${1:-serve}" in
    db-init)
        info "Initialising database schema..."
        exec su savapage -c "$BIN/savapage-db --db-init"
        ;;
    serve) ;;
    *) exec "$@" ;;
esac

# ── 4. run ─────────────────────────────────────────────────────────────────
shutdown() {
    info "Stopping..."
    su savapage -c "$BIN/app-server stop" || true
    kill "$CUPSD_PID" 2>/dev/null || true
    exit 0
}
trap shutdown TERM INT

/usr/sbin/cupsd -f &
CUPSD_PID=$!

rm -f "$SP/server/logs/server.started.txt"
su savapage -c "$BIN/app-server start"
for _ in $(seq 60); do
    [ -f "$SP/server/logs/server.started.txt" ] && break
    sleep 2
done

# CUPS notifier + job subscription: this is what reports finished jobs (and
# their page counts) back to SavaPage.
"$SP/providers/cups/linux-x64/roottasks" install || info "WARNING: CUPS notifier install failed"

tail -F "$SP/server/logs/server.log" &
wait
