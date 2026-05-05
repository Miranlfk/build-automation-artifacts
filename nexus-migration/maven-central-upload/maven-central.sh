#!/usr/bin/env bash
# -------------------------------------------------------------------------------------
# Upload Maven artifacts to Maven Central via Publisher API (central.sonatype.com)
# Builds a bundle ZIP (Maven repo layout), ensures .asc signatures & checksums,
# uploads, then tracks status (and optionally publishes).
#
# Implementation follows the Central Publisher API documentation:
# https://central.sonatype.org/publish/publish-portal-api/
#
# Usage with Jenkins:
# 1. Configure Maven Central credentials in Jenkins (username/password credential)
#    Note: Use User Tokens from https://central.sonatype.com/account instead of regular passwords
# 2. In your Jenkins job configuration, use the Credentials Binding plugin to bind 
#    the credential to CENTRAL_CREDS_USR and CENTRAL_CREDS_PSW environment variables
# 3. Add this script as a post-build step in your Jenkins job
#
# GPG Signing Options:
# - GPG_KEYID: (Optional) Set to the ID of your GPG key for signing artifacts
#   Example: GPG_KEYID=ABC123DEF456
# - SKIP_SIGNATURES: Set to 'true' to skip GPG signing entirely (default: 'false')
# - If no GPG keys are found, signatures will be automatically skipped
#
# Auto-Publishing Behavior:
# - When CLOSE_NEXUS_STAGE=true (set by M2Release when deploying to releases), 
#   artifacts will be automatically published to Maven Central
# - Otherwise, manual publishing is required or can be enabled by setting CENTRAL_AUTO_PUBLISH=true
#
# Configuration Environment Variables:
# - GPG_KEYID             : ID of the GPG key to use for signing artifacts (optional)
# - SKIP_SIGNATURES       : Set to 'true' to skip GPG signing entirely (default: 'false')
# - SKIP_CHECKSUMS        : Set to 'true' to skip checksum generation (default: 'false')
# - CENTRAL_AUTO_PUBLISH  : Set to 'true' to publish automatically (default: follows CLOSE_NEXUS_STAGE)
# - CENTRAL_USERNAME      : Username for Maven Central (if not using Jenkins credentials)
# - CENTRAL_PASSWORD      : Password/token for Maven Central (if not using Jenkins credentials)
# - CENTRAL_API_BASE      : Base URL for Central API (default: https://central.sonatype.com)
# - CENTRAL_PUBLISHING_TYPE: "USER_MANAGED" or "AUTOMATIC" (default: "USER_MANAGED")
# - CENTRAL_DEPLOYMENT_NAME: Name for the deployment (default: "groupId:artifactId:version")
#
# Docs:
# - Auth & endpoints: https://central.sonatype.org/publish/publish-portal-api/
# - Bundle format:    https://central.sonatype.org/publish/publish-portal-upload/
# - GPG requirement:  https://central.sonatype.org/publish/requirements/gpg/
# -------------------------------------------------------------------------------------

set -euo pipefail

# ---------- Logging ----------
log_info()  { echo -e "\033[1;32m[Central Publish]\033[0m $*"; }
log_warn()  { echo -e "\033[1;33m[WARNING]\033[0m $*"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }


# ---------- Guards ----------
if [[ "${IS_M2RELEASEBUILD:-false}" != "true" ]]; then
  log_info "Not an M2 release build. Exiting."
  exit 0
fi

# Check GPG availability
if ! command -v gpg &>/dev/null; then
  log_warn "GPG not found in PATH. Signatures will be disabled."
  SKIP_SIGNATURES=true
