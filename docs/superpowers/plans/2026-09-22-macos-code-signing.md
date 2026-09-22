# macOS Code Signing and Notarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every macOS binary STEPSS publishes carries a Developer ID signature and a notarization ticket, applied by the workflow that builds it.

**Architecture:** One composite action in a new `stepss-ci` repository wraps a single `sign.sh` whose commands are unit-tested on Linux against fake `security`, `codesign` and `xcrun` binaries. Five workflows call it. The four engine repositories sign bare Mach-O files immediately after the build so that their existing regression gates exercise a signed binary; `stepss-java-ui` instead hands the prepared keychain to `jpackage` and notarizes the finished `.dmg`.

**Tech Stack:** GitHub Actions composite actions, Bash, OpenSSL 3, Apple `codesign`, `xcrun notarytool`, `xcrun stapler`, `jpackage` from Temurin JDK 21, Ant.

**Spec:** `docs/superpowers/specs/2026-09-22-macos-code-signing-design.md`

## Global Constraints

- Signing identity: `Developer ID Application: Cyprus University of Technology (SWZD63F3C7)`, Team ID `SWZD63F3C7`, expires `2031-09-12`.
- Secrets, already configured at SPS-L organization level and scoped to the five repositories: `APPLE_SIGNING_P12`, `APPLE_SIGNING_P12_PASSWORD`, `APPLE_NOTARY_KEY_P8`.
- Variables, likewise already configured: `APPLE_NOTARY_KEY_ID` = `8A4L5VF84Z`, `APPLE_NOTARY_ISSUER_ID` = `69a6de82-68c9-47e3-e053-5b8c7c11a4d1`.
- Entitlement `com.apple.security.cs.disable-library-validation` is mandatory on every engine binary. Without it the hardened runtime refuses Homebrew's ad-hoc-signed `libgfortran` and `libopenblas` and the binary cannot start.
- Action versions are pinned to the major and must match the umbrella table: `actions/checkout@v7`, `actions/setup-java@v5`, `actions/upload-artifact@v7`, `actions/download-artifact@v8`.
- No release asset may be renamed, reformatted, added or removed. `update_ramses_libs.sh`, `update_helios_libs.sh`, `update_codegen.sh` and java-ui's `versions.properties` all fail hard on a changed name.
- Signing runs after the build step and before the existing regression gates, never after them.
- `stepss-uramses` is not touched. It publishes no macOS binary.
- Every new repository carries `/.claude/` and `.mcp.json` in `.gitignore` before its first commit.
- Bash scripts use `set -euo pipefail`; tests follow the existing house pattern of `test_<name>.sh` with a `FAKEBIN` directory prepended to `PATH`, as `stepss-python-ui/tools/test_update_ramses_libs.sh` demonstrates.

---

## File Structure

**New repository `stepss-ci`:**

| File | Responsibility |
|---|---|
| `sign-macos/action.yml` | Composite action. Orders the commands, declares inputs and outputs, and guarantees the keychain is destroyed in a post step. |
| `sign-macos/sign.sh` | All logic, as one command dispatcher. The only file with behaviour. |
| `sign-macos/entitlements.plist` | The single entitlement granted to engine binaries. |
| `sign-macos/test_sign.sh` | Unit tests for `sign.sh`, runnable on Linux with no credentials. |
| `.github/workflows/test.yml` | Runs `test_sign.sh` on every push and pull request. |
| `.gitignore`, `README.md` | Repository hygiene; the ignore file is a release constraint, not a nicety. |

**Modified in existing repositories:** one workflow step plus one release-notes paragraph per engine, and in java-ui a `build.xml` conditional plus three workflow steps.

---

### Task 1: `stepss-ci` skeleton and the test harness

**Files:**
- Create: `stepss-ci/.gitignore`
- Create: `stepss-ci/README.md`
- Create: `stepss-ci/sign-macos/sign.sh`
- Create: `stepss-ci/sign-macos/test_sign.sh`
- Create: `stepss-ci/.github/workflows/test.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: `sign.sh <command> [args...]`, dispatching on `$1`. Unknown commands exit 2. The test harness defines `fail`, `ok`, `run_sign` and a `FAKEBIN` on `PATH`; later tasks add cases to the same file.

- [ ] **Step 1: Create the repository on GitHub and clone it beside the others**

```bash
cd ~/Code/stepss
gh repo create SPS-L/stepss-ci --private --description "Shared CI actions for the STEPSS platform"
git clone git@github.com:SPS-L/stepss-ci.git
cd stepss-ci
```

- [ ] **Step 2: Write `.gitignore` before anything else is committed**

A committed gitlink under `.claude/` previously broke `git clone --recurse-submodules` for the whole umbrella, which is why both lines exist and why they go in first.

```gitignore
/.claude/
.mcp.json
```

- [ ] **Step 3: Write the failing test harness**

Create `sign-macos/test_sign.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for sign-macos/sign.sh. Runs on Linux with no credentials and no
# Apple tooling: every macOS binary the script calls is replaced by a fake on
# PATH that logs its argv to $ARGV_LOG and exits with $FAKE_EXIT.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$ROOT/sign.sh"
FAILURES=0
fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
ok()   { echo "ok: $*"; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
FAKEBIN="$TMPD/fakebin"; mkdir -p "$FAKEBIN"
ARGV_LOG="$TMPD/argv.log"

# One fake per Apple tool. Each appends its own name and arguments to the log
# so that a test can assert on what the script actually invoked, and honours
# FAKE_<TOOL>_EXIT so that a test can force a failure.
for tool in security codesign xcrun ditto spctl; do
  cat > "$FAKEBIN/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "$ARGV_LOG"
var="FAKE_\$(echo "$tool" | tr '[:lower:]' '[:upper:]')_EXIT"
out_var="FAKE_\$(echo "$tool" | tr '[:lower:]' '[:upper:]')_OUT"
[ -n "\${!out_var:-}" ] && printf '%s\n' "\${!out_var}"
exit "\${!var:-0}"
EOF
  chmod +x "$FAKEBIN/$tool"
done
export PATH="$FAKEBIN:$PATH"

run_sign() { : > "$ARGV_LOG"; bash "$SCRIPT" "$@" 2>&1; }

# ---- dispatcher ----------------------------------------------------------
out="$(run_sign no-such-command)"; rc=$?
[ "$rc" = 2 ] && ok "unknown command exits 2" || fail "unknown command exited $rc, expected 2"
case "$out" in *no-such-command*) ok "unknown command is named in the error" ;;
               *) fail "error did not name the command: $out" ;; esac

echo
[ "$FAILURES" = 0 ] && { echo "all tests passed"; exit 0; }
echo "$FAILURES test(s) failed"; exit 1
```

- [ ] **Step 4: Run the test to verify it fails**

```bash
bash sign-macos/test_sign.sh
```

Expected: FAIL, because `sign-macos/sign.sh` does not exist and `bash` reports "No such file or directory".

- [ ] **Step 5: Write the minimal `sign.sh`**

```bash
#!/usr/bin/env bash
# Developer ID signing and notarization for the STEPSS platform.
#
# Every command is a separate entry point so that the composite action can
# order them and so that each is testable in isolation. Nothing here reads a
# workflow context: credentials arrive as environment variables, which is what
# lets the whole file be exercised on Linux against fake Apple tools.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: sign.sh <command> [args]
  preflight                 refuse to continue without credentials
  keychain-open             create a temporary keychain and import the identity
  keychain-close            delete it
  cert-expiry               fail past the certificate's notAfter, warn within a year
  identity                  print the SHA-1 of the one signing identity
  sign <file>...            codesign with hardened runtime and entitlements
  verify <file>...          codesign --verify --strict
  notarize <file>...        submit to notarytool and wait for Accepted
  staple <bundle>           staple a ticket to a .dmg or .app and validate it
  assess <file>             spctl assessment
