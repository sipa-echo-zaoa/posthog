#!/bin/bash
set -e

cd /workspace

# When running as a non-root UID, HOME and cache dirs may point to
# unwritable locations. Use /tmp for caches.
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
pnpm install --frozen-lockfile --prefer-offline 2>&1 || pnpm install 2>&1

echo "==> Running database migrations..."
python manage.py migrate --noinput
python manage.py migrate_clickhouse
python manage.py apply_persons_migrations --database=persons_db_writer --ensure-database

echo "==> Downloading GeoIP database..."
bin/download-mmdb || true

# Generate demo data on first boot (creates test@posthog.com / 12345678)
if ! python manage.py shell -c "from posthog.models import Organization; exit(0 if Organization.objects.exists() else 1)" 2>/dev/null; then
    echo "==> Generating demo data (first boot)..."
    python manage.py generate_demo_data
fi

echo "==> Starting PostHog via mprocs in tmux..."
# Run bin/start inside tmux so mprocs gets a real TTY.
# -L sandbox starts a new server that inherits our full environment.
# exec replaces this process so the container stays alive as long as tmux does.
# Use `sandbox shell` to attach and see the mprocs UI.
# Clean up stale lock file from previous container crashes
rm -f /workspace/bin/start.lock

exec tmux -L sandbox new-session -s posthog "bash -c 'source .venv/bin/activate && bin/start'"
