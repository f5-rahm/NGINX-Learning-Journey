# Sprint 5 helpers. Load in every new terminal:  source helpers.sh
#
# Every command sends from the client container, so the gateway sees a real source address.
# Pick it with --from (default: $ALICE). The named clients:
#   ALICE=10.55.100.11  BOB=10.55.100.12   internet clients
#   OFFICE=10.55.10.10                     the operations network, 10.55.10.0/24
#   PARTNER=10.55.20.20                    the partner network, 10.55.20.0/24
#   BAD=10.55.66.6                         an abusive network, 10.55.66.0/24
#   LB=10.55.0.5                           a load balancer in front of the gateway
#
#   r PATH [opts]            one request: status, time, size, speed, Retry-After
#   burst N PATH [opts]      N requests at the same moment, one connection each:
#                            statuses, and when each group was answered
#                            (--conc C: as fast as possible, but only C at a time)
#   pace N RATE PATH [opts]  N requests one after another, RATE per second
#                            (--alt HOST:PORT: every other one goes to a second gateway)
#   hold N SECS PATH [opts]  N requests at once that the origin keeps open SECS seconds
#   slow PATH [--every S] [--body] [--for SECS]
#                            a client that dribbles its headers (or body), one piece every S seconds
#   h2 N PATH [opts]         N requests at once over one HTTP/2 connection
#   sweep N PATH [--base IP] one request from each of N different clients, starting at IP
#                            (default 10.55.110.1)
#   lim [N]                  the last N access log lines (default 10): client, request, status, limit results
#
# opts: --from IP, -H 'Name: value', --data-size BYTES (sends a POST body)
ALICE=10.55.100.11; BOB=10.55.100.12; OFFICE=10.55.10.10; PARTNER=10.55.20.20; BAD=10.55.66.6; LB=10.55.0.5
S5_LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_c() {
    local cmd="$1"; shift
    local from=(--from "$ALICE")
    case " $* " in *" --from "*) from=() ;; esac
    docker exec s5-client python3 /lab/client.py "$cmd" "${from[@]}" "$@"
}
r()     { _c get "$@"; }
burst() { _c burst "$@"; }
pace()  { _c pace "$@"; }
hold()  { _c hold "$@"; }
slow()  { _c slow "$@"; }
h2()    { _c h2 "$@"; }
sweep() { docker exec s5-client python3 /lab/client.py sweep "$@"; }
lim()   { tail -n "${1:-10}" "$S5_LAB/logs/access.log"; }