EOF
}

main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || { usage; exit 2; }
  shift
  case "$cmd" in
    *) echo "sign.sh: unknown command: $cmd" >&2; usage; exit 2 ;;
  esac
}

main "$@"
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
bash sign-macos/test_sign.sh
```

Expected: `ok: unknown command exits 2`, `ok: unknown command is named in the error`, `all tests passed`.

- [ ] **Step 7: Add the CI workflow that runs the tests**

Create `.github/workflows/test.yml`:

```yaml
name: test

on:
  push:
    branches: [main]
  pull_request:

jobs:
  unit:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
      - name: Shell syntax
        run: bash -n sign-macos/sign.sh sign-macos/test_sign.sh
      - name: Unit tests
        run: bash sign-macos/test_sign.sh
```

- [ ] **Step 8: Write `README.md`**

```markdown
# stepss-ci

Shared GitHub Actions for the STEPSS platform.

## `sign-macos`

Signs Mach-O files with the Cyprus University of Technology Developer ID
certificate and submits them to Apple's notary service. Used by
stepss-ramses, stepss-Codegen, stepss-helios, stepss-dyngraph and
stepss-java-ui.

Credentials come from organization secrets and variables scoped to those
five repositories. See
`docs/superpowers/specs/2026-09-22-macos-code-signing-design.md` in the
stepss umbrella repository for the design and for why the
`disable-library-validation` entitlement is mandatory.

All logic lives in `sign-macos/sign.sh` and is unit-tested on Linux by
`sign-macos/test_sign.sh`, which needs neither credentials nor a Mac.
```

- [ ] **Step 9: Commit and push**

```bash
git add .gitignore README.md sign-macos/sign.sh sign-macos/test_sign.sh .github/workflows/test.yml
git commit -m "Add stepss-ci with the sign-macos skeleton and its test harness"
git push -u origin main
```

---

### Task 2: Credential preflight

A skip when credentials are missing publishes unsigned binaries under a green run, so the only acceptable behaviour is a loud failure that names the missing variable.

**Files:**
- Modify: `stepss-ci/sign-macos/sign.sh`
- Modify: `stepss-ci/sign-macos/test_sign.sh`

**Interfaces:**
- Consumes: the dispatcher from Task 1.
- Produces: `sign.sh preflight`, reading `APPLE_SIGNING_P12`, `APPLE_SIGNING_P12_PASSWORD`, `APPLE_NOTARY_P8`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`. Exits 1 naming the first missing variable. When `SIGN_NOTARIZE` is `false`, the three notary variables are not required.

- [ ] **Step 1: Write the failing tests**

Insert before the summary block at the end of `test_sign.sh`:

```bash
# ---- preflight -----------------------------------------------------------
export APPLE_SIGNING_P12="Zm9v" APPLE_SIGNING_P12_PASSWORD="pw" \
       APPLE_NOTARY_KEY_P8="YmFy" APPLE_NOTARY_KEY_ID="8A4L5VF84Z" \
       APPLE_NOTARY_ISSUER_ID="69a6de82-68c9-47e3-e053-5b8c7c11a4d1"

out="$(run_sign preflight)"; rc=$?
[ "$rc" = 0 ] && ok "preflight passes with every credential set" \
               || fail "preflight failed with a full environment: $out"

out="$(APPLE_SIGNING_P12= run_sign preflight)"; rc=$?
[ "$rc" = 1 ] && ok "preflight fails without the certificate" \
               || fail "preflight exited $rc without the certificate, expected 1"
case "$out" in *APPLE_SIGNING_P12*) ok "preflight names the missing variable" ;;
               *) fail "preflight did not name APPLE_SIGNING_P12: $out" ;; esac

out="$(APPLE_NOTARY_ISSUER_ID= run_sign preflight)"; rc=$?
[ "$rc" = 1 ] && ok "preflight fails without the issuer id" \
               || fail "preflight exited $rc without the issuer id, expected 1"

out="$(APPLE_NOTARY_ISSUER_ID= SIGN_NOTARIZE=false run_sign preflight)"; rc=$?
[ "$rc" = 0 ] && ok "preflight ignores notary credentials when not notarizing" \
               || fail "preflight exited $rc in sign-only mode: $out"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash sign-macos/test_sign.sh
```

Expected: four FAIL lines, each reporting exit 2, because `preflight` is not yet a known command.

- [ ] **Step 3: Implement `preflight`**

Add the function above `main` and the case to the dispatcher:

```bash
require_var() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "sign.sh: $name is empty." >&2
    echo "Signing cannot proceed. This step does not skip, because a skipped" >&2
    echo "signing step publishes unsigned binaries under a green run." >&2
    exit 1
  fi
}

cmd_preflight() {
  require_var APPLE_SIGNING_P12
  require_var APPLE_SIGNING_P12_PASSWORD
  if [ "${SIGN_NOTARIZE:-true}" != "false" ]; then
    require_var APPLE_NOTARY_KEY_P8
    require_var APPLE_NOTARY_KEY_ID
    require_var APPLE_NOTARY_ISSUER_ID
  fi
  echo "Credentials present."
}
```

```bash
    preflight) cmd_preflight "$@" ;;
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash sign-macos/test_sign.sh
```

Expected: six `ok:` lines and `all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add sign-macos/sign.sh sign-macos/test_sign.sh
git commit -m "sign-macos: refuse to run without credentials rather than skipping"
```

---

### Task 3: Certificate expiry guard

The certificate expires on 2031-09-12 and the apt signing key on 2031-08-15, four weeks apart. Both would otherwise fail silently on the day, which is what the year of warning is for. The date arithmetic is a pure function so that an expired certificate can be tested without manufacturing one.

**Files:**
- Modify: `stepss-ci/sign-macos/sign.sh`
- Modify: `stepss-ci/sign-macos/test_sign.sh`

**Interfaces:**
- Consumes: `require_var` from Task 2.
- Produces: `sign.sh cert-expiry <notAfter>` where `<notAfter>` is an OpenSSL date string such as `Sep 12 06:46:04 2031 GMT`. Exits 1 when past, exits 0 with a warning on stderr within 365 days, exits 0 silently otherwise. `days_until` is the pure helper and works on both GNU and BSD `date`.

- [ ] **Step 1: Write the failing tests**

```bash
# ---- cert-expiry ---------------------------------------------------------
out="$(run_sign cert-expiry "Sep 12 06:46:04 2031 GMT")"; rc=$?
[ "$rc" = 0 ] && ok "a certificate valid for years passes" \
               || fail "cert-expiry rejected a 2031 date: $out"

out="$(run_sign cert-expiry "Jan 01 00:00:00 2020 GMT")"; rc=$?
[ "$rc" = 1 ] && ok "an expired certificate fails" \
               || fail "cert-expiry exited $rc on a 2020 date, expected 1"
case "$out" in *expired*) ok "the failure says expired" ;;
               *) fail "the failure did not say expired: $out" ;; esac

soon="$(date -u -d '+90 days' '+%b %d %H:%M:%S %Y GMT' 2>/dev/null \
        || date -u -v+90d '+%b %d %H:%M:%S %Y GMT')"
out="$(run_sign cert-expiry "$soon")"; rc=$?
[ "$rc" = 0 ] && ok "a certificate expiring in 90 days still passes" \
               || fail "cert-expiry exited $rc on a near date: $out"
case "$out" in *90\ days*|*89\ days*|*91\ days*) ok "the warning counts the days" ;;
               *) fail "no day count in the warning: $out" ;; esac
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash sign-macos/test_sign.sh
```

Expected: five FAIL lines reporting exit 2.

- [ ] **Step 3: Implement `days_until` and `cert-expiry`**

