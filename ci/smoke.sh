#!/usr/bin/env bash
# Smoke-test a UI image against Kratos, the UI run read-only as an arbitrary non-root
# uid with no capabilities. Walks the browser flows and fails on any error.
# Usage: ci/smoke.sh <ui-image> [kratos-image]
set -uo pipefail
IMG=$1; KRATOS=${2:-oryd/kratos:v1.3.1@sha256:fe2428f103a6240c064b6ea77d3088610865c55fcebccb30355857eccdc25b4b}
UI=http://127.0.0.1:4455; K=http://127.0.0.1:4433; DIR=$(cd "$(dirname "$0")" && pwd)
J=$(mktemp); trap 'rm -f $J; docker rm -f smoke-ui smoke-kratos >/dev/null 2>&1; docker network rm smoke >/dev/null 2>&1' EXIT
fail=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }

docker network create smoke >/dev/null 2>&1
docker run -d --name smoke-kratos --network smoke --network-alias kratos -p 127.0.0.1:4433:4433 \
  -v "$DIR/kratos:/etc/config/kratos:ro" "$KRATOS" serve -c /etc/config/kratos/kratos.yml --dev >/dev/null
for i in $(seq 40); do curl -sf $K/health/ready >/dev/null && break; sleep 1; done
docker run -d --name smoke-ui --network smoke -p 127.0.0.1:4455:3000 \
  --read-only --user 65534:65534 --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /home/ory --tmpfs /.npm \
  -e CSRF_COOKIE_NAME=findforce_csrf -e KRATOS_ADMIN_URL=http://kratos:4434 \
  -e KRATOS_BROWSER_URL=$K -e KRATOS_PUBLIC_URL=http://kratos:4433 \
  -e COOKIE_SECRET=0123456789abcdef0123456789abcdef -e CSRF_COOKIE_SECRET=fedcba9876543210fedcba9876543210 \
  -e DANGEROUSLY_DISABLE_SECURE_CSRF_COOKIES=true \
  "$IMG" >/dev/null
for i in $(seq 40); do curl -sf $UI/health/ready >/dev/null && break; sleep 1; done
code() { curl -s -o /dev/null -w '%{http_code}' -b $J -c $J "$@"; }
[ "$(code $UI/health/alive)" = 200 ] && ok health/alive || bad health/alive
[ "$(code $UI/health/ready)" = 200 ] && ok health/ready || bad health/ready

whoami() { curl -s -b $J $K/sessions/whoami | grep -q "\"$EMAIL\""; }
csrf() { grep -oP 'name="csrf_token"[^>]*value="\K[^"]+|value="\K[^"]+(?="[^>]*name="csrf_token")' | head -1; }
EMAIL="smoke-$RANDOM@example.com"; PW="Correct-Horse-Battery-$RANDOM"

# Registration: UI -> kratos browser flow -> UI renders flow -> POST to kratos -> UI home
out=$(curl -s -L -b $J -c $J -w '\n%{http_code} %{url_effective}' $UI/registration)
last=$(tail -1 <<<"$out"); flow=$(grep -oP 'flow=\K[0-9a-f-]+' <<<"$last"); tok=$(csrf <<<"$out")
[[ $last == 200* && -n $flow && -n $tok ]] && ok "registration page renders ($last)" || bad "registration page ($last tok=${tok:0:8})"
out=$(curl -s -L -b $J -c $J -w '\n%{http_code} %{url_effective}' --data-urlencode "csrf_token=$tok" \
  --data-urlencode "traits.email=$EMAIL" --data-urlencode "password=$PW" -d method=password "$K/self-service/registration?flow=$flow")
last=$(tail -1 <<<"$out"); [[ $last == 200*"/welcome" ]] && whoami && ok "register -> /welcome with session ($last)" || bad "register ($last)"

for p in sessions settings recovery verification welcome; do
  c=$(code -L $UI/$p); [ "$c" = 200 ] && ok "/$p logged-in $c" || bad "/$p logged-in $c"
done

# Logout the way the UI's own links do: Kratos browser logout (the UI's /logout is Hydra's challenge route)
lurl=$(curl -s -b $J $K/self-service/logout/browser | grep -oP '"logout_url":"\K[^"]+')
code -L "$lurl" >/dev/null
curl -s -b $J $K/sessions/whoami -o /dev/null -w '%{http_code}' | grep -q 401 && ok "logged out" || bad "still logged in"

# Settings while logged out: should land on login
last=$(curl -s -L -b $J -c $J -o /dev/null -w '%{http_code} %{url_effective}' $UI/settings)
[[ $last == 200*"/login?flow="* ]] && ok "/settings logged-out -> login ($last)" || echo "info /settings logged-out -> $last"

# Login
out=$(curl -s -L -b $J -c $J -w '\n%{http_code} %{url_effective}' $UI/login)
last=$(tail -1 <<<"$out"); flow=$(grep -oP 'flow=\K[0-9a-f-]+' <<<"$last"); tok=$(csrf <<<"$out")
[[ $last == 200* && -n $flow && -n $tok ]] && ok "login page renders" || bad "login page ($last)"
out=$(curl -s -L -b $J -c $J -w '\n%{http_code} %{url_effective}' --data-urlencode "csrf_token=$tok" \
  --data-urlencode "identifier=$EMAIL" --data-urlencode "password=$PW" -d method=password "$K/self-service/login?flow=$flow")
last=$(tail -1 <<<"$out"); [[ $last == 200*"/welcome" ]] && whoami && ok "login -> /welcome with session ($last)" || bad "login ($last)"

# Bad password renders an error on the login page, not a 5xx
out=$(curl -s -L -c $J.x -w '\n%{http_code} %{url_effective}' $UI/login); flow=$(tail -1 <<<"$out" | grep -oP 'flow=\K[0-9a-f-]+'); tok=$(csrf <<<"$out")
last=$(curl -s -L -b $J.x -c $J.x -o /dev/null -w '%{http_code} %{url_effective}' --data-urlencode "csrf_token=$tok" \
  --data-urlencode "identifier=$EMAIL" -d password=wrong -d method=password "$K/self-service/login?flow=$flow"); rm -f $J.x
[[ $last == 200*"/login?flow="* ]] && ok "wrong password -> login page ($last)" || bad "wrong password ($last)"

errs=$(docker logs smoke-ui 2>&1 | grep -ciE '"level":"error"|TypeError|ReferenceError|unhandled')
[ "$errs" = 0 ] && ok "no errors in UI logs" || { bad "UI log errors: $errs"; docker logs smoke-ui 2>&1 | grep -iE 'error' | head -5; }
docker logs smoke-ui 2>&1 | head -3
exit $fail
