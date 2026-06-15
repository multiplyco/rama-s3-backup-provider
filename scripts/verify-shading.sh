#!/usr/bin/env bash
# verify-shading.sh — assert the shaded rama-s3-backup-provider jar fully
# relocates its bundled AWS SDK, so it cannot collide with a Rama application
# module's own AWS SDK on the shared Rama worker classpath.
#
# This is the STATIC half of the shading gate (the functional half is the
# S3Mock integration test, run against the shaded jar via `mvn verify`).
# It is mechanical and deterministic: rerun it after ANY change to the bundled
# AWS SDK version. It exits non-zero on the first relocation leak.
#
# Usage:
#   mvn -DskipTests package && scripts/verify-shading.sh
#   scripts/verify-shading.sh path/to/rama-s3-backup-provider-X.Y.Z.jar
set -euo pipefail

SHADED_PREFIX="com/rpl/rama/backup/s3/shaded"
ENTRYPOINT="com/rpl/rama/backup/s3/S3BackupProvider.class"   # referenced by FQN in rama.yaml backup.provider:

JAR="${1:-$(ls -1 target/rama-s3-backup-provider-*.jar 2>/dev/null \
            | grep -vE 'sources|javadoc|original-' | head -n1)}"

if [[ -z "${JAR:-}" || ! -f "$JAR" ]]; then
  echo "FAIL: no shaded jar found (build with 'mvn -DskipTests package' or pass a path)" >&2
  exit 2
fi
echo "Verifying $JAR"

fail=0
bad() { echo "  FAIL: $*"; fail=1; }
ok()  { echo "  ok:   $*"; }

entries="$(unzip -Z1 "$JAR")"

# (a) No un-relocated AWS SDK / eventstream / reactive-streams CLASS entries at the root.
leak="$(printf '%s\n' "$entries" | grep -E '^(software/amazon/awssdk|software/amazon/eventstream|org/reactivestreams)/' || true)"
if [[ -n "$leak" ]]; then
  bad "un-relocated class entries (SDK not under $SHADED_PREFIX):"
  printf '%s\n' "$leak" | sed 's/^/        /' | head
else
  ok "no root-level software.amazon.* / org.reactivestreams class entries"
fi

# (b) No service-loader files still NAMED for the un-relocated SDK
#     (ServicesResourceTransformer must rename them to the shaded package).
svc="$(printf '%s\n' "$entries" | grep -E '^META-INF/services/(software\.amazon|org\.reactivestreams)' || true)"
if [[ -n "$svc" ]]; then
  bad "un-renamed META-INF/services files:"
  printf '%s\n' "$svc" | sed 's/^/        /'
else
  ok "service-loader filenames rewritten to shaded package"
fi

# (c) No text resource (service files, and any execution.interceptors if a future
#     SDK bump introduces them) whose CONTENTS still name an un-relocated FQCN.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
unzip -qo "$JAR" -d "$tmp" 'META-INF/services/*' '*/execution.interceptors' 2>/dev/null || true
leaked_content=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if grep -Eq '^(software\.amazon\.(awssdk|eventstream)|org\.reactivestreams)' "$f"; then
    leaked_content+="${f#"$tmp"/}"$'\n'
  fi
done < <(find "$tmp" -type f 2>/dev/null)
if [[ -n "$leaked_content" ]]; then
  bad "text resources still naming un-relocated FQCNs (shade did not rewrite contents):"
  printf '%s' "$leaked_content" | sed 's/^/        /'
else
  ok "service/interceptor resource contents rewritten to shaded package"
fi

# (d) The provider entry point must remain at its ORIGINAL path — rama.yaml
#     resolves it by FQN, so over-broad relocation would break the cluster.
#     (herestring, not a pipe: avoids grep -q SIGPIPE under `set -o pipefail`.)
if grep -qxF "$ENTRYPOINT" <<<"$entries"; then
  ok "entry point $ENTRYPOINT present and un-relocated"
else
  bad "entry point $ENTRYPOINT missing — did a relocation pattern over-match com.rpl.rama.backup.s3?"
fi

# (e) Belt-and-suspenders: the provider's own (non-shaded) classes must carry no
#     UN-relocated 'software/amazon/awssdk' bytecode references (catches
#     Class.forName-style string literals shade did not rewrite). After shading,
#     every legitimate SDK ref is the shaded path 'shaded/software/amazon/awssdk',
#     so we tokenize and discard those before flagging what remains.
stray=0
while IFS= read -r c; do
  [[ -z "$c" ]] && continue
  hits="$(unzip -p "$JAR" "$c" | LC_ALL=C tr -c '[:print:]' '\n' \
          | grep -a 'software/amazon/awssdk' | grep -av 'shaded/software/amazon/awssdk' || true)"
  if [[ -n "$hits" ]]; then
    bad "stray un-relocated SDK reference in non-shaded class: $c"
    stray=1
  fi
done < <(grep -E '\.class$' <<<"$entries" | grep -vE "^($SHADED_PREFIX/|module-info)")
[[ $stray -eq 0 ]] && ok "no stray SDK references in provider's own classes"

if [[ $fail -eq 0 ]]; then
  echo "PASS: AWS SDK fully relocated under $SHADED_PREFIX"
  exit 0
else
  echo "FAILED: relocation is incomplete — see failures above"
  exit 1
fi