```bash
# GNU date on the Linux test runner, BSD date on the macOS runner. The format
# is OpenSSL's notAfter, e.g. "Sep 12 06:46:04 2031 GMT".
days_until() {
  local when="$1" target now
  if date --version >/dev/null 2>&1; then
    target="$(date -u -d "$when" +%s)"
  else
    target="$(date -u -j -f "%b %d %T %Y %Z" "$when" +%s)"
  fi
  now="$(date -u +%s)"
  echo $(( (target - now) / 86400 ))
}

cmd_cert_expiry() {
  local when="${1:?sign.sh cert-expiry needs a notAfter string}"
  local days; days="$(days_until "$when")"
  if [ "$days" -lt 0 ]; then
    echo "sign.sh: the signing certificate expired on $when." >&2
    echo "Every macOS release fails until it is replaced. See the rotation" >&2
    echo "notes in the stepss umbrella CLAUDE.md." >&2
    exit 1
  fi
  if [ "$days" -lt 365 ]; then
    echo "sign.sh: WARNING, the signing certificate expires in $days days, on $when." >&2
  fi
  echo "Certificate valid for $days more days."
}
```

```bash
    cert-expiry) cmd_cert_expiry "$@" ;;
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash sign-macos/test_sign.sh
```

Expected: eleven `ok:` lines and `all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add sign-macos/sign.sh sign-macos/test_sign.sh
git commit -m "sign-macos: fail on an expired certificate, warn a year ahead"
```

---

### Task 4: Keychain lifecycle and identity resolution

Resolving the identity by SHA-1 rather than by name is what makes a wrong or absent certificate fail loudly instead of matching nothing.

**Files:**
- Modify: `stepss-ci/sign-macos/sign.sh`
- Modify: `stepss-ci/sign-macos/test_sign.sh`

**Interfaces:**
- Consumes: `require_var`.
- Produces: `sign.sh keychain-open` creating `$RUNNER_TEMP/stepss-signing.keychain-db`; `sign.sh keychain-close` deleting it; `sign.sh identity` printing one 40-character uppercase hex hash on stdout, exiting 1 when `security find-identity` reports zero or more than one.

- [ ] **Step 1: Write the failing tests**

```bash
# ---- identity ------------------------------------------------------------
one_identity='  1) A1B2C3D4E5F60718293A4B5C6D7E8F9012345678 "Developer ID Application: Cyprus University of Technology (SWZD63F3C7)"
     1 valid identities found'
out="$(FAKE_SECURITY_OUT="$one_identity" run_sign identity)"; rc=$?
[ "$rc" = 0 ] && ok "identity succeeds with exactly one" \
               || fail "identity exited $rc with one identity: $out"
[ "$out" = "A1B2C3D4E5F60718293A4B5C6D7E8F9012345678" ] \
  && ok "identity prints the bare hash" || fail "identity printed: $out"

none='     0 valid identities found'
out="$(FAKE_SECURITY_OUT="$none" run_sign identity)"; rc=$?
[ "$rc" = 1 ] && ok "identity fails when the keychain holds none" \
               || fail "identity exited $rc with no identity"

two="$one_identity
  2) FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF \"Developer ID Application: Other (XXXX)\""
out="$(FAKE_SECURITY_OUT="$two" run_sign identity)"; rc=$?
[ "$rc" = 1 ] && ok "identity fails when the keychain holds two" \
               || fail "identity exited $rc with two identities"

# ---- keychain lifecycle --------------------------------------------------
export RUNNER_TEMP="$TMPD"
out="$(run_sign keychain-open)"; rc=$?
[ "$rc" = 0 ] && ok "keychain-open succeeds" || fail "keychain-open: $out"
grep -q 'security create-keychain' "$ARGV_LOG" \
  && ok "keychain-open creates a keychain" || fail "no create-keychain in: $(cat "$ARGV_LOG")"
grep -q 'security import' "$ARGV_LOG" \
  && ok "keychain-open imports the identity" || fail "no import in: $(cat "$ARGV_LOG")"
grep -q 'security set-key-partition-list' "$ARGV_LOG" \
  && ok "keychain-open sets the partition list" || fail "no partition list in: $(cat "$ARGV_LOG")"

out="$(run_sign keychain-close)"; rc=$?
[ "$rc" = 0 ] && ok "keychain-close succeeds" || fail "keychain-close: $out"
grep -q 'security delete-keychain' "$ARGV_LOG" \
  && ok "keychain-close deletes the keychain" || fail "no delete in: $(cat "$ARGV_LOG")"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash sign-macos/test_sign.sh
```

Expected: ten FAIL lines reporting exit 2.

- [ ] **Step 3: Implement the three commands**

```bash
keychain_path() { echo "${RUNNER_TEMP:?RUNNER_TEMP is unset}/stepss-signing.keychain-db"; }

cmd_keychain_open() {
  require_var APPLE_SIGNING_P12
  require_var APPLE_SIGNING_P12_PASSWORD
  local kc; kc="$(keychain_path)"
  local kcpass; kcpass="$(openssl rand -base64 24)"
  local p12="${RUNNER_TEMP}/identity.p12"

  printf '%s' "$APPLE_SIGNING_P12" | base64 --decode > "$p12"
  security create-keychain -p "$kcpass" "$kc"
  security set-keychain-settings -lut 21600 "$kc"
  security unlock-keychain -p "$kcpass" "$kc"
  # -A is deliberately not used: the partition list below grants access to
  # codesign alone rather than to every application on the runner.
  security import "$p12" -k "$kc" -P "$APPLE_SIGNING_P12_PASSWORD" \
           -T /usr/bin/codesign -T /usr/bin/productsign
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
           -s -k "$kcpass" "$kc"
  security list-keychains -d user -s "$kc" "$(security list-keychains -d user | tr -d ' "')"
  rm -f "$p12"
  echo "Keychain ready at $kc"
}

cmd_keychain_close() {
  local kc; kc="$(keychain_path)"
  security delete-keychain "$kc" || true
  echo "Keychain removed."
}

cmd_identity() {
  local listing count hash
  listing="$(security find-identity -v -p codesigning "$(keychain_path)")"
  count="$(printf '%s\n' "$listing" | grep -c -E '^[[:space:]]*[0-9]+\) [0-9A-F]{40} ' || true)"
  if [ "$count" -ne 1 ]; then
    echo "sign.sh: expected exactly one code signing identity, found $count." >&2
    printf '%s\n' "$listing" >&2
    exit 1
  fi
  hash="$(printf '%s\n' "$listing" | grep -o -E '[0-9A-F]{40}' | head -n1)"
  printf '%s\n' "$hash"
}
```

```bash
    keychain-open)  cmd_keychain_open "$@" ;;
    keychain-close) cmd_keychain_close "$@" ;;
    identity)       cmd_identity "$@" ;;
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash sign-macos/test_sign.sh
```

Expected: twenty-one `ok:` lines and `all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add sign-macos/sign.sh sign-macos/test_sign.sh
git commit -m "sign-macos: temporary keychain and identity resolution by hash"
```

---

### Task 5: Signing and verification

**Files:**
- Modify: `stepss-ci/sign-macos/sign.sh`
- Modify: `stepss-ci/sign-macos/test_sign.sh`
- Create: `stepss-ci/sign-macos/entitlements.plist`

**Interfaces:**
- Consumes: `cmd_identity`.
- Produces: `sign.sh sign <file>...` and `sign.sh verify <file>...`. Signing passes `--force --timestamp --options runtime --entitlements <plist> --sign <hash>`; the plist defaults to `entitlements.plist` beside the script and is overridden by `SIGN_ENTITLEMENTS`.

- [ ] **Step 1: Write `entitlements.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- The engines link against Homebrew's gfortran, OpenMP and OpenBLAS
       runtimes, which carry ad-hoc signatures. Library validation, which the
       hardened runtime enables by default and which notarization makes
       mandatory, refuses to load a dylib signed by another team. Without this
       key the binaries pass Gatekeeper and then fail to start. -->
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
```

