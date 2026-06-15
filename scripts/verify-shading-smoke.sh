#!/usr/bin/env bash
# verify-shading-smoke.sh — FUNCTIONAL half of the shading gate.
#
# Exercises the SHADED jar end-to-end against a real S3 endpoint (adobe/s3mock),
# with the un-relocated AWS SDK DELIBERATELY EXCLUDED from the classpath. The
# shaded jar is therefore the only possible source of SDK classes: if relocation
# were incomplete (a missing class, an unrewritten ServiceLoader/interceptor
# resource, a Class.forName string), the provider would fail to construct or to
# talk to S3 — there is no un-relocated SDK to silently fall back to.
#
# This is the companion to verify-shading.sh (the static half). Together they are
# the mechanical, rerun-on-every-SDK-bump gate. Requires: docker, mvn, a JDK that
# can run the built jar. Self-contained: starts and tears down its own S3Mock.
#
# Usage: scripts/verify-shading-smoke.sh   (run from the repo root)
set -euo pipefail

PORT="${S3MOCK_PORT:-9090}"
CONTAINER="rama-s3-shade-smoke"
WORK="$(mktemp -d)"
cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

JAR="$(ls -1 target/rama-s3-backup-provider-*.jar 2>/dev/null \
       | grep -vE 'sources|javadoc|original-' | head -n1)"
if [[ -z "${JAR:-}" || ! -f "$JAR" ]]; then
  echo "No shaded jar found — run 'mvn -DskipTests package' first." >&2
  exit 2
fi
echo "Shaded jar: $JAR"

# Full test-scope classpath, minus the un-relocated AWS SDK. What remains (Netty,
# slf4j, Rama, reactive-streams) mirrors what Rama's lib/ supplies at deploy time.
mvn -q dependency:build-classpath -DincludeScope=test -Dmdep.outputFile="$WORK/cp-full.txt"
tr ':' '\n' < "$WORK/cp-full.txt" | grep -c . > "$WORK/full-count.txt" || true
tr ':' '\n' < "$WORK/cp-full.txt" \
  | grep -viE '/software/amazon/(awssdk|eventstream)/' > "$WORK/cp-nosdk.txt"
NOSDK="$(paste -sd: "$WORK/cp-nosdk.txt")"
full_n="$(cat "$WORK/full-count.txt")"; kept_n="$(grep -c . "$WORK/cp-nosdk.txt")"
echo "Removed $((full_n - kept_n)) un-relocated AWS SDK jars from the classpath ($kept_n entries remain)."

# Start a throwaway S3Mock (docker run directly — the fabric8 docker-maven-plugin
# is unreliable against some Docker Engine API versions).
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" -p "${PORT}:9090" \
  -e COM_ADOBE_TESTING_S3MOCK_REGION=eu-west-1 adobe/s3mock >/dev/null
echo -n "Waiting for S3Mock on :${PORT} "
for _ in $(seq 1 60); do
  if curl -fsS "http://localhost:${PORT}/favicon.ico" >/dev/null 2>&1; then break; fi
  echo -n "."; sleep 1
done
echo " ready"

cat > "$WORK/ShadeSmoke.java" <<EOF
import com.rpl.rama.backup.BackupProvider;
import com.rpl.rama.backup.s3.S3BackupProvider;
import java.io.ByteArrayInputStream;
import java.io.InputStream;

public class ShadeSmoke {
  public static void main(String[] args) throws Exception {
    System.setProperty("aws.region", "us-west-1");
    System.setProperty("aws.accessKeyId", "x");
    System.setProperty("aws.secretAccessKey", "y");
    BackupProvider p = new S3BackupProvider("http://localhost:${PORT}/shade-smoke");
    p.putObject("k/v", new ByteArrayInputStream("hello-shaded".getBytes()), 12L).get();
    if (!p.hasKey("k/v").get()) throw new RuntimeException("hasKey returned false");
    InputStream is = p.getObject("k/v").get();
    String got = new String(is.readAllBytes());
    if (!"hello-shaded".equals(got)) throw new RuntimeException("content mismatch: " + got);
    BackupProvider.KeysPage page = p.listKeysRecursive("", null).get();
    if (!page.keys.contains("k/v")) throw new RuntimeException("listKeys missing key: " + page.keys);
    p.close();
    System.out.println("SHADE SMOKE OK: content=" + got + " keys=" + page.keys);
  }
}
EOF

echo "Compiling smoke (classpath: shaded jar + Rama, NO un-relocated SDK)…"
javac -cp "$JAR:$NOSDK" -d "$WORK" "$WORK/ShadeSmoke.java"

echo "Running smoke (classpath excludes the un-relocated AWS SDK)…"
if java -cp "$WORK:$JAR:$NOSDK" ShadeSmoke; then
  echo "PASS: shaded jar performs real S3 I/O with no un-relocated SDK present"
else
  echo "FAILED: shaded jar could not perform S3 I/O — relocation is incomplete" >&2
  exit 1
fi
