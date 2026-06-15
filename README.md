A backup provider for Rama that uses AWS S3.

# Usage

To use the provider, download the provided jar from the [releases page](https://github.com/redplanetlabs/rama-s3-backup-provider/releases) and include it in the `lib/` directory of the Conductor and Supervisor nodes.

Set the `backup.provider` config to:

`com.rpl.rama.backup.s3.S3BackupProvider <bucket-name>`

Replace `<bucket-name>` with the name of the bucket you wish to use.

It is advisable to create the bucket with the desired permissions and
other configuration.  However, the provider will try to create the
bucket if it does not exist.

# Credentials

The Rama s3-provider use the AWS [default provider chain](https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html) to determine credentials.

The recommended way to provide credentials when running Rama on AWS is
to use [instance profiles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles.html).

# Tests

The tests use a docker container to run adobe/s3mock, which provides a
mock of the Amazon S3 service.

On mac you may need to set DOCKER_HOST, e.g.

`export DOCKER_HOST=unix:///${HOME}/.docker/run/docker.sock`

To run integration tests

`mvn verify`

# Shaded build & relocation gates

The fat jar is built with `maven-shade-plugin`, which **relocates** the bundled
AWS SDK under `com.rpl.rama.backup.s3.shaded.*`. This is deliberate: the jar is
dropped into a Rama cluster's `lib/` alongside an application module that carries
its *own* AWS SDK. Without relocation the two copies share the `software.amazon.awssdk`
package on one classpath and the older one silently shadows the newer (e.g. a
missing `SdkSystemSetting.AWS_AUTH_SCHEME_PREFERENCE` field at runtime). Relocation
makes that collision structurally impossible, so the bundled SDK version is free to
differ from any application's. (`io.netty` is intentionally *not* bundled — Rama's
own `lib/` supplies it; the relocated Netty async-HTTP wrapper binds to it.)

Two mechanical gates guard the relocation and **must be rerun after any change to
the bundled AWS SDK version** (both run automatically in CI, see
`.github/workflows/shading-gate.yml`):

```
mvn -DskipTests package
scripts/verify-shading.sh         # static:     asserts the SDK is fully relocated
scripts/verify-shading-smoke.sh   # functional: shaded jar does real S3 I/O against
                                  #             S3Mock with NO un-relocated SDK present
```

One residual check cannot live in this repo: a real Rama **backup → restore** on a
throwaway cluster exercises Rama actually loading `S3BackupProvider` through its own
classloader. Run it once per provider release.