- [ ] **Step 2: Write the failing tests**

```bash
# ---- sign and verify -----------------------------------------------------
: > "$TMPD/ramses"; : > "$TMPD/ramses.so"
out="$(FAKE_SECURITY_OUT="$one_identity" run_sign sign "$TMPD/ramses" "$TMPD/ramses.so")"; rc=$?
[ "$rc" = 0 ] && ok "sign succeeds over two files" || fail "sign: $out"
[ "$(grep -c '^codesign ' "$ARGV_LOG")" = 2 ] \
  && ok "sign invokes codesign once per file" || fail "codesign calls: $(grep -c '^codesign ' "$ARGV_LOG")"
grep -q -- '--options runtime' "$ARGV_LOG" \
  && ok "sign enables the hardened runtime" || fail "no --options runtime: $(cat "$ARGV_LOG")"
grep -q -- '--timestamp' "$ARGV_LOG" \
  && ok "sign requests a secure timestamp" || fail "no --timestamp"
grep -q -- '--entitlements' "$ARGV_LOG" \
  && ok "sign passes entitlements" || fail "no --entitlements"
grep -q 'A1B2C3D4E5F60718293A4B5C6D7E8F9012345678' "$ARGV_LOG" \
  && ok "sign uses the resolved hash" || fail "hash not used: $(cat "$ARGV_LOG")"

out="$(FAKE_SECURITY_OUT="$one_identity" FAKE_CODESIGN_EXIT=1 run_sign sign "$TMPD/ramses")"; rc=$?
[ "$rc" != 0 ] && ok "a codesign failure fails the step" || fail "sign swallowed a codesign failure"

out="$(run_sign sign "$TMPD/does-not-exist")"; rc=$?
[ "$rc" = 1 ] && ok "sign fails on a missing file" || fail "sign exited $rc on a missing file"

out="$(run_sign verify "$TMPD/ramses")"; rc=$?
[ "$rc" = 0 ] && ok "verify succeeds" || fail "verify: $out"
grep -q -- '--verify --strict' "$ARGV_LOG" \
  && ok "verify is strict" || fail "verify not strict: $(cat "$ARGV_LOG")"
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
bash sign-macos/test_sign.sh
```

Expected: ten FAIL lines reporting exit 2.

- [ ] **Step 4: Implement `sign` and `verify`**

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cmd_sign() {
  [ "$#" -gt 0 ] || { echo "sign.sh: sign needs at least one file" >&2; exit 2; }
  local ents="${SIGN_ENTITLEMENTS:-$SCRIPT_DIR/entitlements.plist}"
  local hash; hash="$(cmd_identity)"
  local f
  for f in "$@"; do
    [ -f "$f" ] || { echo "sign.sh: no such file: $f" >&2; exit 1; }
  done
  for f in "$@"; do
    echo "Signing $f"
    codesign --force --timestamp --options runtime \
             --entitlements "$ents" --sign "$hash" "$f"
  done
}

cmd_verify() {
  [ "$#" -gt 0 ] || { echo "sign.sh: verify needs at least one file" >&2; exit 2; }
  local f
  for f in "$@"; do
    codesign --verify --strict --verbose=2 "$f"
  done
}
```

```bash
    sign)   cmd_sign "$@" ;;
    verify) cmd_verify "$@" ;;
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bash sign-macos/test_sign.sh
```

Expected: thirty-one `ok:` lines and `all tests passed`.

- [ ] **Step 6: Commit**

```bash
git add sign-macos/sign.sh sign-macos/test_sign.sh sign-macos/entitlements.plist
git commit -m "sign-macos: sign with hardened runtime and the library-validation entitlement"
```

---

### Task 6: Notarization, stapling and assessment

A rejected submission must print Apple's reason, because the run log is the only place anyone will look.

**Files:**
- Modify: `stepss-ci/sign-macos/sign.sh`
- Modify: `stepss-ci/sign-macos/test_sign.sh`

**Interfaces:**
- Consumes: `require_var`.
- Produces: `sign.sh notarize <file>...` zipping the files and submitting them, failing unless the status is `Accepted`; `sign.sh staple <bundle>`; `sign.sh assess <file>`.

- [ ] **Step 1: Write the failing tests**

```bash
# ---- notarize ------------------------------------------------------------
accepted='{"id":"abc-123","status":"Accepted"}'
out="$(FAKE_XCRUN_OUT="$accepted" run_sign notarize "$TMPD/ramses")"; rc=$?
[ "$rc" = 0 ] && ok "notarize succeeds on Accepted" || fail "notarize: $out"
grep -q 'xcrun notarytool submit' "$ARGV_LOG" \
  && ok "notarize submits" || fail "no submit: $(cat "$ARGV_LOG")"
grep -q -- '--wait' "$ARGV_LOG" \
  && ok "notarize waits for the verdict" || fail "no --wait"
grep -q '69a6de82-68c9-47e3-e053-5b8c7c11a4d1' "$ARGV_LOG" \
  && ok "notarize passes the issuer id" || fail "no issuer id: $(cat "$ARGV_LOG")"
grep -q 'ditto ' "$ARGV_LOG" \
  && ok "notarize builds a zip with ditto" || fail "no ditto call"

invalid='{"id":"abc-123","status":"Invalid"}'
out="$(FAKE_XCRUN_OUT="$invalid" run_sign notarize "$TMPD/ramses")"; rc=$?
[ "$rc" = 1 ] && ok "notarize fails on Invalid" || fail "notarize exited $rc on Invalid"
case "$out" in *Invalid*) ok "the failure reports the status" ;;
               *) fail "status not reported: $out" ;; esac
grep -q 'notarytool log' "$ARGV_LOG" \
  && ok "a rejection fetches Apple's log" || fail "no log fetch: $(cat "$ARGV_LOG")"

# ---- staple and assess ---------------------------------------------------
out="$(run_sign staple "$TMPD/STEPSS.dmg")"; rc=$?
[ "$rc" = 0 ] && ok "staple succeeds" || fail "staple: $out"
grep -q 'xcrun stapler staple' "$ARGV_LOG" && ok "staple staples" || fail "no staple call"
grep -q 'xcrun stapler validate' "$ARGV_LOG" && ok "staple validates" || fail "no validate call"

out="$(run_sign assess "$TMPD/ramses")"; rc=$?
[ "$rc" = 0 ] && ok "assess succeeds" || fail "assess: $out"
grep -q '^spctl ' "$ARGV_LOG" && ok "assess calls spctl" || fail "no spctl call"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash sign-macos/test_sign.sh
```

Expected: fourteen FAIL lines reporting exit 2.

- [ ] **Step 3: Implement the three commands**

```bash
cmd_notarize() {
  [ "$#" -gt 0 ] || { echo "sign.sh: notarize needs at least one file" >&2; exit 2; }
  require_var APPLE_NOTARY_KEY_P8
  require_var APPLE_NOTARY_KEY_ID
  require_var APPLE_NOTARY_ISSUER_ID

  local work="${RUNNER_TEMP:?RUNNER_TEMP is unset}/notary"
  mkdir -p "$work"
  local p8="$work/key.p8"
  printf '%s' "$APPLE_NOTARY_KEY_P8" | base64 --decode > "$p8"

  # A .dmg or .app is submitted as itself; bare executables are zipped,
  # because notarytool accepts only .zip, .pkg and .dmg.
  local payload
  if [ "$#" -eq 1 ] && case "$1" in *.dmg|*.pkg|*.app) true ;; *) false ;; esac; then
    payload="$1"
  else
    payload="$work/payload.zip"
    ditto -c -k --keepParent "$@" "$payload"
  fi

  local json status
  json="$(xcrun notarytool submit "$payload" \
            --key "$p8" --key-id "$APPLE_NOTARY_KEY_ID" \
            --issuer "$APPLE_NOTARY_ISSUER_ID" \
            --wait --output-format json)"
  rm -f "$p8"
  status="$(printf '%s' "$json" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
  echo "notarytool status: $status"
  if [ "$status" != "Accepted" ]; then
    local id; id="$(printf '%s' "$json" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
    echo "sign.sh: notarization was not accepted (status: $status)." >&2
    # Apple's reason is the only actionable part and lives behind a second
    # call, so it is fetched here rather than left for someone to run by hand.
    xcrun notarytool log "$id" --key-id "$APPLE_NOTARY_KEY_ID" \
          --issuer "$APPLE_NOTARY_ISSUER_ID" >&2 || true
    exit 1
  fi
}

