# Update Build Jobs Script

This Jenkins Groovy script updates Maven Release job configurations across all Jenkins jobs as part of a Nexus 3 migration. It enables bulk updates to Maven Release build goals and adds a Managed Script post-build step to all qualifying jobs, with support for a safe dry-run mode.

## What It Does

For every Jenkins job that uses the **M2 Release Build Wrapper** (excluding configured folders):

1. **Updates Maven Release goals** — replaces the existing goals/options with the configured value and enables **Nexus 3 upload**.
2. **Adds/verifies a Managed Script post-build step** — ensures the specified managed script is present as a post-build step and is set to run only when the build succeeds.

## Configuration

Edit the variables at the top of the script before running:

| Variable | Default | Description |
|---|---|---|
| `dryRun` | `true` | When `true`, logs planned changes without applying them. Set to `false` to apply changes. |
| `excludedFolder` | `"iam-cloud"` | Jobs under this top-level folder are skipped. |
| `newGoals` | *(see script)* | The Maven Release goals and options to set on all matching jobs. |
| `managedScriptName` | `"XYZ"` | The name of the Managed Script to add/verify as a post-build step. |

## Usage

1. Open the Jenkins **Script Console** (`Manage Jenkins → Script Console`).
2. Paste the contents of `updateBuilds.groovy`.
3. Adjust the configuration variables at the top as needed.
4. Run with `dryRun = true` first to review the planned changes in the output log.
5. Set `dryRun = false` and run again to apply the changes.

## Output

The script logs each job it processes with status indicators:

| Symbol | Meaning |
|---|---|
| 🚫 | Job skipped (excluded folder). |
| 🔍 | Job is being checked. |
| 🛠️ | Maven Release configuration is being updated. |
| ✅ | Configuration already up to date; no change needed. |
| ➕ | Managed Script post-build step is being added. |
| 🔁 | Managed Script run condition is being updated. |
| 📝 | Changes would be saved (dry-run mode). |
| 💾 | Changes saved. |
| 🔸 | No changes needed for this job. |

## Prerequisites

The following Jenkins plugins must be installed:

- [M2 Release Plugin](https://plugins.jenkins.io/m2release/) — provides `M2ReleaseBuildWrapper`.
- [Managed Script Plugin](https://plugins.jenkins.io/managed-scripts/) — provides `ManagedScript`.

## Notes

- Only **Freestyle/Maven project** jobs (`hudson.model.Project`) are processed. Pipeline jobs are not affected.
- Jobs without an M2 Release Build Wrapper are silently skipped.
- Changes are only persisted to disk when `dryRun = false` and `job.save()` is called.
