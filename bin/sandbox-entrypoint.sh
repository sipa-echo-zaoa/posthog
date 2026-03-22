#!/bin/bash
set -e

cd /workspace

# --- PRE-MERGE WORKAROUND (delete this block after merging to master) ---
# The sandbox modifies several bin/ scripts and posthog/utils.py. Branches
# that don't have those changes yet will fail to boot. This block overlays
# the sandbox-aware versions from the Docker image onto the worktree.
# Once this PR is merged, every branch inherits the changes and this
# block does nothing useful (cp overwrites with identical files, sed is a no-op).
echo "==> Applying sandbox script overlays..."
cp /usr/local/share/sandbox/bin/wait-for-docker    bin/wait-for-docker
cp /usr/local/share/sandbox/bin/mprocs.yaml        bin/mprocs.yaml
cp /usr/local/share/sandbox/bin/start-backend      bin/start-backend
cp /usr/local/share/sandbox/bin/start-rust-service bin/start-rust-service
# Fix hardcoded Vite dev server port in older branches (no-op after merge).
sed -i "s|http://localhost:8234|${JS_URL}|g" posthog/utils.py
# --- END PRE-MERGE WORKAROUND ---

# When running as a non-root UID (the default — see docker-compose.sandbox.yml),
# HOME and cache dirs point to unwritable locations. Redirect to /tmp.
export HOME=/tmp/sandbox-home
export UV_CACHE_DIR=/tmp/uv-cache
export XDG_CACHE_HOME=/tmp/sandbox-cache
export COREPACK_ENABLE_AUTO_PIN=0
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
mkdir -p "$HOME" "$UV_CACHE_DIR" "$XDG_CACHE_HOME"

echo "==> Installing Python dependencies..."
uv sync

# Activate the venv so python/pip resolve to the right environment
source .venv/bin/activate

# Make hogli available — normally done by flox on-activate.sh
ln -sf "$(pwd)/bin/hogli" .venv/bin/hogli 2>/dev/null || true

echo "==> Installing Node dependencies..."
# CI=1 suppresses interactive prompts (e.g. "reinstall from scratch? Y/n")
# that hang when there's no TTY. The worktree may already have partial
# node_modules from posthog-worktree setup.
CI=1 pnpm install --frozen-lockfile --prefer-offline 2>&1 || CI=1 pnpm install 2>&1

echo "==> Running database migrations..."
python manage.py migrate --noinput
python manage.py migrate_clickhouse
python manage.py apply_persons_migrations --database=persons_db_writer --ensure-database

echo "==> Downloading GeoIP database..."
bin/download-mmdb || true

# Generate demo data on first boot (creates test@posthog.com / 12345678).
# Uses a marker file rather than a Django ORM query to avoid a full app startup.
MARKER="/tmp/sandbox-home/.demo-data-generated"
if [[ ! -f "$MARKER" ]]; then
    echo "==> Generating demo data (first boot)..."
    python manage.py generate_demo_data
    touch "$MARKER"
fi

echo "==> Starting PostHog via mprocs in tmux..."
# mprocs needs a real TTY, so we wrap bin/start in a tmux session.
# tmux -L <name> starts a fresh server that inherits our full environment.
# exec replaces this process so the container stays alive as long as tmux does.
# Use `sandbox shell <branch>` to attach and see the mprocs UI.
rm -f /workspace/bin/start.lock

exec tmux -L sandbox new-session -s posthog "bash -c 'source .venv/bin/activate && bin/start'"