cmd_staple() {
  local bundle="${1:?sign.sh staple needs a .dmg, .pkg or .app}"
  xcrun stapler staple "$bundle"
  xcrun stapler validate "$bundle"
}

cmd_assess() {
  local target="${1:?sign.sh assess needs a path}"
  case "$target" in
    *.dmg|*.pkg) spctl --assess --type install --verbose=4 "$target" ;;
    *)           spctl --assess --type execute --verbose=4 "$target" ;;
  esac
}
```

```bash
    notarize) cmd_notarize "$@" ;;
    staple)   cmd_staple "$@" ;;
    assess)   cmd_assess "$@" ;;
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash sign-macos/test_sign.sh
```

Expected: forty-five `ok:` lines and `all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add sign-macos/sign.sh sign-macos/test_sign.sh
git commit -m "sign-macos: notarize, staple and assess"
```

---

### Task 7: The composite action

**Files:**
- Create: `stepss-ci/sign-macos/action.yml`

**Interfaces:**
- Consumes: every `sign.sh` command.
- Produces: `SPS-L/stepss-ci/sign-macos@v1` with inputs `paths`, `mode` (`sign`, `notarize`, `sign-and-notarize`), `bundle` and `entitlements`, and outputs `keychain-path` and `identity`. Credentials arrive through the calling step's `env`.

- [ ] **Step 1: Write `action.yml`**

```yaml
name: Sign and notarize macOS binaries
description: >
  Signs Mach-O files with the Cyprus University of Technology Developer ID
  certificate and submits them to Apple's notary service.

inputs:
  mode:
    description: "sign, notarize, or sign-and-notarize"
    required: false
    default: sign-and-notarize
  paths:
    description: "Newline-separated Mach-O files. Empty leaves signing to the caller."
    required: false
    default: ""
  bundle:
    description: "A .dmg, .pkg or .app to staple after notarization."
    required: false
    default: ""
  entitlements:
    description: "Override the entitlements plist."
    required: false
    default: ""

outputs:
  keychain-path:
    description: "The temporary keychain, for tools that must be told where to look."
    value: ${{ steps.open.outputs.keychain }}
  identity:
    description: "SHA-1 of the resolved signing identity."
    value: ${{ steps.open.outputs.identity }}

runs:
  using: composite
  steps:
    - name: Preflight
      shell: bash
      env:
        SIGN_NOTARIZE: ${{ inputs.mode == 'sign' && 'false' || 'true' }}
      run: bash "${{ github.action_path }}/sign.sh" preflight

    - name: Open the keychain
      id: open
      shell: bash
      run: |
        set -euo pipefail
        bash "${{ github.action_path }}/sign.sh" keychain-open
        identity="$(bash "${{ github.action_path }}/sign.sh" identity)"
        echo "identity=$identity" >> "$GITHUB_OUTPUT"
        echo "keychain=$RUNNER_TEMP/stepss-signing.keychain-db" >> "$GITHUB_OUTPUT"
        # The certificate is read back from the keychain rather than from the
        # PKCS#12, because the bundle's certificate bag is RC2-encrypted and
        # the macOS openssl is LibreSSL.
        not_after="$(security find-certificate -p -c "Developer ID Application" \
                     "$RUNNER_TEMP/stepss-signing.keychain-db" \
                     | openssl x509 -noout -enddate | cut -d= -f2)"
        bash "${{ github.action_path }}/sign.sh" cert-expiry "$not_after"

    - name: Sign
      if: inputs.paths != '' && inputs.mode != 'notarize'
      shell: bash
      env:
        SIGN_ENTITLEMENTS: ${{ inputs.entitlements }}
      run: |
        set -euo pipefail
        mapfile -t files < <(printf '%s\n' "${{ inputs.paths }}" | sed '/^[[:space:]]*$/d')
        bash "${{ github.action_path }}/sign.sh" sign "${files[@]}"
        bash "${{ github.action_path }}/sign.sh" verify "${files[@]}"

    - name: Notarize
      if: inputs.mode != 'sign'
      shell: bash
      run: |
        set -euo pipefail
        if [ -n "${{ inputs.bundle }}" ]; then
          bash "${{ github.action_path }}/sign.sh" notarize "${{ inputs.bundle }}"
          bash "${{ github.action_path }}/sign.sh" staple "${{ inputs.bundle }}"
          bash "${{ github.action_path }}/sign.sh" assess "${{ inputs.bundle }}"
        else
          mapfile -t files < <(printf '%s\n' "${{ inputs.paths }}" | sed '/^[[:space:]]*$/d')
          bash "${{ github.action_path }}/sign.sh" notarize "${files[@]}"
          bash "${{ github.action_path }}/sign.sh" assess "${files[0]}"
        fi

    - name: Close the keychain
      if: always()
      shell: bash
      run: bash "${{ github.action_path }}/sign.sh" keychain-close
```

- [ ] **Step 2: Check the YAML parses and the script is syntactically valid**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('sign-macos/action.yml'))" && echo "action.yml parses"
bash -n sign-macos/sign.sh && echo "sign.sh parses"
```

Expected: both lines print.

- [ ] **Step 3: Commit, push and tag**

```bash
git add sign-macos/action.yml
git commit -m "sign-macos: the composite action"
git push
git tag v1
git push origin v1
```

- [ ] **Step 4: Open the repository to the organization**

In the `stepss-ci` repository settings, under Actions, General, set Access to "Accessible from repositories in the SPS-L organization". Without this the five callers cannot resolve the action and fail at checkout with a 404. Confirm with:

```bash
gh api repos/SPS-L/stepss-ci/actions/permissions/access --jq .access_level
```

Expected: `organization`.

---

### Task 8: Helios adoption, and the ad-hoc signature it currently applies

Helios is first because `ci.yml` runs on every push, so the chain is proved against real artefacts without any release being at risk. Its existing fallback would overwrite a Developer ID signature with an ad-hoc one, so it changes in the same commit.

**Files:**
- Modify: `stepss-helios/.github/workflows/ci.yml:62-63` (after Build) and `:93-97` (the macOS smoke test)

**Interfaces:**
- Consumes: `SPS-L/stepss-ci/sign-macos@v1`.
- Produces: signed and notarized `build/helios` and `build/libhelios_api.dylib` in the `macos-14` matrix leg, packed unchanged into `stepss-helios-macos-arm64.tar.gz` and `helios-api-macos-arm64.tar.gz`.

- [ ] **Step 1: Add the signing step immediately after Build**

Insert after the `Build` step, which ends at `ci.yml:63`:

```yaml
      # Before the tests, not after: every gate below then exercises the signed
      # binary, so a signature that prevents it from starting fails here rather
      # than on a user's machine. Skipped on pull requests, which receive no
      # secrets.
      - name: Sign and notarize (macOS)
        if: runner.os == 'macOS' && github.event_name != 'pull_request'
        uses: SPS-L/stepss-ci/sign-macos@v1
        with:
          paths: |
            build/helios
            build/libhelios_api.dylib
        env:
          APPLE_SIGNING_P12: ${{ secrets.APPLE_SIGNING_P12 }}
          APPLE_SIGNING_P12_PASSWORD: ${{ secrets.APPLE_SIGNING_P12_PASSWORD }}
          APPLE_NOTARY_KEY_P8: ${{ secrets.APPLE_NOTARY_KEY_P8 }}
          APPLE_NOTARY_KEY_ID: ${{ vars.APPLE_NOTARY_KEY_ID }}
          APPLE_NOTARY_ISSUER_ID: ${{ vars.APPLE_NOTARY_ISSUER_ID }}
```

