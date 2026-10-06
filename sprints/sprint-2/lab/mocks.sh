#!/usr/bin/env bash
# Start, stop, and inspect the Sprint 2 mock backends, one process per node.
#
#   ./mocks.sh start            # default nodes: 8001 api-node-1, 8002 api-node-2, 8003 chat-ws
#   ./mocks.sh start 8004       # extra node api-node-3 (Day 2 backup/hashing, Day 4 API)
#   ./mocks.sh stop 8001        # kill one node (simulate a crash)
#   ./mocks.sh start 8001       # bring it back
#   ./mocks.sh status
#   ./mocks.sh logs 8001        # follow one node's request log
set -u

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$LAB_DIR/run"
LOG_DIR="$LAB_DIR/logs"
mkdir -p "$RUN_DIR" "$LOG_DIR"

declare -A NAMES=([8001]=api-node-1 [8002]=api-node-2 [8003]=chat-ws [8004]=api-node-3)
DEFAULT_PORTS=(8001 8002 8003)      # what "start" brings up with no arguments
ALL_PORTS=(8001 8002 8003 8004)     # what "stop" and "status" cover with no arguments

is_up() { [ -f "$RUN_DIR/mock-$1.pid" ] && kill -0 "$(cat "$RUN_DIR/mock-$1.pid")" 2>/dev/null; }

start_node() {
    local port=$1 ws=""
    [ -z "${NAMES[$port]:-}" ] && { echo "unknown port $port"; return 1; }
    if is_up "$port"; then echo "  $port ${NAMES[$port]} already running"; return 0; fi
    [ "$port" = 8003 ] && ws="--ws"
    python3 "$LAB_DIR/mock_backend.py" --port "$port" --name "${NAMES[$port]}" $ws \
        >> "$LOG_DIR/mock-$port.log" 2>&1 &
    echo $! > "$RUN_DIR/mock-$port.pid"
    for _ in $(seq 20); do
        (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && { echo "  $port ${NAMES[$port]} up"; return 0; }
        sleep 0.1
    done
    echo "  $port ${NAMES[$port]} FAILED to start (see logs/mock-$port.log)"; return 1
}

stop_node() {
    local port=$1
    if is_up "$port"; then
        kill "$(cat "$RUN_DIR/mock-$port.pid")"; echo "  $port ${NAMES[$port]} stopped"
    else
        echo "  $port ${NAMES[$port]:-?} not running"
    fi
    rm -f "$RUN_DIR/mock-$port.pid"
}

cmd=${1:-status}; shift || true
ports=("$@")
if [ ${#ports[@]} -eq 0 ]; then
    if [ "$cmd" = start ]; then ports=("${DEFAULT_PORTS[@]}"); else ports=("${ALL_PORTS[@]}"); fi
fi

case "$cmd" in
    start)   for p in "${ports[@]}"; do start_node "$p"; done ;;
    stop)    for p in "${ports[@]}"; do stop_node "$p"; done ;;
    restart) for p in "${ports[@]}"; do stop_node "$p"; start_node "$p"; done ;;
    status)  for p in "${ports[@]}"; do
                 if is_up "$p"; then echo "  $p ${NAMES[$p]} UP"; else echo "  $p ${NAMES[$p]} down"; fi
             done ;;
    logs)    files=(); for p in "${ports[@]}"; do files+=("$LOG_DIR/mock-$p.log"); done
             tail -f "${files[@]}" ;;
    *)       echo "usage: $0 {start|stop|restart|status|logs} [port...]"; exit 1 ;;
esac