else
  # Check for available secret keys
  if ! gpg --list-secret-keys 2>/dev/null | grep -q "sec"; then
    log_warn "No GPG secret keys found. Signatures will be disabled."
    log_warn "To create a GPG key: gpg --gen-key"
    log_warn "Or import an existing key: gpg --import your-private-key.asc"
    log_warn "Then set GPG_KEYID=<your-key-id> before running this script"
    SKIP_SIGNATURES=true
  elif [[ -n "$GPG_KEYID" ]]; then
    # Check if the specified GPG key exists
    if ! gpg --list-secret-keys "$GPG_KEYID" &>/dev/null; then
      log_warn "Specified GPG key $GPG_KEYID not found. Available keys:"
      gpg --list-secret-keys --keyid-format=long | grep -A1 "^sec" || true
      log_warn "Continuing with default key selection"
    fi
  fi
fi

MVN_RELEASE_VERSION=${MVN_RELEASE_VERSION:-}
if [[ -z "$MVN_RELEASE_VERSION" ]]; then
  log_error "MVN_RELEASE_VERSION is required."
  exit 1
fi

WORKSPACE_DIR="$(pwd)"
log_info "Workspace: $WORKSPACE_DIR"
ARTIFACT_ID=${ARTIFACT_ID:-${M2RELEASE_ARTIFACT_ID:-$(grep -m1 "<artifactId>" pom.xml 2>/dev/null | sed -e 's/.*<artifactId>\(.*\)<\/artifactId>.*/\1/' || mvn help:evaluate -Dexpression=project.artifactId -q -DforceStdout)}}
GROUP_ID="com.wso2.test"
# Check if we have Jenkins-specific artifact information
JENKINS_ARTIFACT=${JENKINS_ARTIFACT:-}
if [[ -n "$JENKINS_ARTIFACT" ]]; then
    log_info "Using Jenkins-provided artifact information: $JENKINS_ARTIFACT"
    # Expected format: groupId:artifactId
    IFS=':' read -ra ARTIFACT_PARTS <<< "$JENKINS_ARTIFACT"
    if [[ ${#ARTIFACT_PARTS[@]} -ge 2 ]]; then
        # Override artifactId but keep our hardcoded groupId
        ARTIFACT_ID=${ARTIFACT_PARTS[1]}
        # Force the groupId to be the hardcoded value
        JENKINS_ARTIFACT="${GROUP_ID}:${ARTIFACT_ID}"
        log_info "Enforcing hardcoded Group ID: ${GROUP_ID}"
    fi
fi

# Log discovery information
log_info "Discovered artifact: ${GROUP_ID}:${ARTIFACT_ID}:${MVN_RELEASE_VERSION}"

# Log GPG configuration status
if [[ "$SKIP_SIGNATURES" == "true" ]]; then
  log_warn "GPG signatures are disabled (SKIP_SIGNATURES=true)"
else
  if [[ -n "$GPG_KEYID" ]]; then
    log_info "Using GPG key ID: $GPG_KEYID for signing"
  else
    log_info "Using default GPG key for signing"
  fi
fi

# ---------- Central API ----------
CENTRAL_API_BASE=${CENTRAL_API_BASE:-"https://central.sonatype.com"}
UPLOAD_EP="$CENTRAL_API_BASE/api/v1/publisher/upload"
STATUS_EP="$CENTRAL_API_BASE/api/v1/publisher/status"
DEPLOY_EP="$CENTRAL_API_BASE/api/v1/publisher/deployment" # /<id>

# Look for credentials from Jenkins
CENTRAL_CREDENTIALS_ID=${CENTRAL_CREDENTIALS_ID:-"maven-central-credentials"}
CENTRAL_USERNAME="DxJ5s0"
CENTRAL_PASSWORD="l212TjXjF0xeekkx78lGD10PdoPNEV92Y"

# If credentials are not directly set as environment variables, try to get them from Jenkins
if [[ -z "$CENTRAL_USERNAME" || -z "$CENTRAL_PASSWORD" ]]; then
  if [[ -n "${JENKINS_HOME:-}" ]]; then
    log_info "Attempting to retrieve credentials from Jenkins credential store..."
    
    # Check if we have access to the credentials through environment variables set by Jenkins Credentials Binding Plugin
    if [[ -n "${CENTRAL_CREDS_USR:-}" && -n "${CENTRAL_CREDS_PSW:-}" ]]; then
      log_info "Using credentials bound by Jenkins Credentials Binding Plugin"
      CENTRAL_USERNAME=$CENTRAL_CREDS_USR
      CENTRAL_PASSWORD=$CENTRAL_CREDS_PSW
    fi
  fi
  
  # Final check if we have the credentials
  if [[ -z "$CENTRAL_USERNAME" || -z "$CENTRAL_PASSWORD" ]]; then
    log_error "Maven Central credentials not found. Please configure CENTRAL_CREDENTIALS_ID in Jenkins or provide CENTRAL_USERNAME and CENTRAL_PASSWORD directly."
    log_info "Note: As per latest documentation, it's recommended to use User Tokens from https://central.sonatype.com/account"
    exit 1
  fi
fi

# Create the Bearer token for authentication according to the official documentation
# See https://central.sonatype.org/publish/publish-portal-api/#authentication-authorization
AUTH_BEARER=$(printf "%s:%s" "$CENTRAL_USERNAME" "$CENTRAL_PASSWORD" | base64)
AUTH_HEADER="Authorization: Bearer $AUTH_BEARER"

CENTRAL_PUBLISHING_TYPE=${CENTRAL_PUBLISHING_TYPE:-"USER_MANAGED"} # or AUTOMATIC
CENTRAL_DEPLOYMENT_NAME=${CENTRAL_DEPLOYMENT_NAME:-"${GROUP_ID}:${ARTIFACT_ID}:${MVN_RELEASE_VERSION}"}

# Check if we should auto-publish based on CLOSE_NEXUS_STAGE (set by M2Release plugin)
IS_CLOSED=${CLOSE_NEXUS_STAGE:-false}
if [[ "$IS_CLOSED" == "true" ]]; then
    log_info "Artifact is being deployed to releases (CLOSE_NEXUS_STAGE=$IS_CLOSED)"
    # Auto-publish when going to releases
    CENTRAL_AUTO_PUBLISH=true
    log_info "Auto-publishing to Maven Central enabled"
else
    CENTRAL_AUTO_PUBLISH=${CENTRAL_AUTO_PUBLISH:-false}
    log_info "Auto-publishing determined by CENTRAL_AUTO_PUBLISH=$CENTRAL_AUTO_PUBLISH"
fi

GPG_KEYID=ABC123DEF456
SKIP_SIGNATURES=${SKIP_SIGNATURES:-false}
SKIP_CHECKSUMS=${SKIP_CHECKSUMS:-false}

# ---------- Helpers ----------
# Discover modules (artifactIds) via pom.xml files
discover_modules() {
  local modules=()
  [[ -n "$ARTIFACT_ID" ]] && modules+=("$ARTIFACT_ID")
  while IFS= read -r pom; do
    [[ "$pom" == "$WORKSPACE_DIR/pom.xml" ]] && continue
    local aid
    aid=$(grep -m1 "<artifactId>" "$pom" 2>/dev/null | sed -e 's/.*<artifactId>\(.*\)<\/artifactId>.*/\1/' || true)
    [[ -n "$aid" ]] && modules+=("$aid")
  done < <(find "$WORKSPACE_DIR" -name pom.xml -type f 2>/dev/null)
  printf "%s\n" "${modules[@]}" | awk 'NF' | sort -u
}

# Attempt to get a module's groupId (fallback to parent GROUP_ID)
module_group_id() {
  local module="$1"
  local pom
  while IFS= read -r p; do
    if grep -q "<artifactId>$module</artifactId>" "$p" 2>/dev/null; then pom="$p"; break; fi
  done < <(find "$WORKSPACE_DIR" -name pom.xml -type f 2>/dev/null)
  if [[ -n "${pom:-}" ]]; then
    local gid
    gid=$(grep -m1 "<groupId>" "$pom" 2>/dev/null | sed -e 's/.*<groupId>\(.*\)<\/groupId>.*/\1/' || true)
    [[ -n "$gid" ]] && { echo "$gid"; return; }
  fi
  echo "$GROUP_ID"
}

# Find candidate target dirs for given module
find_module_targets() {
  local module="$1"
  # direct target dirs named after module path
  while IFS= read -r t; do
    [[ -d "$t" ]] || continue
    local parent; parent="$(basename "$(dirname "$t")")"
    if [[ "$parent" == "$module" ]]; then echo "$t"; fi
  done < <(find "$WORKSPACE_DIR" -type d -path "*/target" -not -path "*/target/*" 2>/dev/null)

  # fallback: any target containing files that look like this module
  local pat1="$module*.jar"
  while IFS= read -r t; do
    if find "$t" -maxdepth 1 -type f \( -name "$pat1" -o -name "$module.pom" -o -name "$module-${MVN_RELEASE_VERSION}.pom" \) | grep -q .; then
      echo "$t"
    fi
  done < <(find "$WORKSPACE_DIR" -type d -path "*/target" -not -path "*/target/*" 2>/dev/null)

  # also check local repo cache if present
  local gid; gid=$(module_group_id "$module")
  if [[ -n "$gid" ]]; then
    local gpath; gpath=$(tr '.' '/' <<<"$gid")
    local repo_dir="$WORKSPACE_DIR/.repository/$gpath/$module/$MVN_RELEASE_VERSION"
    [[ -d "$repo_dir" ]] && echo "$repo_dir"
  fi
}

# Collect files for a module (pom, jar, sources, javadoc, war)
collect_artifacts() {
  local dir="$1"
  find "$dir" -type f \( -name "*.pom" -o -name "pom.xml" -o -name "*.jar" -o -name "*.war" \) \
    -maxdepth 2 2>/dev/null || true
}

# Ensure signature and checksums exist for a file
ensure_sig_and_checksums() {
  local f="$1"
  
  # Handle GPG signatures
  if [[ ! -f "${f}.asc" && "$SKIP_SIGNATURES" != "true" ]]; then
    # Check if gpg is available
    if ! command -v gpg &>/dev/null; then
      log_warn "GPG not found in PATH. Skipping signature for $(basename "$f")."
    elif [[ -n "$GPG_KEYID" ]]; then
      if gpg --batch --yes --local-user "$GPG_KEYID" -ab "$f" 2>/dev/null; then
        log_info "Signed: $(basename "$f").asc"
      else
        log_warn "GPG signing failed for $(basename "$f") with key $GPG_KEYID. Continuing without signature."
      fi
    else
      if gpg --batch --yes -ab "$f" 2>/dev/null; then
        log_info "Signed: $(basename "$f").asc"
      else
        log_warn "GPG signing failed for $(basename "$f"). No default secret key available. Continuing without signature."
      fi
    fi
  fi
  
  # Generate checksums
  if [[ "$SKIP_CHECKSUMS" != "true" ]]; then
    for algo in sha1 md5; do
      local out="${f}.${algo}"
      [[ -f "$out" ]] || { openssl dgst -$algo -r "$f" | awk '{print $1}' > "$out"; log_info "Checksum: $(basename "$out")"; }
    done
  fi
}

# Stage a single module into a Maven-layout bundle dir
stage_module_into_bundle() {
  local module="$1" bundle_root="$2"
  local gid; gid=$(module_group_id "$module")
  if [[ -z "$gid" ]]; then log_warn "No groupId for $module; skipping."; return; fi

  local gpath; gpath=$(tr '.' '/' <<<"$gid")
  local outdir="$bundle_root/$gpath/$module/$MVN_RELEASE_VERSION"
  mkdir -p "$outdir"

  # gather candidate dirs
  local targets=()
  while IFS= read -r t; do targets+=("$t"); done < <(find_module_targets "$module" | awk 'NF' | sort -u)

  if [[ ${#targets[@]} -eq 0 ]]; then
    log_warn "No artifact directories found for module $module"
    return
  fi

  # pick files
  local files=()
  for t in "${targets[@]}"; do
    while IFS= read -r f; do files+=("$f"); done < <(collect_artifacts "$t")
  done

  # Deduplicate by basename (prefer non-classes jars over sources/javadoc order handled by names)
  mapfile -t files < <(printf "%s\n" "${files[@]}" | awk 'NF' | awk '!seen[$0]++')

  # Normalize pom.xml name to <artifactId>-<version>.pom when needed
  for f in "${files[@]}"; do
    local base; base="$(basename "$f")"
    # Only accept files for this module and version
    if [[ "$base" == "pom.xml" ]]; then
      cp -f "$f" "$outdir/${module}-${MVN_RELEASE_VERSION}.pom"
      ensure_sig_and_checksums "$outdir/${module}-${MVN_RELEASE_VERSION}.pom"
    elif [[ "$base" == "${module}-${MVN_RELEASE_VERSION}.pom" || "$base" == "${module}.pom" ]]; then
      cp -f "$f" "$outdir/${module}-${MVN_RELEASE_VERSION}.pom"
      ensure_sig_and_checksums "$outdir/${module}-${MVN_RELEASE_VERSION}.pom"
    elif [[ "$base" =~ ^${module}-${MVN_RELEASE_VERSION}(-[A-Za-z0-9._-]+)?\.(jar|war)$ ]]; then
      cp -f "$f" "$outdir/$base"
      ensure_sig_and_checksums "$outdir/$base"
    elif [[ "$base" =~ ^${module}(-sources|-javadoc)\.jar$ ]]; then
      # Some builds put classifier jars without version in some dirs
      local classifier="${base#${module}-}"    # e.g. sources.jar
      cp -f "$f" "$outdir/${module}-${MVN_RELEASE_VERSION}-${classifier}"
      ensure_sig_and_checksums "$outdir/${module}-${MVN_RELEASE_VERSION}-${classifier}"
    fi
  done

  # sanity: require pom & at least one primary artifact
  if [[ ! -f "$outdir/${module}-${MVN_RELEASE_VERSION}.pom" ]]; then
    log_warn "Missing POM for $module:$MVN_RELEASE_VERSION; module will be skipped from bundle."
    rm -rf "$outdir"
  fi
}

# Poll deployment status
poll_status() {
  local dep_id="$1" attempt=0 max_attempts=60
  while (( attempt < max_attempts )); do
    ((attempt++))
    local resp
    # Uses the status verification endpoint from the documentation:
    # https://central.sonatype.org/publish/publish-portal-api/#verify-status-of-the-deployment
    resp=$(curl -sS -X POST -H "$AUTH_HEADER" "$STATUS_EP?id=$dep_id" || true)
    local state
    state=$(jq -r '.deploymentState // empty' <<<"$resp" 2>/dev/null || true)
    [[ -n "$state" ]] || { log_warn "No state yet (try $attempt)."; sleep 5; continue; }
    log_info "Deployment $dep_id state: $state"
    # Handle all possible state values defined in the documentation
    case "$state" in
      PUBLISHED) return 0 ;;
      FAILED)    
        # Show more detailed error info if available
        local errors
        errors=$(jq -r '.errors[]?.message // empty' <<<"$resp" 2>/dev/null || true)
        if [[ -n "$errors" ]]; then
          log_error "Deployment failed with errors:"
          echo "$errors" >&2
        else
          echo "$resp" >&2
        fi
        return 2 
        ;;
      VALIDATED|VALIDATING|PUBLISHING|PENDING) sleep 5 ;;
      *) sleep 5 ;;
    esac
  done
  return 3
}

# ---------- Build bundle ----------
BUNDLE_DIR="$(mktemp -d)"
BUNDLE_NAME="central-bundle-${ARTIFACT_ID:-project}-${MVN_RELEASE_VERSION}.zip"
BUNDLE_PATH="$WORKSPACE_DIR/${BUNDLE_NAME}"

log_info "Discovering modules…"
MODULES=$(discover_modules)
if [[ -z "$MODULES" ]]; then
  log_error "No modules found."
  exit 1
fi
printf "%s\n" "$MODULES" | sed 's/^/  • /'

log_info "Staging artifacts into bundle structure…"
while IFS= read -r module; do
  [[ -n "$module" ]] || continue
  stage_module_into_bundle "$module" "$BUNDLE_DIR"
done <<< "$MODULES"

# ensure we have at least one component
if ! find "$BUNDLE_DIR" -type f | grep -q .; then
  log_error "No staged artifacts; nothing to upload."
  exit 1
fi

# create zip
( cd "$BUNDLE_DIR" && zip -q -r "$BUNDLE_PATH" . )
log_info "Bundle created: $BUNDLE_PATH"

# ---------- Upload ----------
log_info "Uploading bundle to Central Publisher API…"
# Construct upload URL according to https://central.sonatype.org/publish/publish-portal-api/#uploading-a-deployment-bundle
# Make sure the deployment name is available to Python by exporting it
export CENTRAL_DEPLOYMENT_NAME
UPLOAD_URL="$UPLOAD_EP?name=$(python3 - <<PY
import urllib.parse,os
deployment_name = os.environ.get("CENTRAL_DEPLOYMENT_NAME", "${CENTRAL_DEPLOYMENT_NAME}")
print(urllib.parse.quote(deployment_name))
PY
)&publishingType=$CENTRAL_PUBLISHING_TYPE"

# Execute the upload request using the format specified in the documentation
HTTP_CODE=$(curl -sS -w "%{http_code}" -o /tmp/central_upload_resp.txt \
  -H "$AUTH_HEADER" \
  -F "bundle=@${BUNDLE_PATH};type=application/octet-stream" \
  "$UPLOAD_URL")

if [[ "$HTTP_CODE" != "201" && "$HTTP_CODE" != "200" ]]; then
  log_error "Upload failed (HTTP $HTTP_CODE)"
  log_error "Response: $(cat /tmp/central_upload_resp.txt)"
  exit 1
fi

DEPLOYMENT_ID=$(tr -d '\n\r ' < /tmp/central_upload_resp.txt)
log_info "Deployment ID: $DEPLOYMENT_ID"

# ---------- If USER_MANAGED, wait for VALIDATED then (optionally) publish ----------
if [[ "$CENTRAL_PUBLISHING_TYPE" == "USER_MANAGED" ]]; then
  log_info "Polling for VALIDATED state (USER_MANAGED)…"
  poll_status "$DEPLOYMENT_ID" || true
  
  # Auto-publish if configured
  if [[ "$CENTRAL_AUTO_PUBLISH" == "true" ]]; then
    if [[ "$IS_CLOSED" == "true" ]]; then
      log_info "Publishing deployment $DEPLOYMENT_ID automatically (reason: deploying to releases)…"
    else
      log_info "Publishing deployment $DEPLOYMENT_ID automatically (reason: CENTRAL_AUTO_PUBLISH=true)…"
    fi
    
    # Uses the publish endpoint from the documentation:
    # https://central.sonatype.org/publish/publish-portal-api/#publish-or-drop-the-deployment
    log_info "Requesting deployment publication to Maven Central..."
    publish_response=$(curl -sS -X POST -H "$AUTH_HEADER" "$DEPLOY_EP/$DEPLOYMENT_ID" -o /dev/null -w "%{http_code}\n")
    if [[ "$publish_response" == "200" || "$publish_response" == "201" || "$publish_response" == "204" ]]; then
      log_info "Publish request accepted. Polling for PUBLISHED state..."
      poll_status "$DEPLOYMENT_ID" || true
    else
      log_warn "Publish request returned unexpected HTTP code: $publish_response"
    fi
  else
    if [[ "$IS_CLOSED" == "false" ]]; then
      log_info "Auto-publish disabled (reason: not deploying to releases, CLOSE_NEXUS_STAGE=$IS_CLOSED)"
    else
      log_info "Auto-publish disabled (reason: CENTRAL_AUTO_PUBLISH=$CENTRAL_AUTO_PUBLISH)"
    fi
    log_info "Deployment is ready for manual publishing at Sonatype Central."
    log_info "Visit: https://central.sonatype.com/publishing/deployments"
  fi
else
  log_info "AUTOMATIC mode — polling until PUBLISHED…"
  poll_status "$DEPLOYMENT_ID" || true
fi

# Create a status file that Jenkins can read
if [[ -n "${JENKINS_HOME:-}" ]]; then
  STATUS_FILE="$WORKSPACE_DIR/central-upload-status.txt"
  echo "DEPLOYMENT_ID=$DEPLOYMENT_ID" > "$STATUS_FILE"
  echo "DEPLOYMENT_NAME=$CENTRAL_DEPLOYMENT_NAME" >> "$STATUS_FILE"
  echo "DEPLOYMENT_STATE=$state" >> "$STATUS_FILE"
  echo "BUNDLE_PATH=$BUNDLE_PATH" >> "$STATUS_FILE"
  # Add artifact coordinates for better traceability
  echo "GROUP_ID=$GROUP_ID" >> "$STATUS_FILE"
  echo "ARTIFACT_ID=$ARTIFACT_ID" >> "$STATUS_FILE"
  echo "VERSION=$MVN_RELEASE_VERSION" >> "$STATUS_FILE"
  # Add links to Central Portal for easier access
  echo "CENTRAL_PORTAL_URL=https://central.sonatype.com/publishing/deployments" >> "$STATUS_FILE"
  log_info "Status file created at $STATUS_FILE"
  
  # Export variables for Jenkins to use if needed
  export MAVEN_CENTRAL_DEPLOYMENT_ID="$DEPLOYMENT_ID"
  export MAVEN_CENTRAL_DEPLOYMENT_NAME="$CENTRAL_DEPLOYMENT_NAME"
  export MAVEN_CENTRAL_DEPLOYMENT_STATE="$state"
  export MAVEN_CENTRAL_GROUP_ID="$GROUP_ID"
  export MAVEN_CENTRAL_ARTIFACT_ID="$ARTIFACT_ID"
  export MAVEN_CENTRAL_VERSION="$MVN_RELEASE_VERSION"
fi

if [[ "${state:-}" == "PUBLISHED" || "${state:-}" == "VALIDATED" ]]; then
  if [[ "${state:-}" == "PUBLISHED" ]]; then
    log_info "Upload to Maven Central successful and published: $CENTRAL_DEPLOYMENT_NAME (ID: $DEPLOYMENT_ID)"
    log_info "Your artifact should be available soon at: https://repo1.maven.org/maven2/${GROUP_ID//./\/}/${ARTIFACT_ID}/${MVN_RELEASE_VERSION}/"
  else
    log_info "Upload to Maven Central successful (validated but not yet published): $CENTRAL_DEPLOYMENT_NAME (ID: $DEPLOYMENT_ID)"
    log_info "Visit https://central.sonatype.com/publishing/deployments to manage your deployment"
  fi
  log_info "Done."
  exit 0
else
  log_warn "Upload completed but final state was not PUBLISHED or VALIDATED: ${state:-unknown}"
  log_info "You can check the status at: https://central.sonatype.com/publishing/deployments"
  log_info "Done with warnings."
  # Exit with success to not fail the build, as the upload did complete
  # Change to exit 1 if you want to fail the build when not fully published
  exit 0
fi