- [ ] **Step 2: Replace the ad-hoc fallback in the macOS smoke test**

Replace `ci.yml:93-97` with:

```yaml
      - name: C API smoke test (macOS)
        if: runner.os == 'macOS'
        run: |
          # An assertion, no longer a fallback. This used to re-sign ad-hoc when
          # the check failed, which would now replace the Developer ID signature
          # applied above. On a pull request there is no signature to find, so
          # the ad-hoc one is applied there and only there.
          if [ "${{ github.event_name }}" = "pull_request" ]; then
            codesign -dv build/libhelios_api.dylib 2>/dev/null \
              || codesign --force -s - build/libhelios_api.dylib
          else
            codesign -dv build/libhelios_api.dylib
          fi
          python3 tests/smoke/api_smoke.py --lib build/libhelios_api.dylib
```

- [ ] **Step 3: Verify the workflow parses**

```bash
cd ~/Code/stepss/stepss-helios
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo "ci.yml parses"
```

Expected: `ci.yml parses`.

- [ ] **Step 4: Commit and push**

```bash
git add .github/workflows/ci.yml
git commit -m "CI: sign and notarize the macOS binaries"
git push
```

- [ ] **Step 5: Watch the run and confirm the evidence, not the colour**

```bash
gh run watch --repo SPS-L/stepss-helios
gh run view --repo SPS-L/stepss-helios --log | grep -E 'Certificate valid|notarytool status|accepted|Signing '
```

Expected: `Certificate valid for NNNN more days`, `Signing build/helios`, `Signing build/libhelios_api.dylib`, `notarytool status: Accepted`, and an `spctl` assessment naming `Notarized Developer ID`. A green run alone is not the evidence; a skipped signing step also produces one.

- [ ] **Step 6: Let several merges pass before continuing**

Do not begin Task 9 until at least two further pushes to `main` have signed and notarized without intervention. This is the whole purpose of adopting helios first.

---

### Task 9: RAMSES adoption

**Files:**
- Modify: `stepss-ramses/.github/workflows/release.yml:278-279` (after Build in `build-macos`) and `:392-394` (the release-notes text)

**Interfaces:**
- Consumes: `SPS-L/stepss-ci/sign-macos@v1`.
- Produces: signed `build/Release_gnu_m/ramses` and `build/Release_gnu_m/ramses.so`, which travel unchanged into `ramses-macos-arm64-$VER.tar.gz`, `ramses-libs-macos-arm64-$VER.zip` and thence into the `stepss-python-ui` wheel.

- [ ] **Step 1: Add the signing step after Build, before the Dylib inventory**

```yaml
      - name: Sign and notarize
        uses: SPS-L/stepss-ci/sign-macos@v1
        with:
          paths: |
            build/Release_gnu_m/ramses
            build/Release_gnu_m/ramses.so
        env:
          APPLE_SIGNING_P12: ${{ secrets.APPLE_SIGNING_P12 }}
          APPLE_SIGNING_P12_PASSWORD: ${{ secrets.APPLE_SIGNING_P12_PASSWORD }}
          APPLE_NOTARY_KEY_P8: ${{ secrets.APPLE_NOTARY_KEY_P8 }}
          APPLE_NOTARY_KEY_ID: ${{ vars.APPLE_NOTARY_KEY_ID }}
          APPLE_NOTARY_ISSUER_ID: ${{ vars.APPLE_NOTARY_ISSUER_ID }}
```

Placing it before `Dylib inventory (informational)` means the `otool -L` output in the log describes the artefact that ships.

- [ ] **Step 2: Correct the release-notes text**

Replace the three lines at `release.yml:392-394`, which read exactly

```
          - Binaries are unsigned; macOS quarantines downloaded files, so
            first run may be blocked by Gatekeeper. Fix with:
            xattr -dr com.apple.quarantine <extracted files>
```

with

```
          - Binaries are signed by Cyprus University of Technology and
            notarized by Apple. No quarantine workaround is needed. A first
            run on a machine that has never seen them needs network access
            once, so that Gatekeeper can confirm the notarization.
```

- [ ] **Step 3: Verify the workflow parses**

```bash
cd ~/Code/stepss/stepss-ramses
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" && echo "release.yml parses"
```

- [ ] **Step 4: Commit and push**

```bash
git add .github/workflows/release.yml
git commit -m "Release: sign and notarize the macOS binaries"
git push
```

- [ ] **Step 5: Confirm at the next release**

This workflow runs only on `release` and `workflow_dispatch`, and a dispatch cuts a real release, so there is nothing to run now. At the next RAMSES release, check the macOS leg for `notarytool status: Accepted` before announcing it.

---

### Task 10: CODEGEN adoption

**Files:**
- Modify: `stepss-Codegen/.github/workflows/release.yml:211-215` (after Build in `build-macos`) and `:290-293` (the generated INSTALL.md)

**Interfaces:**
- Consumes: `SPS-L/stepss-ci/sign-macos@v1`.
- Produces: signed `Release_m/CODEGEN`, travelling unchanged into `codegen-macos-arm64-$VER.tar.gz` and into the `stepss-cg-studio` wheel.

- [ ] **Step 1: Add the signing step after Build**

```yaml
      - name: Sign and notarize
        uses: SPS-L/stepss-ci/sign-macos@v1
        with:
          paths: |
            Release_m/CODEGEN
        env:
          APPLE_SIGNING_P12: ${{ secrets.APPLE_SIGNING_P12 }}
          APPLE_SIGNING_P12_PASSWORD: ${{ secrets.APPLE_SIGNING_P12_PASSWORD }}
          APPLE_NOTARY_KEY_P8: ${{ secrets.APPLE_NOTARY_KEY_P8 }}
          APPLE_NOTARY_KEY_ID: ${{ vars.APPLE_NOTARY_KEY_ID }}
          APPLE_NOTARY_ISSUER_ID: ${{ vars.APPLE_NOTARY_ISSUER_ID }}
```

- [ ] **Step 2: Correct the generated INSTALL.md**

Replace the paragraph at `release.yml:290-293`, which reads exactly

```
          macOS only: the binary is unsigned and macOS quarantines downloaded
          files, so the first run may be blocked by Gatekeeper. Clear it with
          \`xattr -dr com.apple.quarantine CODEGEN\`. Intel Macs are not covered
          by this build.
```

with

```
          macOS only: the binary is signed by Cyprus University of Technology
          and notarized by Apple, so no quarantine workaround is needed. The
          first run on a machine that has never seen it needs network access
          once, so that Gatekeeper can confirm the notarization. Intel Macs
          are not covered by this build.
```

- [ ] **Step 3: Verify, commit and push**

```bash
cd ~/Code/stepss/stepss-Codegen
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" && echo "release.yml parses"
git add .github/workflows/release.yml
git commit -m "Release: sign and notarize the macOS binary"
git push
```

---

### Task 11: DYNGRAPH adoption

**Files:**
- Modify: `stepss-dyngraph/.github/workflows/release.yml:215-219` (after Build in `build-macos`) and `:301-304` (the generated INSTALL.md)

**Interfaces:**
- Consumes: `SPS-L/stepss-ci/sign-macos@v1`.
- Produces: signed `Release_m/dyngraph`, travelling unchanged into `dyngraph-macos-arm64-$VER.tar.gz`.

- [ ] **Step 1: Add the signing step after Build**

