#!/bin/bash
# Persist the submission ID before waiting, then allow a retry of the same bytes.
set -euo pipefail
archive=${1:?}
attach=${2:?}
record=${3:?}
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  auth=(--keychain-profile "$NOTARY_PROFILE")
  if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then auth+=(--keychain "$NOTARY_KEYCHAIN"); fi
else
  : "${NOTARY_KEY_PATH:?Set NOTARY_PROFILE or a notary API key path}"
  : "${NOTARY_KEY_ID:?Set the notary API key ID}"
  auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID")
  if [[ -n "${NOTARY_ISSUER:-}" ]]; then auth+=(--issuer "$NOTARY_ISSUER"); fi
fi
if [[ -f "$record.done" ]]; then
  xcrun stapler validate "$attach"
  exit 0
fi
if [[ ! -f "$record.id" ]]; then
  # Apple returns JSON with the submission UUID when the upload succeeds.
  xcrun notarytool submit "$archive" "${auth[@]}" --output-format json > "$record.submit.tmp"
  jq -er '.id | select(test("^[A-Fa-f0-9-]{36}$"))' "$record.submit.tmp" > "$record.id.tmp"
  shasum -a 256 "$archive" | awk '{print $1}' > "$record.sha256"
  mv "$record.id.tmp" "$record.id"
fi
id=$(cat "$record.id")
printf 'Checking notarization %s\n' "$id"
wait_status=0
xcrun notarytool wait "$id" "${auth[@]}" --timeout 90m --output-format json > "$record.wait.tmp" || wait_status=$?
if ! jq -e '.status == "Accepted" or .status == "Invalid" or .status == "Rejected"' "$record.wait.tmp" >/dev/null; then
  echo "Apple has not returned a final result for $id. Resume this package to retry." >&2; exit 1
fi
xcrun notarytool log "$id" "${auth[@]}" "$record.log.tmp"
jq '{jobId, status, statusSummary, uploadDate, sha256, issues: [(.issues // [])[] | {severity, code, path, message, architecture}]}' \
  "$record.log.tmp" > "$record.json"
jq -e --arg id "$id" --arg digest "$(cat "$record.sha256")" '(.jobId|ascii_downcase) == ($id|ascii_downcase) and (.sha256|ascii_downcase) == $digest and .status == "Accepted" and (.issues|length) == 0' "$record.json" >/dev/null || {
  echo "Review Apple results at $record.json before distributing." >&2; exit 1
}
[[ "$wait_status" = 0 ]]
xcrun stapler staple "$attach"
xcrun stapler validate "$attach"
touch "$record.done"
