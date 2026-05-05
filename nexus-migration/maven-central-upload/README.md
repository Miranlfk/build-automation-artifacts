# Maven Central Upload Script

This script uploads Maven release artifacts to **Maven Central** via the [Sonatype Central Publisher API](https://central.sonatype.org/publish/publish-portal-api/). It builds a bundle ZIP in Maven repository layout, attaches GPG signatures and checksums, uploads the bundle, and optionally auto-publishes based on the release stage.

## How It Works

1. Detects that the current build is an M2 release build via `IS_M2RELEASEBUILD=true`.
2. Resolves artifact coordinates from environment variables or `pom.xml`.
3. Discovers all Maven modules by scanning `pom.xml` files in the workspace.
4. Stages each module's artifacts (POM, JAR, sources, javadoc, WAR) into a Maven repository layout directory.
5. Generates GPG `.asc` signatures and MD5/SHA1 checksums for each file.
6. Packages everything into a single ZIP bundle.
7. Uploads the bundle to the Central Publisher API.
8. Polls for validation status and optionally triggers publishing.

## Requirements

- `bash`
- `curl`
- `jq`
- `python3`
- `gpg` (optional — required for signing)
- `zip`

## Environment Variables

### Credentials

| Variable | Description |
|---|---|
| `CENTRAL_USERNAME` | Maven Central username (User Token). |
| `CENTRAL_PASSWORD` | Maven Central password/token. |
| `CENTRAL_CREDS_USR` | Jenkins Credentials Binding username (alternative to above). |
| `CENTRAL_CREDS_PSW` | Jenkins Credentials Binding password (alternative to above). |

> **Note:** Use [User Tokens](https://central.sonatype.com/account) from your Sonatype account rather than your regular password.

### Build Variables (typically set by M2 Release Plugin)

| Variable | Required | Description |
|---|---|---|
| `IS_M2RELEASEBUILD` | Yes | Must be `true` for the script to run. |
| `MVN_RELEASE_VERSION` | Yes | The Maven release version. |
| `ARTIFACT_ID` / `M2RELEASE_ARTIFACT_ID` | No | Maven `artifactId`. Resolved from `pom.xml` if not set. |
| `CLOSE_NEXUS_STAGE` | No | When `true`, auto-publishing to Maven Central is enabled. |

### Configuration

| Variable | Default | Description |
|---|---|---|
| `CENTRAL_API_BASE` | `https://central.sonatype.com` | Base URL for the Central Publisher API. |
| `CENTRAL_PUBLISHING_TYPE` | `USER_MANAGED` | Set to `AUTOMATIC` to publish without manual approval. |
| `CENTRAL_DEPLOYMENT_NAME` | `groupId:artifactId:version` | Display name for the deployment. |
| `CENTRAL_AUTO_PUBLISH` | Follows `CLOSE_NEXUS_STAGE` | Set to `true` to publish automatically after validation. |
| `GPG_KEYID` | — | ID of the GPG key to use for signing. Uses default key if not set. |
| `SKIP_SIGNATURES` | `false` | Set to `true` to disable GPG signing. |
| `SKIP_CHECKSUMS` | `false` | Set to `true` to skip MD5/SHA1 checksum generation. |

## Auto-Publishing Behaviour

| `CLOSE_NEXUS_STAGE` | `CENTRAL_AUTO_PUBLISH` | Behaviour |
|---|---|---|
| `true` | (overridden to `true`) | Artifact is automatically published after validation. |
| `false` / unset | `true` | Artifact is automatically published after validation. |
| `false` / unset | `false` (default) | Artifact is uploaded and validated; manual publishing required via the [Central Portal](https://central.sonatype.com/publishing/deployments). |

## GPG Signing

The script automatically handles GPG availability:
- If `gpg` is not installed, signatures are skipped with a warning.
- If no secret keys are found, signatures are skipped with guidance on how to create or import a key.
- Set `GPG_KEYID` to use a specific key; otherwise the default key is used.
- Set `SKIP_SIGNATURES=true` to bypass signing entirely (not recommended for Maven Central).

## Usage with Jenkins

1. Configure a **Username/Password** credential in Jenkins using your Sonatype User Token.
2. Use the **Credentials Binding** plugin to expose the credential as `CENTRAL_CREDS_USR` and `CENTRAL_CREDS_PSW`.
3. Add the script as a post-build step in your Maven Release job.

```groovy
// Example Jenkins pipeline snippet
withCredentials([usernamePassword(
    credentialsId: 'maven-central-credentials',
    usernameVariable: 'CENTRAL_CREDS_USR',
    passwordVariable: 'CENTRAL_CREDS_PSW'
)]) {
    sh 'bash /path/to/maven-central.sh'
}
```

## Output

On completion a `central-upload-status.txt` file is written to the workspace (when running in Jenkins) containing:

```
DEPLOYMENT_ID=<id>
DEPLOYMENT_NAME=<name>
DEPLOYMENT_STATE=<VALIDATED|PUBLISHED>
BUNDLE_PATH=<path>
GROUP_ID=<groupId>
ARTIFACT_ID=<artifactId>
VERSION=<version>
CENTRAL_PORTAL_URL=https://central.sonatype.com/publishing/deployments
```

## References

- [Central Publisher API](https://central.sonatype.org/publish/publish-portal-api/)
- [Bundle Format](https://central.sonatype.org/publish/publish-portal-upload/)
- [GPG Requirements](https://central.sonatype.org/publish/requirements/gpg/)