```yaml
      - name: Sign and notarize
        uses: SPS-L/stepss-ci/sign-macos@v1
        with:
          paths: |
            Release_m/dyngraph
        env:
          APPLE_SIGNING_P12: ${{ secrets.APPLE_SIGNING_P12 }}
          APPLE_SIGNING_P12_PASSWORD: ${{ secrets.APPLE_SIGNING_P12_PASSWORD }}
          APPLE_NOTARY_KEY_P8: ${{ secrets.APPLE_NOTARY_KEY_P8 }}
          APPLE_NOTARY_KEY_ID: ${{ vars.APPLE_NOTARY_KEY_ID }}
          APPLE_NOTARY_ISSUER_ID: ${{ vars.APPLE_NOTARY_ISSUER_ID }}
```

- [ ] **Step 2: Correct the generated INSTALL.md**

Replace the paragraph at `release.yml:301-304`, which reads exactly

```
          macOS only: the binary is unsigned and macOS quarantines downloaded
          files, so the first run may be blocked by Gatekeeper. Clear it with
          \`xattr -dr com.apple.quarantine dyngraph\`. Intel Macs are not
          covered by this build.
```

with

```
          macOS only: the binary is signed by Cyprus University of Technology
          and notarized by Apple, so no quarantine workaround is needed. The
          first run on a machine that has never seen it needs network access
          once, so that Gatekeeper can confirm the notarization. Intel Macs
          are not covered by this build.
```

- [ ] **Step 3: Verify, commit and push**

```bash
cd ~/Code/stepss/stepss-dyngraph
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" && echo "release.yml parses"
git add .github/workflows/release.yml
git commit -m "Release: sign and notarize the macOS binary"
git push
```

---

### Task 12: Record the `jpackage` signing options before using them

The option set differs between JDK versions and must be read rather than assumed. This task produces a recorded fact, not a code change.

**Files:**
- Create: `stepss-java-ui/docs/superpowers/notes/2026-09-22-jpackage-mac-options.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the exact option names Task 13 writes into `build.xml`, and the default entitlements Task 13 asserts on.

- [ ] **Step 1: Add a temporary workflow that prints what the runner has**

Create `.github/workflows/jpackage-probe.yml` on a branch:

```yaml
name: jpackage-probe
on: workflow_dispatch
jobs:
  probe:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-java@v5
        with:
          distribution: temurin
          java-version: "21"
      - name: Options
        run: jpackage --help | sed -n '/Platform dependent option/,$p'
      - name: Default entitlements shipped with the JDK
        run: |
          jdk="$(/usr/libexec/java_home -v 21)"
          find "$jdk" -name '*.plist' -path '*jpackage*' -print -exec cat {} \;
```

- [ ] **Step 2: Run it and read the output**

```bash
cd ~/Code/stepss/stepss-java-ui
gh workflow run jpackage-probe.yml --ref <branch>
gh run watch --repo SPS-L/stepss-java-ui
```

- [ ] **Step 3: Write down what it said**

Record in `docs/superpowers/notes/2026-09-22-jpackage-mac-options.md`: the exact spelling of every `--mac-*` option the runner's `jpackage` accepts, and the full contents of the default entitlements plist. Two questions must be answered in writing: whether `--mac-signing-key-user-name` takes the identity with or without the `Developer ID Application: ` prefix, and whether the default entitlements already contain `com.apple.security.cs.disable-library-validation`.

- [ ] **Step 4: Delete the probe workflow and commit the note**

```bash
git rm .github/workflows/jpackage-probe.yml
git add docs/superpowers/notes/2026-09-22-jpackage-mac-options.md
git commit -m "Record the jpackage macOS signing options on the JDK 21 runner"
```

---

### Task 13: java-ui signing and notarization

**Files:**
- Modify: `stepss-java-ui/build.xml:465-520` (the `bundle` target's conditionals) and `:568-588` (the `jpackage` exec)
- Modify: `stepss-java-ui/.github/workflows/release.yml:530-545` (around "Build the installer")

**Interfaces:**
- Consumes: `SPS-L/stepss-ci/sign-macos@v1`, and the option spellings recorded in Task 12.
- Produces: a signed `STEPSS.app` inside a notarized and stapled `STEPSS-<version>.dmg`, attached under its existing name.

- [ ] **Step 1: Add the signing arguments to `build.xml`**

Insert beside the other conditionals in the `bundle` target, before the `jpackage` exec. Use the option spellings recorded in Task 12; the form below assumes `--mac-signing-key-user-name` without the prefix, which Task 12 confirms or corrects.

```xml
  <!-- macOS signing. Absent when mac.signing.keychain is unset, so a local
       build on a developer's Mac still produces an unsigned bundle rather
       than failing for want of a certificate. The identifier is written out
       rather than derived from the main class package for the reason the
       win-upgrade-uuid comment gives: an identity the operating system uses
       to recognise one installation as the successor of another must not
       move because somebody renamed a package. -->
  <condition property="bundle.sign.args"
             value="--mac-sign --mac-signing-key-user-name '${mac.signing.identity}' --mac-signing-keychain '${mac.signing.keychain}' --mac-package-identifier my.stepss">
   <and>
    <os family="mac"/>
    <isset property="mac.signing.keychain"/>
   </and>
  </condition>
  <property name="bundle.sign.args" value=""/>
```

Add the argument to the `jpackage` exec, after `${bundle.platform.args}`:

```xml
   <arg line="${bundle.sign.args}"/>
```

- [ ] **Step 2: Open the keychain before the installer is built**

Insert into `release.yml` immediately before the `Build the installer` step:

```yaml
      - name: Open the signing keychain (macOS)
        id: signing
        if: matrix.os == 'macos-latest'
        uses: SPS-L/stepss-ci/sign-macos@v1
        with:
          mode: sign
          paths: ""
        env:
          APPLE_SIGNING_P12: ${{ secrets.APPLE_SIGNING_P12 }}
          APPLE_SIGNING_P12_PASSWORD: ${{ secrets.APPLE_SIGNING_P12_PASSWORD }}
```

With `paths` empty the action prepares and verifies the keychain and does nothing else, which is precisely what `jpackage` needs from it.

- [ ] **Step 3: Pass the keychain to `ant`**

Replace the `Build the installer` step with:

```yaml
      - name: Build the installer
        shell: bash
        run: |
          set -euo pipefail
          args=()
          if [ "${{ matrix.os }}" = "macos-latest" ]; then
            args+=("-Dmac.signing.keychain=${{ steps.signing.outputs.keychain-path }}")
            args+=("-Dmac.signing.identity=Cyprus University of Technology (SWZD63F3C7)")
          fi
          ant bundle "-Dbundle.type=--type ${{ matrix.type }}" "${args[@]}"
```

- [ ] **Step 4: Assert the entitlements rather than trusting them**

Insert after `Build the installer`:

```yaml
      # jpackage supplies its own entitlements and passing --mac-entitlements
      # would replace them wholesale, taking the JVM's own requirements with
      # it. So the outcome is asserted instead of dictated. Without this key
      # the app cannot load Homebrew's gfortran and every simulation fails.
      - name: Assert the app image carries disable-library-validation
        if: matrix.os == 'macos-latest'
        run: |
          set -euo pipefail
          app="$(find bundle -maxdepth 3 -name 'STEPSS.app' -print -quit)"
          [ -n "$app" ] || { echo "no STEPSS.app found under bundle/"; exit 1; }
          codesign -d --entitlements - --xml "$app" > ents.xml
          plutil -p ents.xml
          grep -q 'com.apple.security.cs.disable-library-validation' ents.xml || {
            echo "The app image lacks disable-library-validation."
            echo "The engines will fail to load Homebrew's gfortran at run time."
            echo "Pass --mac-entitlements with a plist that reproduces the"
            echo "jpackage defaults plus this key. See the note recorded under"
            echo "docs/superpowers/notes/."
            exit 1
          }
