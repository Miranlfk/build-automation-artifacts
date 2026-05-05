# Nexus Repository Security Export/Import Script

This script exports and imports **Nexus Repository security objects** (content selectors, privileges, and roles) between Nexus instances using the Nexus REST API. It is useful for migrating security configurations when upgrading or moving Nexus instances.

Tested migration path: **Nexus Repository Pro 3.66.x → Nexus Repository Pro 3.82.x**

## Supported Objects

| Object | Description |
|---|---|
| **Content Selectors** | CSEL/JEXL expressions that define repository content subsets. |
| **Privileges** | Fine-grained permissions (repository-admin, repository-view, repository-content-selector, etc.). |
| **Roles** | Named sets of privileges and nested roles. |

## Requirements

- `bash`
- `curl`
- `jq`
- `python3`

## Usage

```bash
# Export security objects from a source Nexus instance
SOURCE_PASS='<password>' ./nexus-import-export.sh export \
  --url https://old-nexus.example.com \
  --user admin \
  --file nexus-security.json

# Import security objects into a target Nexus instance
TARGET_PASS='<password>' ./nexus-import-export.sh import \
  --url https://new-nexus.example.com \
  --user admin \
  --file nexus-security.json

# Dry run — preview what would be imported without making changes
TARGET_PASS='<password>' ./nexus-import-export.sh import \
  --url https://new-nexus.example.com \
  --user admin \
  --file nexus-security.json \
  --dry-run
```

## Options

| Option | Description |
|---|---|
| `--url URL` | **(Required)** Nexus base URL, e.g. `https://nexus.example.com`. |
| `--user USER` | **(Required)** Nexus admin username. |
| `--file FILE` | JSON file path. Default: `nexus-security.json`. |
| `--dry-run` | *(Import only)* Preview what would be imported without modifying Nexus. |
| `--overwrite` | *(Export only)* Overwrite the output file if it already exists. |
| `--insecure` | Skip TLS certificate verification. |

### Include/Exclude Object Types

| Option | Description |
|---|---|
| `--no-content-selectors` | Skip content selectors. |
| `--no-privileges` | Skip privileges. |
| `--no-roles` | Skip roles. |
| `--only-selectors` | Process content selectors only. |
| `--only-privileges` | Process privileges only. |
| `--only-roles` | Process roles only. |

## Password Environment Variables

| Variable | Used For |
|---|---|
| `NEXUS_PASS` | Either export or import. |
| `SOURCE_PASS` | Export only. |
| `TARGET_PASS` | Import only. |

If no password variable is set, the script will interactively prompt for the password.

## Export Format

The exported JSON file has the following structure:

```json
{
  "exportedAt": "2026-05-05T10:00:00Z",
  "sourceUrl": "https://old-nexus.example.com",
  "contentSelectors": [ ... ],
  "privileges": [ ... ],
  "roles": [ ... ]
}
```

## Import Behaviour

### Content Selectors
- Creates new selectors via POST.
- Updates existing selectors via PUT if a 409 conflict is returned.

### Privileges
- Built-in `nx-*` privileges: skipped if already present.
- Custom privileges: deleted first (if existing), then recreated fresh to ensure clean state.
- Privilege names are sanitised (special characters replaced with `-`) to meet Nexus naming rules.

### Roles
- Import is done in **two passes** to handle cross-referencing roles:
  1. **Pass 1** — creates all role shells with empty nested-role arrays.
  2. **Pass 2** — updates every role with its full payload including nested role references.
- Non-`nx-*` roles are deleted and recreated in Pass 1.

## Notes

- The import order is: **content selectors → privileges → roles**. This ensures that all referenced objects exist before dependent objects are created.
- The script exits with code `1` if any section encounters failures; partial successes are retained.
