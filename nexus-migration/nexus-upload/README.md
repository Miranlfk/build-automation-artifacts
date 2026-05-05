# Nexus 3 Artifact Upload Script

This script uploads Maven release artifacts to a **Nexus Repository 3** instance using the Nexus REST API. It is designed to integrate with the **WSO2 M2 Release Plugin** in Jenkins and runs automatically as a post-build step during Maven release builds.

## How It Works

1. Detects that the current build is an M2 release build via `IS_M2RELEASEBUILD=true`.
2. Resolves artifact coordinates (`groupId`, `artifactId`, `version`) from environment variables or `pom.xml`.
3. Searches for release artifacts in multiple possible locations (custom artifacts directory, `target/checkout`, Maven local repository).
4. Recursively scans the discovered directories and classifies files (POM, JAR, sources, javadoc, WAR).
5. Uploads each unique Maven component (`groupId:artifactId:version`) to the configured Nexus 3 repository via the REST API.
6. Selects the target repository (`staging` or `releases`) based on the `CLOSE_NEXUS_STAGE` flag.

## Requirements

- `bash`
- `curl`

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `IS_M2RELEASEBUILD` | Yes | `false` | Must be `true` for the script to run. Set automatically by the M2 Release Plugin. |
| `MVN_RELEASE_VERSION` | Yes | — | The Maven release version being built. Set automatically by the M2 Release Plugin. |
| `NEXUS_URL` | No | `https://maven3-upgrade.wso2.org/nexus/` | Base URL of the Nexus 3 instance. |
| `NEXUS_USER` | No | — | Nexus username. Falls back to `M2RELEASE_NEXUS_USER` or `MVNEXT_NEXUS_USER`. |
| `NEXUS_PASSWORD` | No | — | Nexus password. Falls back to `M2RELEASE_NEXUS_PASSWORD` or `MVNEXT_NEXUS_PASSWORD`. |
| `CLOSE_NEXUS_STAGE` | No | — | When `true`, artifacts are uploaded to the `releases` repository; otherwise `staging`. |
| `NEXUS_API_PATH` | No | `service/rest/v1/components?repository=` | Nexus REST API path for component upload. |
| `M2RELEASE_GROUP_ID` | No | — | Maven `groupId`. Resolved from environment or `pom.xml` if not set. |
| `ARTIFACT_ID` | No | — | Maven `artifactId`. Resolved from environment or `pom.xml` if not set. |

## Repository Selection

| `CLOSE_NEXUS_STAGE` | Target Repository |
|---|---|
| `true` | `releases` |
| `false` / unset | `staging` |

## Artifact Discovery

The script searches for artifacts in the following locations (in order):

1. `<workspace>/artifacts/<artifactId>/<version>/`
2. `<workspace>/target/checkout/`
3. `<workspace>/target/checkout/target/`
4. `<workspace>/.repository/<group/path>/<artifactId>/<version>/`

Within each location it supports two scanning strategies:
- **Maven local repository layout** — identifies `.pom` files and derives coordinates from the directory path.
- **Maven project checkout layout** — reads `pom.xml` files and scans `target/` directories for built artifacts.

## Usage with Jenkins

1. Add the script to your Jenkins agent.
2. In your Maven Release job, add this script as a **post-build step** (e.g. using the Managed Script Plugin).
3. Ensure the M2 Release Plugin is configured and credentials are available as environment variables (`NEXUS_USER`, `NEXUS_PASSWORD`).

```groovy
// Example Jenkins pipeline snippet
post {
    success {
        sh 'bash /path/to/nexus3.sh'
    }
}
```

## Notes

- The script exits silently (exit 0) when `IS_M2RELEASEBUILD` is not `true`, making it safe to include unconditionally as a post-build step.
- If Cloudflare blocks are detected in the Nexus response, a descriptive error is logged with remediation steps.
- Upload failures for individual components are collected and reported at the end; the script exits with code `1` if any component fails.
