#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build-and-push.sh — Build, security-check and push the scale-in OCI Function
# Usage: ./build-and-push.sh [IMAGE_TAG]
#   IMAGE_TAG defaults to the placeholder below. Either pass your own image tag
#   as the first argument or replace <region-key> and <your-tenancy-namespace>
#   with your OCIR region code and tenancy namespace, e.g.
#   fra.ocir.io/mytenancy/openvidu-oci-scalein:main
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_TAG="${1:-<region-key>.ocir.io/<your-tenancy-namespace>/openvidu-oci-scalein:main}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

FAILURES=0

# ---------------------------------------------------------------------------
# 1. SOURCE FILE SCAN — check before building
# ---------------------------------------------------------------------------
echo ""
info "=== Step 1: Scanning source files for secrets ==="

# Patterns that should never appear in source. Tuned to match real secret
# values, not placeholders in docstrings ("<ocid>", "your-token-here"). Min
# lengths roughly match the shortest credentials these services issue.
SECRET_PATTERNS=(
  # Real OCIDs have a 50+ char unique_id; require ≥30 to skip placeholders
  # like `ocid1.instance...`.
  'ocid1\.[a-z]+\.[a-z0-9-]+\.[a-z0-9-]*\.[a-z0-9]{30,}'
  # PEM private keys
  'BEGIN (RSA|EC|OPENSSH|PGP) PRIVATE'
  # Assignments with a non-trivial literal value (≥12 non-quote chars)
  'password\s*[:=]\s*["\x27][^"\x27\s]{12,}'
  'secret\s*[:=]\s*["\x27][^"\x27\s]{16,}'
  'token\s*[:=]\s*["\x27][^"\x27\s]{16,}'
  'api[_-]?key\s*[:=]\s*["\x27][^"\x27\s]{16,}'
  # Hardcoded Bearer tokens (real tokens are dozens of chars).
  'Authorization:\s*Bearer\s+[A-Za-z0-9_-]{20,}'
  # AWS access keys (well-defined format)
  'AKIA[0-9A-Z]{16}'
)

# Lines marked `# noqa: secret-scan` are exempt (e.g. a docstring example);
# anything else hitting a pattern fails.
for pattern in "${SECRET_PATTERNS[@]}"; do
  matches=$(grep -rniE "$pattern" "$SCRIPT_DIR" \
    --include="*.py" --include="*.txt" --include="*.json" --include="*.yaml" \
    --include="*.yml" --include="*.env" \
    2>/dev/null \
    | grep -vE 'noqa:\s*secret-scan' \
    || true)
  if [ -n "$matches" ]; then
    fail "Potential secret found matching pattern '$pattern':"
    echo "$matches" | sed 's/^/       /'
  fi
done

[ "$FAILURES" -eq 0 ] && pass "No secrets found in source files"

# ---------------------------------------------------------------------------
# 2. BUILD
# ---------------------------------------------------------------------------
echo ""
info "=== Step 2: Building image: $IMAGE_TAG ==="

docker build --no-cache -t "$IMAGE_TAG" "$SCRIPT_DIR"
pass "Image built successfully"

# ---------------------------------------------------------------------------
# 3. IMAGE LAYER SCAN — check the built image filesystem
# ---------------------------------------------------------------------------
echo ""
info "=== Step 3: Scanning image filesystem for secrets ==="

# Paths/files that are common secret locations
SUSPICIOUS_PATHS=(
  "/root/.oci"
  "/home"
  "/.aws"
  "/etc/oci"
  "config.json"
  ".env"
  "*.pem"
  "*.key"
  "id_rsa"
  "id_ecdsa"
)

for path in "${SUSPICIOUS_PATHS[@]}"; do
  found=$(docker run --rm --entrypoint sh "$IMAGE_TAG" \
    -c "find /root /home /function /etc/oci -path /proc -prune -o -name '$path' -print 2>/dev/null" \
    2>/dev/null || true)
  if [ -n "$found" ]; then
    fail "Suspicious path found in image: $found"
  fi
done

# Scan only /function (user code) — skip /python/packages (OCI SDK has
# intentional example OCIDs, key doc snippets, and 'Bearer Oracle' in its source)
info "Scanning image file contents (this may take a moment)..."
for pattern in 'ocid1\.' 'BEGIN.*PRIVATE' 'Authorization.*Bearer'; do
  found=$(docker run --rm --entrypoint sh "$IMAGE_TAG" \
    -c "grep -rniE '$pattern' /function 2>/dev/null | grep -v '.pyc' | head -5" \
    2>/dev/null || true)
  # Filter out legitimate SDK usage (variable names, not values)
  filtered=$(echo "$found" | grep -vE '(signer|get_resource_principals|Signer|auth\.)' || true)
  if [ -n "$filtered" ]; then
    fail "Potential secret in image matching '$pattern':"
    echo "$filtered" | sed 's/^/       /'
  fi
done

[ "$FAILURES" -eq 0 ] && pass "No secrets found in image filesystem"

# ---------------------------------------------------------------------------
# 4. ENTRYPOINT CHECK
# ---------------------------------------------------------------------------
echo ""
info "=== Step 4: Verifying ENTRYPOINT ==="

entrypoint=$(docker inspect --format '{{json .Config.Entrypoint}}' "$IMAGE_TAG")
if echo "$entrypoint" | grep -q "fdk"; then
  pass "ENTRYPOINT contains fdk: $entrypoint"
else
  fail "ENTRYPOINT looks wrong: $entrypoint"
fi

# Verify the fdk binary actually exists at the declared path
fdk_path=$(echo "$entrypoint" | tr -d '[]"' | awk -F',' '{print $1}')
docker run --rm --entrypoint sh "$IMAGE_TAG" -c "test -f '$fdk_path'" 2>/dev/null \
  && pass "FDK binary exists at $fdk_path" \
  || fail "FDK binary NOT found at $fdk_path"

# ---------------------------------------------------------------------------
# 5. ENVIRONMENT VARIABLES CHECK — no secrets baked as ENV
# ---------------------------------------------------------------------------
echo ""
info "=== Step 5: Checking ENV variables in image ==="

env_vars=$(docker inspect --format '{{json .Config.Env}}' "$IMAGE_TAG")
suspicious_env=$(echo "$env_vars" | tr ',' '\n' | grep -iE '(password|secret|token|key|ocid)' \
  | grep -vE 'PYTHONPATH' || true)
if [ -n "$suspicious_env" ]; then
  fail "Suspicious ENV variable(s) baked into image: $suspicious_env"
else
  pass "No secrets in image ENV variables"
fi

# ---------------------------------------------------------------------------
# 6. SUMMARY
# ---------------------------------------------------------------------------
echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo -e "${RED}=== SECURITY CHECK FAILED: $FAILURES issue(s) found. Image NOT pushed. ===${NC}"
  docker image rm "$IMAGE_TAG" 2>/dev/null || true
  exit 1
fi

pass "All security checks passed ($FAILURES failures)"

# ---------------------------------------------------------------------------
# 7. PUSH
# ---------------------------------------------------------------------------
echo ""
info "=== Step 6: Pushing $IMAGE_TAG ==="

docker push "$IMAGE_TAG"
pass "Image pushed successfully: $IMAGE_TAG"
echo ""
