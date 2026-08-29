#!/usr/bin/env bash
# Boot the Zulip dev server for a founding.dev preview.
#
# Zulip's dev environment expects PostgreSQL, Redis, RabbitMQ and memcached to be
# running locally, started by systemd. Upstream's dev-in-Docker image installs
# docker-systemctl-replacement so `service postgresql start` works. We start the
# four daemons directly instead: no init system, no shim, and each failure is
# visible on its own line instead of buried inside a faked systemctl.
#
# Ordering matters. run-dev fails fast and unhelpfully against a database that is
# still starting, so PostgreSQL is waited for explicitly rather than slept on.
set -uo pipefail

cd /home/zulip/zulip
: "${FDEV_STATE_DIR:=/srv/zulip-state}"

# Activate the virtualenv. tools/lib/sanity_check.py compares sys.prefix against
# <repo>/.venv and refuses to run otherwise:
#
#   You need to run /home/zulip/zulip/tools/run-dev inside a Zulip dev environment.
#
# The scripts use `#!/usr/bin/env python3`, which finds the system interpreter, so
# the venv has to be on PATH before any of them are called - rebuild-dev-database
# included, not just run-dev.
export VIRTUAL_ENV=/home/zulip/zulip/.venv
export PATH="$VIRTUAL_ENV/bin:$PATH"

log() { echo "[fdev-preview] $*"; }

# EXTERNAL_HOST is the hostname Zulip builds absolute URLs from and validates the
# incoming Host header against. It is derived HERE rather than defaulted in the
# compose file because the platform's only env-injection path rewrites a value to
# the full public URL, scheme included, and Zulip wants a bare host[:port]. An
# "https://..." value does not error - it silently produces broken links and a
# host-check failure, which is far more expensive to diagnose than it looks.
#
# FLY_APP_NAME is set on the machine and passed through by compose; the platform
# serves each preview at https://<app>.fly.dev. Unset means a laptop.
if [ -z "${EXTERNAL_HOST:-}" ]; then
  if [ -n "${FLY_APP_NAME:-}" ]; then
    EXTERNAL_HOST="$FLY_APP_NAME.fly.dev"
  else
    EXTERNAL_HOST="localhost:9991"
  fi
fi
export EXTERNAL_HOST
log "EXTERNAL_HOST=$EXTERNAL_HOST"

# zproject/dev-secrets.conf carries this instance's secret_key, and Zulip's
# development settings refuse to import without it ("Mandatory secret
# \"secret_key\" is not set"). provision writes it during the image build, but it
# lives INSIDE the repo, so the bind mount that makes the source editable hides
# the image's copy - and it is gitignored, so it is not in the template either.
#
# Generating it per instance is the correct behaviour, not a workaround. A
# secret_key baked into the shared preview image would be identical for every
# tenant, and anyone able to pull that image could forge session cookies for
# any other customer's chat.
#
# EXTERNAL_HOST must already be exported: generate_secrets imports the settings
# module, which parses it as a URL and asserts on an empty value.
if [ ! -f zproject/dev-secrets.conf ]; then
  log "generating zproject/dev-secrets.conf (first boot on this disk)"
  ./scripts/setup/generate_secrets.py --development \
    || log "WARN: generate_secrets failed - the server will not start"
else
  # Idempotent top-up: it only fills in secrets that are missing, so a Zulip
  # upgrade that adds a new mandatory one self-heals instead of crash-looping.
  ./scripts/setup/generate_secrets.py --development >/dev/null 2>&1 || true
fi

# Start the four daemons through the same systemctl shim the image was built
# with. Using the shim rather than pg_ctlcluster/redis-server/... by hand keeps
# boot identical to provision-time, so a service that came up during the build
# comes up the same way here.
# Starting the four daemons, which needs two different mechanisms.
#
# systemctl3.py BY PATH, not /bin/systemctl: the image diverts /bin/systemctl to
# the shim, but provision installs systemd as a dependency and apt puts the real
# binary back. Booted on a real machine the diverted name resolved to genuine
# systemd and produced "System has not been booted with systemd as init system".
# The shim itself is untouched, so call it where it actually lives.
#
# PostgreSQL is started with pg_ctlcluster rather than through the shim. Debian
# ships it as a TEMPLATE unit (postgresql@16-main) behind a `postgresql` meta
# unit, and the shim cannot expand the meta unit - asking it to start
# "postgresql" exits 0 having done nothing, which is exactly how this looked in
# production: no error, no database, and Django failing with "connection to
# server at 127.0.0.1:5432 refused" several minutes later. pg_ctlcluster is the
# supported entry point and reports honestly when the cluster is already up.
PG_VER="$(pg_lsclusters -h 2>/dev/null | awk 'NR==1{print $1}')"
if [ -z "$PG_VER" ]; then
    log "FATAL: no PostgreSQL cluster found - the image did not provision correctly"
    exit 1
fi
log "starting postgresql ${PG_VER}"
sudo pg_ctlcluster "$PG_VER" main start 2>&1 | sed 's/^/  pg: /' || log "  (already running)"

log "starting rabbitmq, redis, memcached"
sudo /bin/systemctl3.py start rabbitmq-server redis-server memcached 2>&1 | sed 's/^/  svc: /'

# RabbitMQ must be reconfigured on every boot, not just at build time.
#
# A broker's node identity is derived from the hostname (rabbit@<host>), and its
# user database lives under that node. configure-rabbitmq runs during provision,
# so the `zulip` user was created under the BUILD container's hostname; on a Fly
# machine the hostname differs, RabbitMQ comes up as a brand new empty node, and
# Zulip's very first AMQP connection fails with:
#
#   ACCESS_REFUSED - Login was refused using authentication mechanism PLAIN
#
# which surfaces as an endless pika reconnect loop rather than a clean error.
# Re-running the script is idempotent and re-creates the user against whatever
# node this boot produced, using the password already in zulip-secrets.conf.
log "waiting for rabbitmq"
for i in $(seq 1 60); do
    if (echo > /dev/tcp/127.0.0.1/5672) >/dev/null 2>&1; then log "  rabbitmq up (${i}s)"; break; fi
    sleep 1
done
log "configuring rabbitmq for this node"
sudo -- ./scripts/setup/configure-rabbitmq 2>&1 | sed 's/^/  amqp: /' || log "  (configure-rabbitmq reported a problem)"

log "waiting for postgres to accept connections"
for i in $(seq 1 90); do
    if pg_isready -q -h 127.0.0.1 2>/dev/null; then log "  ready (${i}s)"; break; fi
    [ "$i" -eq 90 ] && log "  NOT ready after 90s — continuing so run-dev's own error is the one you see"
    sleep 1
done

# The dev database is built once, and the marker lives on the durable volume: a
# machine replacement must not rebuild an empty database over a customer's data.
mkdir -p "$FDEV_STATE_DIR"
if [ ! -f "$FDEV_STATE_DIR/db-initialised" ]; then
    log "first boot - building the development database (this takes a few minutes)"
    if ./tools/rebuild-dev-database; then
        touch "$FDEV_STATE_DIR/db-initialised"
        log "development database ready"
    else
        # Not fatal: a broken database the agent can be asked to repair beats a
        # container that exits and takes the whole preview down with it.
        log "database build FAILED - starting the server anyway so the error is visible"
    fi
else
    log "database already initialised - skipping rebuild"
fi

log "starting run-dev on 0.0.0.0:9991"
# --interface 0.0.0.0: the default binds loopback only, which is invisible to the
# Fly proxy - the app looks healthy inside the machine and dead from outside.
exec ./tools/run-dev --interface 0.0.0.0
