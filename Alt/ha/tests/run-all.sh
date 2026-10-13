#!/bin/bash
# =============================================================================
# Alt/ha test suite runner: static checks + all unit/CLI/render/agent tests.
# Usage: tests/run-all.sh   (from anywhere; no root required)
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HA_DIR="$(cd "$HERE/.." && pwd)"

TOTAL_PASS=0
TOTAL_FAIL=0
STATUS=0

echo "====================================================================="
echo " fusionpbx-ha test suite"
echo "====================================================================="
echo

echo "--- static checks ---"
_fail=0
for f in "$HA_DIR/fusionpbx-ha.sh" "$HA_DIR/resources/ha-lib.sh" "$HA_DIR/resources/promote.sh.tpl"; do
    if sh -n "$f" 2>/dev/null; then
        echo "PASS  sh -n $f"
        TOTAL_PASS=$((TOTAL_PASS + 1))
    else
        echo "FAIL  sh -n $f"
        TOTAL_FAIL=$((TOTAL_FAIL + 1)); _fail=1
    fi
done
if python3 -m py_compile "$HA_DIR/resources/role-agent.py" 2>/dev/null; then
    echo "PASS  py_compile role-agent.py"
    TOTAL_PASS=$((TOTAL_PASS + 1))
else
    echo "FAIL  py_compile role-agent.py"
    TOTAL_FAIL=$((TOTAL_FAIL + 1)); _fail=1
fi
[ "$_fail" = "0" ]

for t in test_lib.sh test_render.sh test_cli.sh test_agent.sh; do
    echo
    echo "--- $t ---"
    _out=$(bash "$HERE/$t" 2>&1)
    _rc=$?
    echo "$_out"
    [ "$_rc" -eq 0 ] || STATUS=1
    # accumulate counts from the suite's own summary line
    _line=$(echo "$_out" | grep '^RESULT:' | tail -1)
    _p=$(echo "$_line" | sed 's/.*PASS=\([0-9]*\).*/\1/')
    _f=$(echo "$_line" | sed 's/.*FAIL=\([0-9]*\).*/\1/')
    TOTAL_PASS=$((TOTAL_PASS + ${_p:-0}))
    TOTAL_FAIL=$((TOTAL_FAIL + ${_f:-0}))
done

echo
echo "====================================================================="
echo " TOTAL: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL"
echo "====================================================================="
[ "$TOTAL_FAIL" -eq 0 ] && [ "$STATUS" -eq 0 ]
