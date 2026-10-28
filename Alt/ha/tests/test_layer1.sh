#!/bin/bash
# =============================================================================
# Layer-1 installer contracts (Alt/install.sh + Alt/resources/): the
# interactive questions layer, the ionCube default-off gate, the proxy
# .curlrc hardening and the parent->child value-carrier chain
# (install.sh asks its questions in the PARENT shell; every step script
# runs as a child and re-sources config.sh - only the environment carries
# the answers/flags into them).
# No root required: every behavioral case is driven through a pipe (the
# documented no-terminal contract) or by sourcing the libraries directly.
# =============================================================================
set -u

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
L1="$REPO/Alt"

PASS=0
FAIL=0
report() {
    if [ "$2" = "0" ] || [ "$2" = "ok" ]; then
        PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL  %s   %s\n' "$1" "${3:-}"
    fi
}

# ---------------------------------------------------------------------------
echo "== static: every layer-1 script parses =="
# bash -n: the layer-1 reality (util.sh legitimately uses bash arrays);
# dash sh -n: the files this change touched stay POSIX-clean
_fail=0
for f in "$L1/install.sh" "$L1/pre-install.sh" "$L1"/resources/*.sh "$L1"/resources/switch/*.sh; do
    bash -n "$f" 2>/dev/null || { echo "  bash -n FAIL: $f"; _fail=1; }
done
[ "$_fail" = "0" ]
report "all layer-1 scripts pass 'bash -n'" "$?"

_fail=0
for f in "$L1/install.sh" "$L1/pre-install.sh" "$L1/resources/interactive.sh" \
         "$L1/resources/config.sh" "$L1/resources/arguments.sh" \
         "$L1/resources/php.sh" "$L1/resources/proxy.sh"; do
    sh -n "$f" 2>/dev/null || { echo "  sh -n (dash) FAIL: $f"; _fail=1; }
done
[ "$_fail" = "0" ]
report "the touched files stay POSIX-clean ('sh -n', /bin/sh=dash)" "$?"

# ---------------------------------------------------------------------------
echo "== interactive.sh: the no-terminal contract (piped stdin) =="

# run_collect <input> - sources interactive.sh, runs the questions with the
# piped input, prints the resulting "PROXY|DOMAIN|PASSWORD" verdict
run_collect() {
    printf '%s\n' "$1" | (
        . "$L1/resources/interactive.sh"
        verbose() { :; }
        PROXY_SERVER=""; domain_name="ip_address"; system_password="random"
        system_username="admin"; install_ioncube=false
        interactive_collect_answers >/dev/null 2>/dev/null
        printf '%s|%s|%s\n' "$PROXY_SERVER" "$domain_name" "$system_password"
    )
}

_v="$(run_collect '
')"
[ "$_v" = "|ip_address|random" ]
report "all-Enter run keeps every default (proxy none, domain sentinel, password random)" "$?" "got: $_v"

_v="$(run_collect 'proxy.bad
192.168.0.1:3128
pbx.corp.local
secret1
secret1')"
[ "$_v" = "192.168.0.1:3128|pbx.corp.local|secret1" ]
report "custom answers survive: proxy re-asked until valid, domain, password" "$?" "got: $_v"

_v="$(run_collect '

secret1
secret2
secret3
secret3')"
[ "$_v" = "|ip_address|secret3" ]
report "password mismatch re-asks until the two entries match" "$?" "got: $_v"

_v="$(run_collect 'http://10.0.0.5:3128
')"
[ "$_v" = "10.0.0.5:3128|ip_address|random" ]
report "proxy protocol prefix is stripped (same normalization as arguments.sh)" "$?" "got: $_v"

# CLI-first rule: a value already set (--proxy / a custom config.sh value)
# is never asked for again - the proxy question consumes NOTHING
_v="$(printf 'SHOULD-NOT-BE-READ\n' | (
    . "$L1/resources/interactive.sh"
    verbose() { :; }
    PROXY_SERVER="10.9.9.9:8080"; domain_name="set-in-config.sh"; system_password="random"
    system_username="admin"; install_ioncube=false
    interactive_collect_answers >/dev/null 2>/dev/null
    printf '%s|%s\n' "$PROXY_SERVER" "$domain_name"
))"
[ "$_v" = "10.9.9.9:8080|set-in-config.sh" ]
report "already-given values (CLI flag / edited config.sh) are never re-asked" "$?" "got: $_v"

# the terminal gate: piped stdin -> interactive_install_questions returns
# immediately and consumes NOTHING (the line is still readable afterwards)
printf 'y\n' | {
    . "$L1/resources/interactive.sh"
    verbose() { :; }
    PROXY_SERVER=""; domain_name="ip_address"; system_password="random"; install_ioncube=false
    interactive_install_questions >/dev/null 2>&1
    read -r _rest
    [ "$_rest" = "y" ] && [ "$domain_name" = "ip_address" ]
}
report "no terminal on stdin: zero questions, input not consumed (curl|sh safe)" "$?"

# ask_yesno defaults and re-ask on garbage
printf '\n' | ( . "$L1/resources/interactive.sh"; ask_yesno "q?" y  >/dev/null 2>/dev/null )
report "ask_yesno: bare Enter takes the y default" "$?"
printf '\n' | ( . "$L1/resources/interactive.sh"; ask_yesno "q?" n  >/dev/null 2>/dev/null; )
[ $? -ne 0 ]
report "ask_yesno: bare Enter takes the n default (declines)" "$?"
printf 'garbage\nn\n' | ( . "$L1/resources/interactive.sh"; ask_yesno "q?" y >/dev/null 2>/dev/null; )
[ $? -ne 0 ]
report "ask_yesno: unrecognized answer re-asks" "$?"

# ---------------------------------------------------------------------------
echo "== value-carrier chain: parent answers survive into the step children =="

# config.sh defaults without inheritance
(
    unset domain_name system_password install_ioncube switch_source switch_branch 2>/dev/null || true
    . "$L1/resources/config.sh"
    [ "$domain_name" = "ip_address" ] && [ "$system_password" = "random" ] \
      && [ "$install_ioncube" = "false" ] && [ "$switch_source" = "false" ] \
      && [ "$switch_branch" = "stable" ]
)
report "config.sh defaults without inheritance" "$?"

# config.sh KEEPS inherited values - the interactive/flag carrier
(
    export domain_name=pbx.corp.local system_password=secret install_ioncube=true
    export switch_branch=master
    . "$L1/resources/config.sh"
    [ "$domain_name" = "pbx.corp.local" ] && [ "$system_password" = "secret" ] \
      && [ "$install_ioncube" = "true" ] && [ "$switch_branch" = "master" ]
)
report "config.sh keeps inherited values (environment carrier)" "$?"

# the child-process contract: a step script re-sources config.sh and must
# still see the parent's answers (this is what run_step actually does)
_v="$(env domain_name=pbx.corp.local system_password=secret install_ioncube=true switch_branch=master \
    sh -c '. "$1/resources/config.sh"; printf "%s|%s|%s|%s" "$domain_name" "$system_password" "$install_ioncube" "$switch_branch"' x "$L1")"
[ "$_v" = "pbx.corp.local|secret|true|master" ]
report "child step scripts keep the parent's answers/flags" "$?" "got: $_v"

# arguments.sh: --with-ioncube applies AND exports
(
    set -- --with-ioncube
    ARGUMENTS_PROCESSED=""
    error() { :; }; warning() { :; }; verbose() { :; }
    . "$L1/resources/config.sh"
    . "$L1/resources/arguments.sh"
    [ "$USE_IONCUBE" = "true" ] && [ "$install_ioncube" = "true" ] \
      && [ "$switch_source" = "false" ]
)
report "arguments.sh: --with-ioncube sets install_ioncube=true" "$?"

(
    set -- --use-switch-source --use-switch-master
    ARGUMENTS_PROCESSED=""
    error() { :; }; warning() { :; }; verbose() { :; }
    . "$L1/resources/config.sh"
    . "$L1/resources/arguments.sh"
    [ "$switch_source" = "true" ] && [ "$switch_package" = "false" ] && [ "$switch_branch" = "master" ]
)
report "arguments.sh: --use-switch-* flags apply (and export for the children)" "$?"

# ---------------------------------------------------------------------------
echo "== ionCube: off by default, opt-in only =="

grep -q 'install_ioncube="${install_ioncube:-false}"' "$L1/resources/config.sh"
report "config.sh defines install_ioncube (default false)" "$?"

grep -q '\[ "${install_ioncube:-false}" != "true" \]' "$L1/resources/php.sh" \
  && grep -q -- '--with-ioncube' "$L1/resources/php.sh"
report "php.sh gates the whole ionCube block behind install_ioncube" "$?"

# the getopt registration itself (a flag missing from -l would make getopt
# reject --with-ioncube at runtime):
grep -q -- '--with-ioncube' "$L1/resources/arguments.sh" \
  && grep -Eq '\-l [^"]*with-ioncube' "$L1/resources/arguments.sh"
report "arguments.sh registers and documents --with-ioncube" "$?"

grep -q 'ionCube' "$L1/install.sh"
report "install.sh banner shows the ionCube state" "$?"

# ---------------------------------------------------------------------------
echo "== proxy hardening: local addresses never go through the proxy =="

grep -q -- '--noproxy localhost,127.0.0.1,::1,.local' "$L1/resources/proxy.sh"
report "proxy.sh .curlrc carries --noproxy for local addresses" "$?"

grep -q -- '--noproxy localhost,127.0.0.1,::1,.local' "$L1/pre-install.sh"
report "pre-install.sh .curlrc carries --noproxy for local addresses" "$?"

# ---------------------------------------------------------------------------
echo "== install.sh wiring: questions after the guard, before the proxy =="

_g="$(grep -n 'guard_check_installed$' "$L1/install.sh" | head -1 | cut -d: -f1)"
_i="$(grep -n '^interactive_install_questions$' "$L1/install.sh" | head -1 | cut -d: -f1)"
_p="$(grep -n 'resources/proxy.sh\"$' "$L1/install.sh" | head -1 | cut -d: -f1)"
[ -n "$_g" ] && [ -n "$_i" ] && [ -n "$_p" ] && [ "$_g" -lt "$_i" ] && [ "$_i" -lt "$_p" ]
report "questions run after the installed-system guard, before proxy.sh" "$?" "guard:$_g questions:$_i proxy:$_p"

grep -q 'resources/interactive.sh' "$L1/install.sh"
report "install.sh sources resources/interactive.sh" "$?"

# ===========================================================================
echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
