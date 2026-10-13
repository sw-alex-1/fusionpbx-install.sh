#!/bin/bash
# =============================================================================
# role-agent.py unit tests (no psycopg2 required: only the config parser and
# the request-routing logic are tested; the SQL probe needs a live cluster)
# =============================================================================
set -u

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
AGENT="$REPO/Alt/ha/resources/role-agent.py"
WORK=$(mktemp -d /tmp/ha-agent-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
report() {
    if [ "$2" = "0" ] || [ "$2" = "ok" ]; then
        PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL  %s   %s\n' "$1" "${3:-}"
    fi
}

cat > "$WORK/cluster.conf" <<'EOF'
# comment line
HA_CLUSTER_NAME="fpbx-ha"
HA_NODE1_NAME="fpbx-ha-1"; HA_NODE1_IP="10.0.0.11"; HA_NODE1_ROLE="primary"
HA_AGENT_PORT="8008"
HA_PG_PORT="5432"
HA_DB_NAME="fusionpbx"
HA_DB_USER="fusionpbx"
HA_DB_PASSWORD="dbpass123"
EOF

python3 - "$AGENT" "$WORK" <<'EOF'
import importlib.util
import sys
import os

agent_path, work = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("role_agent", agent_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

results = []

# 1. load_conf: full fixture
conf = mod.load_conf(os.path.join(work, "cluster.conf"))
results.append(("loads all required keys", conf["HA_AGENT_PORT"] == "8008" and conf["HA_DB_PASSWORD"] == "dbpass123"))

# 2. single-line pairs (NAME="v"; NAME2="v2") are parsed too
results.append(("semicolon-joined lines parsed", conf.get("HA_NODE1_IP") == "10.0.0.11"))

# 3. missing key -> SystemExit
bad = os.path.join(work, "bad.conf")
open(bad, "w").write('HA_AGENT_PORT="8008"\n')  # everything else missing
try:
    mod.load_conf(bad)
    results.append(("missing keys -> fatal", False))
except SystemExit:
    results.append(("missing keys -> fatal", True))

# 4. unreadable file -> SystemExit
try:
    mod.load_conf(os.path.join(work, "nope.conf"))
    results.append(("missing file -> fatal", False))
except SystemExit:
    results.append(("missing file -> fatal", True))

# 5. is_primary: connection failure must be a clean False, never a crash.
# On a machine without the driver, is_primary degrades to False with a log.
if mod.PSYCOPG2_AVAILABLE:
    fc = {"HA_PG_PORT": "54329", "HA_DB_NAME": "x", "HA_DB_USER": "x", "HA_DB_PASSWORD": "x"}
    ok = mod.is_primary(fc) is False
    results.append(("dead connection -> not primary (no crash)", ok))
else:
    fc = {"HA_PG_PORT": "5432", "HA_DB_NAME": "x", "HA_DB_USER": "x", "HA_DB_PASSWORD": "x"}
    ok = mod.is_primary(fc) is False
    results.append(("no driver -> clean 'not primary' (skipped live probe)", ok))

# 6. Handler routes only /primary (static check of the do_GET source)
import inspect
src = inspect.getsource(mod.Handler.do_GET)
results.append(("only /primary is served", 'self.path != "/primary"' in src and "404" in src))

with open(os.path.join(work, "results"), "w") as fh:
    for name, ok in results:
        fh.write(("PASS  %s\n" if ok else "FAIL  %s\n") % name)
    fh.write("COUNT %d %d\n" % (sum(1 for _, ok in results if ok), sum(1 for _, ok in results if not ok)))
EOF

grep '^PASS' "$WORK/results" | while read -r _line; do echo "$_line"; done
grep '^FAIL' "$WORK/results" | while read -r _line; do echo "$_line"; done
read -r _ _p _f < <(grep '^COUNT' "$WORK/results")
PASS="${_p:-0}"; FAIL="${_f:-0}"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
