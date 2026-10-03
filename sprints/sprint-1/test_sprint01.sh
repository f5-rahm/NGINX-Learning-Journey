#!/usr/bin/env bash
# ==============================================================================
# Sprint 1 Lab Verification Test Suite
# Tests NGINX static web server configuration against objective criteria
#
# Usage:   ./test_sprint01.sh
# Target:  override with NGINX_TARGET, e.g. NGINX_TARGET=http://127.0.0.1:8082 ./test_sprint01.sh
# ==============================================================================
set -u

TARGET="${NGINX_TARGET:-http://127.0.0.1:8081}"
HOST_HEADER="Host: shop.northwind.local"
PASSED=0
TOTAL=0
STRETCH_PASSED=0
STRETCH_TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Check that NGINX answers on the target (no dependency on nc)
if ! curl -s -o /dev/null --max-time 3 "$TARGET/" 2>/dev/null; then
    echo -e "${RED}[ERROR] NGINX is not reachable at $TARGET!${NC}"
    echo -e "Please launch NGINX with your lab configuration:"
    echo -e "  cd /srv/nginx-journey/sprints/sprint-1/lab"
    echo -e "  ngx -t && ngx        # or: /usr/sbin/nginx -p \$PWD -c \$PWD/nginx.conf -e logs/error.log"
    exit 1
fi

# Core assertions count toward the sprint gate; stretch ones are reported separately.
record() {
  local tier="$1" ok="$2" msg="$3"
  if [ "$tier" = "core" ]; then
    TOTAL=$((TOTAL + 1)); [ "$ok" = 1 ] && PASSED=$((PASSED + 1))
  else
    STRETCH_TOTAL=$((STRETCH_TOTAL + 1)); [ "$ok" = 1 ] && STRETCH_PASSED=$((STRETCH_PASSED + 1))
  fi
  if [ "$ok" = 1 ]; then
    echo -e "  ${GREEN}✔ [PASS]${NC} $msg"
  else
    echo -e "  ${RED}✖ [FAIL]${NC} $msg"
  fi
}

assert_status() {
  local test_name="$1" path="$2" expected_code="$3" tier="${4:-core}"
  local response_code
  response_code=$(curl -s -o /dev/null -w "%{http_code}" -H "$HOST_HEADER" "$TARGET$path" 2>/dev/null)
  [ -z "$response_code" ] && response_code="000"
  if [ "$response_code" = "$expected_code" ]; then
    record "$tier" 1 "$test_name (Status: $response_code)"
  else
    record "$tier" 0 "$test_name (Expected $expected_code, Got $response_code)"
  fi
}

assert_body_contains() {
  local test_name="$1" path="$2" expected_text="$3" tier="${4:-core}"
  local body
  body=$(curl -s -H "$HOST_HEADER" "$TARGET$path" 2>/dev/null || echo "")
  if [[ "$body" == *"$expected_text"* ]]; then
    record "$tier" 1 "$test_name (Found '$expected_text')"
  else
    record "$tier" 0 "$test_name (Did not find '$expected_text' in response)"
  fi
}

assert_header() {
  local test_name="$1" path="$2" expected_header="$3" tier="${4:-core}"
  local headers
  headers=$(curl -s -I -H "$HOST_HEADER" "$TARGET$path" 2>/dev/null || echo "")
  if echo "$headers" | grep -iqE "$expected_header"; then
    record "$tier" 1 "$test_name (Found header match '$expected_header')"
  else
    record "$tier" 0 "$test_name (Header '$expected_header' not found)"
  fi
}

assert_no_header_match() {
  local test_name="$1" path="$2" forbidden_pattern="$3" tier="${4:-core}"
  local headers
  headers=$(curl -s -I -H "$HOST_HEADER" "$TARGET$path" 2>/dev/null || echo "")
  if echo "$headers" | grep -iqE "$forbidden_pattern"; then
    record "$tier" 0 "$test_name (Found forbidden header pattern '$forbidden_pattern')"
  else
    record "$tier" 1 "$test_name (Header pattern '$forbidden_pattern' successfully hidden)"
  fi
}

