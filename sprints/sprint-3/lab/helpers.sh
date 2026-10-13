# Sprint 3 shell helpers. Load them in every new terminal:
#   cd /srv/nginx-journey/sprints/sprint-3/lab && source helpers.sh
#
#   c   [curl args] URL      curl as a client that trusts the Lumina Lab CA (lumina.local -> 127.0.0.1)
#   hs  [s_client args]      one TLS handshake to 8443, summarized on one line
#   resume [--reload] [args] save a session, then reconnect 4 times: Reused or New?
#   h3  [curl args] URL      curl with HTTP/3 support (container; the host curl has none)
#   h3alt [URL]              two requests that honor Alt-Svc: watch the second one switch to HTTP/3
#   SNI=name hs ...          send a different SNI name; SNI= hs ... sends none
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CA="$LAB/certs/ca.crt"
H3_IMAGE=alpine/curl-http3:8.11.0

c() { curl -s --cacert "$CA" --resolve "lumina.local:${PORT:-8443}:127.0.0.1" "$@"; }

_sclient() {
    local sni=(-servername "${SNI-lumina.local}"); [ -z "${SNI-lumina.local}" ] && sni=(-noservername)
    # TLS 1.3 sends its session ticket after the handshake, so keep the connection open briefly
    (sleep 0.3) | openssl s_client -connect "127.0.0.1:${PORT:-8443}" "${sni[@]}" -CAfile "$CA" "$@" 2>&1
}

hs() {
    _sclient "$@" | awk '
        /^(New|Reused), /     { split($0, a, ", "); res = a[1]; sub(/Cipher is /, "", a[3]); cipher = a[3] }
        /^ +Protocol +:/      { ver = $NF }
        /Peer signature type/ { sig = $NF }
        /Server Temp Key/     { sub(/.*Server Temp Key: /, ""); grp = $0 }
        /ALPN protocol/       { alpn = $NF }
        /alert number/        { split($0, f, ":"); al = f[6]; n = $NF }
        /no protocols available/ { al = "CLIENT refused: no protocols available" }
        /Verify return code: [1-9]/ && vr == "" { sub(/.*Verify return code: [0-9]+ \(/, ""); sub(/\)$/, ""); vr = $0 }
        END {
            if (cipher == "" || cipher == "(NONE)") { print "FAILED  " (al != "" ? al (n != "" ? " (" n ")" : "") : "no handshake"); exit }
            printf "%s %s  cipher=%s  sig=%s  kx=%s%s\n", res, ver, cipher, sig, grp, (alpn != "" ? "  alpn=" alpn : "") (vr != "" ? "  VERIFY FAILED: " vr : "")
        }'
}

resume() {
    local reload=""; [ "${1:-}" = --reload ] && { reload=1; shift; }
    local sess; sess=$(mktemp)
    _sclient -sess_out "$sess" "$@" >/dev/null
    if [ -n "$reload" ]; then
        (cd "$LAB" && /usr/sbin/nginx -p "$LAB" -c "$LAB/nginx.conf" -e logs/error.log -s reload) && sleep 1 && echo "(reloaded)"
    fi
    local out=""
    for _ in 1 2 3 4; do out+="$(_sclient -sess_in "$sess" "$@" | grep -oE '^(Reused|New)' | head -1) "; done
    echo "$out"; rm -f "$sess"
}

h3() {
    docker run --rm --network host --add-host lumina.local:127.0.0.1 -v "$LAB/certs:/certs:ro" "$H3_IMAGE" \
        curl -s --cacert /certs/ca.crt "$@"
}

h3alt() {   # two requests from one client that remembers Alt-Svc: the first learns, the second upgrades
    docker run --rm --network host --add-host lumina.local:127.0.0.1 -v "$LAB/certs:/certs:ro" "$H3_IMAGE" sh -c '
        for i in 1 2; do
            curl -s --cacert /certs/ca.crt --alt-svc /tmp/altsvc -o /dev/null -w "request $i: HTTP/%{http_version}\n" "$1"
        done' _ "${1:-https://lumina.local:8443/}"
}
