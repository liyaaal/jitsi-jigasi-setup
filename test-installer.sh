#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
TEST_ROOT=$(mktemp -d "$ROOT/.installer-test.XXXXXX")
export TEST_ROOT
mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/docker-calls"
if [[ "${FAIL_PULL:-0}" == 1 && "$*" == *' pull' ]]; then exit 42; fi
SH
cat > "$TEST_ROOT/bin/git" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == clone ]]; then
    target="${@: -1}"
    mkdir -p "$target"
    if [[ -n "${UPSTREAM_FIXTURE:-}" ]]; then
        cp "$UPSTREAM_FIXTURE"/{env.example,docker-compose.yml,transcriber.yml} "$target/"
    else
        printf 'CONFIG=old\nJICOFO_AUTH_PASSWORD=\nJVB_AUTH_PASSWORD=\n' > "$target/env.example"
    fi
else
    printf 'fca3e3a578a1bdd527c20b9d86a31cfc362d5426\n'
fi
SH
chmod +x "$TEST_ROOT/bin/"*
export PATH="$TEST_ROOT/bin:$PATH"
args=(--dir "$TEST_ROOT/install" --public-url https://meet.example.org --advertise-ip 203.0.113.10 --email admin@example.org)
bash "$ROOT/jitsi_install.sh" configure "${args[@]}"
before=$(sed -n 's/^JIGASI_TRANSCRIBER_PASSWORD=//p' "$TEST_ROOT/install/.env")
[[ ${#before} -eq 64 ]]
printf '\nENABLE_TRANSCRIPTIONS=0\n' >> "$TEST_ROOT/install/.env"
bash "$ROOT/jitsi_install.sh" configure "${args[@]}"
after=$(sed -n 's/^JIGASI_TRANSCRIBER_PASSWORD=//p' "$TEST_ROOT/install/.env")
[[ "$before" == "$after" ]]
[[ $(grep -c '^ENABLE_TRANSCRIPTIONS=' "$TEST_ROOT/install/.env") -eq 1 ]]
grep -q '^ENABLE_TRANSCRIPTIONS=1$' "$TEST_ROOT/install/.env"
grep -q '^JVB_ADVERTISE_IPS=203.0.113.10$' "$TEST_ROOT/install/.env"
grep -q 'VoskTranscriptionService' "$TEST_ROOT/install/.env"
grep -q 'return 403' "$TEST_ROOT/install/config/web/nginx-custom/meeting-pro-private-transcripts.conf"
if bash "$ROOT/jitsi_install.sh" configure "${args[@]}" --public-url 'https://bad.test/path'; then exit 1; fi
if bash "$ROOT/jitsi_install.sh" configure "${args[@]}" --advertise-ip '999.1.1.1'; then exit 1; fi
if FAIL_PULL=1 bash "$ROOT/jitsi_install.sh" up --dir "$TEST_ROOT/install"; then exit 1; fi
if grep -q 'up -d' "$TEST_ROOT/docker-calls"; then printf 'Started after failed pull!\n' >&2; exit 1; fi
mkdir "$TEST_ROOT/unmanaged"
if bash "$ROOT/jitsi_install.sh" configure "${args[@]}" --dir "$TEST_ROOT/unmanaged"; then exit 1; fi
printf 'PASS: passwords preserved, settings deduplicated, invalid input rejected, failed pull aborts, existing install protected.\n'
printf 'TEST_ARTIFACTS=%s\n' "$TEST_ROOT"
