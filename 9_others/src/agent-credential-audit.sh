#!/usr/bin/env bash
# #439: check the GitHub credential an agent holds against
# 9_others/agent-credential-policy.json. It never prints the token.
#
# Exit 0  the token is fine-grained, or classic with no scope beyond
#         allowed_classic_scopes
# Exit 1  the token has more scopes than allowed; each extra scope is printed
# Exit 2  no token was found, or GitHub did not accept it (so nothing was checked)
#
# Looks in both places an agent can get a token: $GH_TOKEN and `gh auth token`.
# In hermes tool shells GH_TOKEN is stripped but gh still has the token on
# disk, so checking only the env var would wrongly report "no token".
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
POLICY="${AGENT_CREDENTIAL_POLICY:-$ROOT/9_others/agent-credential-policy.json}"
API="${GITHUB_API_URL:-https://api.github.com}"
[ -f "$POLICY" ] || { echo "::error::policy not found at $POLICY"; exit 2; }
command -v jq >/dev/null || { echo "::error::jq is required"; exit 2; }

var="$(jq -r '.env_var' "$POLICY")"
fvar="$(jq -r '.fine_grained_env_var // empty' "$POLICY")"
tok=""; src=""
[ -n "$fvar" ] && [ -n "${!fvar:-}" ] && { tok="${!fvar}"; src="\$$fvar"; }
[ -n "$tok" ] || { tok="${!var:-}"; src="\$$var"; }
if [ -z "$tok" ] && command -v gh >/dev/null; then
    tok="$(env -u "$var" gh auth token 2>/dev/null || true)"; src="gh auth token"
fi
[ -n "$tok" ] || { echo "NO CREDENTIAL: \$$var is empty and gh has no token"; exit 2; }
echo "credential source: $src"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# The header goes in a file so the token never shows up in argv (ps).
printf 'Authorization: Bearer %s\n' "$tok" > "$T/h"
curl -sS -D - -o /dev/null -H @"$T/h" "$API/user" > "$T/resp" 2>/dev/null
code="$(tr -d '\r' < "$T/resp" | awk 'NR==1{print $2}')"
[ "$code" = "200" ] || { echo "GitHub rejected the credential (HTTP ${code:-none}); scopes not checked"; exit 2; }

# Remove the header name with sed. Do not split on ':' here, because scope
# values contain colons too (admin:org).
scopes="$(tr -d '\r' < "$T/resp" | sed -n 's/^[Xx]-[Oo][Aa][Uu][Tt][Hh]-[Ss][Cc][Oo][Pp][Ee][Ss]: *//p' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sort -u)"
if ! tr -d '\r' < "$T/resp" | grep -qi '^x-oauth-scopes:'; then
    # Fine-grained tokens send no X-OAuth-Scopes header; their permissions
    # are only visible in the GitHub UI.
    echo "fine-grained token: no classic scopes; confirm permissions against required list in the GitHub UI"
    exit 0
fi

excess="$(comm -23 <(printf '%s\n' "$scopes") <(jq -r '.allowed_classic_scopes[]' "$POLICY" | sort -u) | grep -v '^$')"

# Reported but not counted as failure: plaintext copies on disk. These widen
# who can read the token, but they do not add scopes.
for f in "$HOME/.git-credentials" "$HOME/.config/gh/hosts.yml"; do
    [ -f "$f" ] && grep -qF -- "$tok" "$f" 2>/dev/null && echo "plaintext copy on disk: $f"
done
tree="${AGENT_GIT_TREE:-$HOME/git}"
for g in "$tree"/*/.git; do
    [ -d "$g" ] || continue
    git --git-dir="$g" config --local --get-all credential.helper 2>/dev/null | grep -qx store \
        && echo "repo-local credential.helper=store (copies the token into \$HOME): ${g%/.git}"
done

if [ -n "$excess" ]; then
    echo "OVER-SCOPED classic token: $(printf '%s\n' "$excess" | wc -l) scope(s) beyond policy:"
    printf '  excess: %s\n' $excess
    exit 1
fi
echo "classic token within policy: $(printf '%s ' $scopes)"
exit 0