```

- [ ] **Step 5: Notarize and staple the finished disk image**

Insert after the assertion and before `Attach it to the release`:

```yaml
      - name: Notarize and staple the .dmg
        if: matrix.os == 'macos-latest'
        uses: SPS-L/stepss-ci/sign-macos@v1
        with:
          mode: notarize
          bundle: bundle/STEPSS-${{ needs.release.outputs.version }}.dmg
        env:
          APPLE_SIGNING_P12: ${{ secrets.APPLE_SIGNING_P12 }}
          APPLE_SIGNING_P12_PASSWORD: ${{ secrets.APPLE_SIGNING_P12_PASSWORD }}
          APPLE_NOTARY_KEY_P8: ${{ secrets.APPLE_NOTARY_KEY_P8 }}
          APPLE_NOTARY_KEY_ID: ${{ vars.APPLE_NOTARY_KEY_ID }}
          APPLE_NOTARY_ISSUER_ID: ${{ vars.APPLE_NOTARY_ISSUER_ID }}
```

The `.dmg` name that `jpackage` produces carries the version without a leading `v`, matching `--app-version ${stepss.version}`. If the path does not resolve, print `ls bundle/` in the step before assuming the name is wrong.

- [ ] **Step 6: Verify the build file and the workflow parse**

```bash
cd ~/Code/stepss/stepss-java-ui
ant -p >/dev/null && echo "build.xml parses"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" && echo "release.yml parses"
```

- [ ] **Step 7: Commit and push**

```bash
git add build.xml .github/workflows/release.yml
git commit -m "Release: sign the app image and notarize the .dmg"
git push
```

- [ ] **Step 8: Understand what the first run costs**

This workflow publishes on dispatch. The three bundle legs attach to a draft and a failure in any of them discards it, so a notarization failure costs a discarded draft and no tag, which is the designed behaviour and not a reason to add a retry.

---

### Task 14: The comment in python-ui that is no longer true

**Files:**
- Modify: `stepss-python-ui/tools/update_helios_libs.sh:11-14`

**Interfaces:**
- Consumes: nothing. The script's behaviour does not change; only a comment that gives users wrong advice.

- [ ] **Step 1: Replace the quarantine advice**

The comment currently tells a reader to strip the quarantine attribute from `libhelios_api.dylib`. Replace those lines with:

```bash
# The macOS library is signed by Cyprus University of Technology and notarized
# by Apple, so no quarantine workaround is needed. Files installed by pip are
# not quarantined in any case.
```

- [ ] **Step 2: Run the script's own tests**

```bash
cd ~/Code/stepss/stepss-python-ui
bash tools/test_update_ramses_libs.sh
```

Expected: `all tests passed`. The comment change cannot affect it, and a failure means something else is wrong and must be investigated before committing.

- [ ] **Step 3: Commit and push**

```bash
git add tools/update_helios_libs.sh
git commit -m "The bundled macOS library is signed; drop the quarantine advice"
git push
```

---

### Task 15: The umbrella record and the submodule

**Files:**
- Modify: `CLAUDE.md` (umbrella)
- Modify: `.gitmodules` by way of `git submodule add`

**Interfaces:**
- Consumes: the pushed `stepss-ci` repository from Task 7.
- Produces: the umbrella tracking `stepss-ci`, and a written record of the three cross-repository facts plus the two expiry dates.

- [ ] **Step 1: Add the submodule with a relative URL**

```bash
cd ~/Code/stepss
git submodule add -b main ../stepss-ci.git stepss-ci
```

- [ ] **Step 2: Confirm the gitignore rule holds for the new component**

```bash
for d in stepss-*/; do
  grep -q 'claude' "$d.gitignore" 2>/dev/null &&
    grep -q 'mcp.json' "$d.gitignore" 2>/dev/null || echo "${d%/}"
done
```

Expected: no output. A printed `stepss-ci` means Task 1 Step 2 was skipped and must be fixed before this pointer is committed.

- [ ] **Step 3: Update the secrets grep expectation in `CLAUDE.md`**

In the "Secrets and cross-repo contracts" section, the block currently reads:

```sh
grep -rho 'secrets\.[A-Z_]*' stepss-*/.github/workflows/*.yml | sort -u
# expect STEPSS_TOKEN and APT_GPG_PRIVATE_KEY, and nothing else
```

Change the comment to:

```sh
# expect STEPSS_TOKEN, APT_GPG_PRIVATE_KEY, APPLE_SIGNING_P12,
# APPLE_SIGNING_P12_PASSWORD and APPLE_NOTARY_KEY_P8, and nothing else
```

Add a paragraph after the `APT_GPG_PRIVATE_KEY` discussion recording that the three Apple names are signing material of the same class, that they live at organization level scoped to five repositories rather than being copied per repository, and that the two identifiers they are used with, `APPLE_NOTARY_KEY_ID` and `APPLE_NOTARY_ISSUER_ID`, are deliberately organization *variables* so that the grep above keeps answering the question it is asked.

- [ ] **Step 4: Add a macOS signing section to `CLAUDE.md`**

Write a section covering the three facts that are invisible from inside any single repository:

- The hardened runtime, which notarization makes mandatory, enables library validation, and every engine links Homebrew's GCC runtime, so `com.apple.security.cs.disable-library-validation` is mandatory. Removing it produces binaries that pass Gatekeeper and then fail to start, which no CI gate downstream of signing will catch unless the gates run on the signed binary, which is why signing is placed before them.
- A notarization ticket is keyed on the code directory hash and staples only to a `.dmg`, `.pkg` or `.app`. The command-line components therefore ship notarized but unstapled binaries inside their existing `.tar.gz` assets, and their asset names were deliberately left alone because `update_ramses_libs.sh`, `update_codegen.sh` and `versions.properties` all fail hard on a rename.
- Engine binaries are signed in their own repositories because they travel as `.tar.gz` resources inside `stepss.jar` and `jpackage` never sees them. Signing java-ui alone would produce a signed container holding unsigned engines. This also fixes the `stepss-python-ui` and `stepss-cg-studio` wheels, which bundle the same binaries.

Record the two dates in the same section: the certificate expires 2031-09-12, four weeks after the apt signing key's 2031-08-15, and the Apple Developer Program membership renews annually on 2026-11-20, a lapse of which revokes the certificate. The certificate has a guard inside the action; the membership has none.

- [ ] **Step 5: Commit the pointer and the record together**

```bash
git add .gitmodules stepss-ci CLAUDE.md
git commit -m "Add stepss-ci and record the macOS signing contract"
```

---

## Self-Review

**Spec coverage.** Section 2 of the spec, credentials, is already complete and is carried into Global Constraints. Section 3's four constraints appear as Task 5 (entitlement), Tasks 9 to 11 (asset names untouched), Task 13 (jpackage cannot sign the engines) and Task 8 (helios first). Section 5's nine steps map onto Tasks 2 to 6, with the action assembling them in Task 7. Section 6's placement rule is enforced in Tasks 8 to 11 and the conflicting helios line is Task 8 Step 2. Section 7 is Tasks 12 and 13, including the option verification the spec insisted on. Section 8's order is the task order. Section 9 is Task 15. Section 10 is Tasks 9, 10, 11 and 14. Section 11's dates are Task 3 and Task 15 Step 4. Section 12 is satisfied by omission: `stepss-uramses` appears in no task.

**Placeholders.** None. The one deliberately deferred value, the exact `jpackage` option spelling, is not a placeholder but the deliverable of Task 12, which runs before the task that consumes it.

**Type consistency.** The command names `preflight`, `keychain-open`, `keychain-close`, `cert-expiry`, `identity`, `sign`, `verify`, `notarize`, `staple` and `assess` are used identically in `sign.sh`, in the tests and in `action.yml`. The environment variable names match the organization secrets and variables exactly. The action outputs `keychain-path` and `identity`, and Task 13 consumes `steps.signing.outputs.keychain-path` under that spelling.
