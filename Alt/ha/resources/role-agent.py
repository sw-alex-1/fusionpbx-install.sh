#!/usr/bin/python3
"""fusionpbx-ha role agent.

Tiny HTTP service telling HAProxy which node is currently the PostgreSQL
primary.  HAProxy (on both data nodes) probes every data node's agent:

    GET /primary   ->  200  local PostgreSQL IS the primary
                       503  local PostgreSQL is a standby / down / unrecovered

The check is a single SQL query (SELECT pg_is_in_recovery()) against the
LOCAL PostgreSQL, using credentials from the cluster configuration file.

Everything else returns 404.  The agent serves nothing and accepts nothing
besides this stateless probe (see DESIGN.md section 14.4).

Configuration is read from the shell-sourceable cluster.conf written by
fusionpbx-ha.sh:

    HA_AGENT_PORT="8008"
    HA_PG_PORT="5432"
    HA_DB_NAME="fusionpbx"
    HA_DB_USER="fusionpbx"
    HA_DB_PASSWORD="..."

Access logs are suppressed (HAProxy polls every ~3s from two nodes);
only state TRANSITIONS and errors are logged to stderr (journald).
"""

import argparse
import datetime
import http.server
import socketserver
import re
import sys

# Import guard (not a hard exit): keeps this module importable for tests;
# main() refuses to start the service without the driver, and is_primary()
# degrades to "not primary" with a log entry.
try:
    import psycopg2
    PSYCOPG2_AVAILABLE = True
except ImportError:
    PSYCOPG2_AVAILABLE = False

# Values that must be present in cluster.conf for the agent to work
REQUIRED_KEYS = ("HA_AGENT_PORT", "HA_PG_PORT", "HA_DB_NAME",
                 "HA_DB_USER", "HA_DB_PASSWORD")

# cluster.conf line format:  VAR="value"   (shell-sourceable INI style)
CONF_LINE = re.compile(r'(\w+)\s*=\s*"([^"]*)"')


def load_conf(path):
    conf = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                # finditer: cluster.conf joins several VAR="v" pairs on one
                # line (HA_NODE1_NAME="..."; HA_NODE1_IP="..."; ...)
                for m in CONF_LINE.finditer(line):
                    conf[m.group(1)] = m.group(2)
    except OSError as exc:
        print("role-agent: FATAL: cannot read %s: %s" % (path, exc),
              file=sys.stderr)
        sys.exit(1)
    missing = [k for k in REQUIRED_KEYS if not conf.get(k)]
    if missing:
        print("role-agent: FATAL: %s misses required keys: %s"
              % (path, ", ".join(missing)), file=sys.stderr)
        sys.exit(1)
    return conf


def log(msg):
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print("role-agent: %s %s" % (stamp, msg), file=sys.stderr, flush=True)


def is_primary(conf):
    """True when the local PostgreSQL accepts writes (is the cluster primary)."""
    if not PSYCOPG2_AVAILABLE:
        log("psycopg2 is not installed (package python3-module-psycopg2)")
        return False
    try:
        conn = psycopg2.connect(host="127.0.0.1",
                                port=int(conf["HA_PG_PORT"]),
                                dbname=conf["HA_DB_NAME"],
                                user=conf["HA_DB_USER"],
                                password=conf["HA_DB_PASSWORD"],
                                connect_timeout=3)
    except Exception as exc:  # any failure means "not primary"
        log("connection failed: %s" % (exc,))
        return False
    try:
        cur = conn.cursor()
        cur.execute("SELECT pg_is_in_recovery()")
        in_recovery = bool(cur.fetchone()[0])
        return not in_recovery
    except Exception as exc:
        log("query failed: %s" % (exc,))
        return False
    finally:
        try:
            conn.close()
        except Exception:
            pass


class AgentServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """Threaded server: health checks from two HAProxy instances + operator
    curls must never queue behind each other."""
    daemon_threads = True
    allow_reuse_address = True


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fusionpbx-ha-agent/1.0"
    conf = None            # injected by main()
    last_state = None      # for transition logging

    def _respond(self, code):
        body = b"%d\n" % code
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/primary":
            self._respond(404)
            return
        primary = is_primary(self.conf)
        code = 200 if primary else 503
        state = "primary" if primary else "standby/down"
        if state != self.last_state:
            log("local role: %s (HTTP %d)" % (state, code))
            self.last_state = state
        self._respond(code)

    def log_message(self, fmt, *args):  # suppress per-request access logs
        pass


def main():
    parser = argparse.ArgumentParser(
        description="FusionPBX HA role agent (primary/standby HTTP probe)")
    parser.add_argument("--config", default="/etc/fusionpbx-ha/cluster.conf",
                        help="path to cluster.conf")
    args = parser.parse_args()

    if not PSYCOPG2_AVAILABLE:
        print("role-agent: FATAL: python3 module psycopg2 is not installed "
              "(package python3-module-psycopg2)", file=sys.stderr)
        sys.exit(1)

    conf = load_conf(args.config)
    Handler.conf = conf

    port = int(conf["HA_AGENT_PORT"])
    bind = "0.0.0.0"   # the NEIGHBOURING haproxy must reach this agent
    log("starting on %s:%d (probe: GET /primary)" % (bind, port))
    try:
        with AgentServer((bind, port), Handler) as httpd:
            httpd.serve_forever()
    except KeyboardInterrupt:
        log("stopped")
    except OSError as exc:
        log("FATAL: cannot bind %s:%d: %s" % (bind, port, exc))
        sys.exit(1)


if __name__ == "__main__":
    main()