assert_png() {
  local test_name="$1" path="$2" tier="${3:-core}"
  local sig
  sig=$(curl -s -H "$HOST_HEADER" "$TARGET$path" 2>/dev/null | head -c 4 | od -An -tx1 | tr -d ' \n')
  if [ "$sig" = "89504e47" ]; then
    record "$tier" 1 "$test_name (PNG signature found)"
  else
    record "$tier" 0 "$test_name (Response is not the PNG file)"
  fi
}

echo -e "\n${BOLD}${BLUE}====================================================${NC}"
echo -e "${BOLD}${BLUE}  Sprint 1 Automated Lab Verification Suite         ${NC}"
echo -e "${BOLD}${BLUE}  Target: $TARGET | VHost: shop.northwind.local     ${NC}"
echo -e "${BOLD}${BLUE}====================================================${NC}\n"

echo -e "${BOLD}Core assertions (sprint gate)${NC}"

# Test 1 & 2: Exact match healthcheck
assert_status "1. Healthcheck exact match status" "/healthz" 200
assert_body_contains "2. Healthcheck body payload" "/healthz" "OK"

# Test 3 & 4: Standard root static file
assert_status "3. Root static document returns 200" "/" 200
assert_body_contains "4. Root storefront content served" "/" "Northwind Storefront"

# Test 5: Alias path resolution (without path doubling). Checks the PNG file signature,
# not the status: a regex location like ~* \.png$ can return 200 (even labeled
# Content-Type: image/png, which NGINX sets from the extension) without serving the file.
assert_png "5. Media alias serves the real image (/assets/media/logo.png)" "/assets/media/logo.png"

# Test 6 & 7: Single-Page Application (SPA) fallback routing
assert_status "6. SPA deep link fallback (/app/orders/history)" "/app/orders/history" 200
assert_body_contains "7. SPA deep link resolves to app shell" "/app/orders/history" "Northwind App Shell"

# Test 8 & 9: Permanent redirect (301)
assert_status "8. Legacy route redirects with 301" "/legacy" 301
assert_header "9. Legacy redirect specifies Location: /app/" "/legacy" "^Location: .*/app/"

# Test 10 & 11: Security - dotfiles denied
assert_status "10. Dotfile /.env is 403 Forbidden" "/.env" 403
assert_status "11. Dotfile /.git/config is 403 Forbidden" "/.git/config" 403

# Test 12: Security - server_tokens off (version omitted)
assert_no_header_match "12. Server tokens hidden (no version in Server header)" "/" "^Server: nginx/[0-9]"

echo -e "\n${BOLD}${YELLOW}Stretch assertions (Day 2 gotchas, not part of the gate)${NC}"

# S1: ^~ skips regex, so a dotfile deny at server level does not protect ^~ locations
assert_status "S1. Dotfile inside the media location is 403" "/assets/media/.secret" 403 stretch

# S2: /.well-known/ must stay reachable for ACME (Sprint 3); 404 means not blocked
assert_status "S2. /.well-known/ is not blocked by the dotfile rule" "/.well-known/acme-challenge/test" 404 stretch

# S3: add_header inheritance; a location-level add_header would drop the server-level one
assert_header "S3. X-Worker-PID still present on SPA responses" "/app/orders/history" "^X-Worker-PID: [0-9]+" stretch

echo -e "\n${BOLD}${BLUE}----------------------------------------------------${NC}"
echo -e "${BOLD}  Core results:    $PASSED / $TOTAL tests passed.${NC}"
echo -e "${BOLD}  Stretch results: $STRETCH_PASSED / $STRETCH_TOTAL tests passed.${NC}"
echo -e "${BOLD}${BLUE}----------------------------------------------------${NC}"

if [ "$PASSED" -eq "$TOTAL" ]; then
  echo -e "${GREEN}${BOLD}★ SUCCESS: All $TOTAL Sprint 1 Lab assertions verified!${NC}\n"
  exit 0
else
  echo -e "${RED}${BOLD}⚠ INCOMPLETE: $((TOTAL - PASSED)) test(s) failed. Review configuration.${NC}\n"
  exit 1
fi

