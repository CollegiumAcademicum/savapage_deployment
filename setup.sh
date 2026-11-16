#!/usr/bin/env bash
# Bootstrap script for pod0 — run as root. Safe to re-run.
# First run installs everything and creates .env; after filling in .env,
# run it again to create the database in CArtei's Postgres.
# Can be executed before the repo exists:
#   curl -fsSL https://raw.githubusercontent.com/CollegiumAcademicum/savapage_deployment/main/setup.sh | bash
set -euo pipefail

REPO_URL="https://github.com/CollegiumAcademicum/savapage_deployment.git"
SRV_DIR="${SAVAPAGE_DIR:-/tank/savapage}"
LINK_DIR="$HOME/savapage"
SERVICE_NAME="savapage"
SYSTEMD_DIR="/etc/systemd/system"
PG_CONTAINER="cartei_postgres_1"
PG_SUPERUSER="${CARTEI_PG_USER:-cartei}"   # POSTGRES_USER in /tank/cartei/.env

# ── helpers ────────────────────────────────────────────────────────────────
info() { echo "[setup] $*"; }
warn() { echo "[setup] WARNING: $*" >&2; }
die()  { echo "[setup] ERROR: $*" >&2; exit 1; }

# ── 1. prerequisites ────────────────────────────────────────────────────────
info "Checking prerequisites..."
command -v podman         >/dev/null 2>&1 || die "podman is not installed."
command -v podman-compose >/dev/null 2>&1 \
  || podman compose version >/dev/null 2>&1 \
  || die "podman-compose is not installed."
command -v git            >/dev/null 2>&1 || die "git is not installed."
command -v systemctl      >/dev/null 2>&1 || warn "systemctl not found — skipping service setup."

# ── 2. clone or update repo ─────────────────────────────────────────────────
if [ -d "$SRV_DIR/.git" ]; then
    info "Repo already exists at $SRV_DIR — pulling latest..."
    git -C "$SRV_DIR" pull
else
    info "Cloning repo to $SRV_DIR..."
    mkdir -p "$(dirname "$SRV_DIR")"
    git clone "$REPO_URL" "$SRV_DIR"
fi

if [ -L "$LINK_DIR" ]; then
    info "Symlink $LINK_DIR already exists — skipping."
elif [ -d "$LINK_DIR" ]; then
    warn "$LINK_DIR is a real directory. Remove it and re-run if needed."
else
    ln -s "$SRV_DIR" "$LINK_DIR"
    info "Created symlink: $LINK_DIR -> $SRV_DIR"
fi

cd "$SRV_DIR"

# ── 3. .env ──────────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
    cp .env.example .env
    chmod 600 .env
    info "Created .env from .env.example — fill in all CHANGE_ME values, then re-run this script."
else
    info ".env already exists — skipping."
fi

# ── 4. data directories ───────────────────────────────────────────────────────
info "Ensuring data directories exist..."
mkdir -p data/server data/cups
# The container trusts this CA for LDAPS to FreeIPA (copied, so :z does not
# relabel the host's own file).
cp /etc/ipa/ca.crt data/ipa-ca.crt || die "/etc/ipa/ca.crt missing — is pod0 enrolled in FreeIPA?"

# ── 5. systemd services ──────────────────────────────────────────────────────
if command -v systemctl >/dev/null 2>&1; then
    info "Installing systemd services..."
    cp "$SRV_DIR/$SERVICE_NAME.service"        "$SYSTEMD_DIR/$SERVICE_NAME.service"
    cp "$SRV_DIR/$SERVICE_NAME-update.service" "$SYSTEMD_DIR/$SERVICE_NAME-update.service"
    cp "$SRV_DIR/$SERVICE_NAME-update.timer"   "$SYSTEMD_DIR/$SERVICE_NAME-update.timer"

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME.service"
    systemctl enable --now "$SERVICE_NAME-update.timer"
    info "Services enabled."
else
    warn "Skipped systemd setup — run manually if needed."
fi

# ── 6. database in CArtei's Postgres ─────────────────────────────────────────
if grep -q CHANGE_ME .env; then
    info "Skipping database setup — .env still contains CHANGE_ME values."
    DB_READY=
elif ! podman exec "$PG_CONTAINER" pg_isready -q 2>/dev/null; then
    warn "$PG_CONTAINER is not running — start cartei-db.service and re-run."
    DB_READY=
else
    set -a; . ./.env; set +a
    info "Creating role and database '$DB_NAME' (if missing)..."
    podman exec -i "$PG_CONTAINER" psql -q -v ON_ERROR_STOP=1 -U "$PG_SUPERUSER" -d postgres \
        -v user="$DB_USER" -v pw="$DB_PASSWORD" -v db="$DB_NAME" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'user')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'user') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'user', :'pw') \gexec
SELECT format('CREATE DATABASE %I OWNER %I ENCODING ''UTF8'' TEMPLATE template0', :'db', :'user')
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
SQL

    # savapage-db --db-init wipes the database, so only run it on an empty one.
    tables=$(podman exec "$PG_CONTAINER" psql -tA -U "$PG_SUPERUSER" -d "$DB_NAME" \
        -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
    if [ "$tables" = "0" ]; then
        info "Database is empty — initialising the SavaPage schema..."
        podman compose pull
        podman compose run --rm savapage db-init
    else
        info "Database already has $tables tables — skipping schema init."
    fi
    DB_READY=1
fi

# ── done ─────────────────────────────────────────────────────────────────────
echo ""
echo "Setup complete. Next steps:"
echo ""
if [ -z "$DB_READY" ]; then
echo "  1. Edit .env and fill in all CHANGE_ME values, then re-run this script:"
echo "       nano $SRV_DIR/.env && $SRV_DIR/setup.sh"
else
echo "  1. Start:"
echo "       cd $SRV_DIR && ./start.sh"
echo ""
echo "  2. First-time configuration (Caddy, Keycloak client, LDAP, printers):"
echo "       see README.md"
fi
echo ""
echo "  After that, the service auto-starts at every boot."
