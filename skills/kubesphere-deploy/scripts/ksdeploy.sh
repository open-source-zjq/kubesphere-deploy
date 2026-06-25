#!/usr/bin/env bash
#
# ksdeploy.sh — Generic KubeSphere DevOps pipeline CLI
#
# Authenticates against a KubeSphere cluster and triggers / monitors DevOps
# pipeline runs over the public kapis REST API. Version-tolerant across
# KubeSphere 3.x and 4.x (LuBan).
#
# Configuration comes from environment variables, optionally loaded from a
# `kubesphere.env` file (see kubesphere.env.example). Nothing in this script
# ever prints a token, password or the `encrypt` blob to stdout/stderr.
#
# Usage:
#   ksdeploy.sh <command> [args]
#
# Commands:
#   auth                              Verify credentials work (prints OK, never the token)
#   workspaces                       List workspace names
#   devops [workspace]               List DevOps projects (name + generateName) in a workspace
#   resolve-devops [ws] [generate]   Print the real DevOps project name (metadata.name)
#   pipelines <devops>               List pipelines in a DevOps project
#   params <devops> <pipeline>       Show a pipeline's parameter template
#   runs <devops> <pipeline> [--branch=<b>]        List recent runs of a pipeline
#   run [pipeline] [flags]           Trigger a pipeline run (see below)
#   status <devops> <run>            Show a pipeline run's status
#   logs <devops> <pipeline> <run> [--branch=<b>]  Print a run's console log
#   help                             Show this help
#
# `run` flags (all optional):
#   --workspace=<name>               Override KS_WORKSPACE
#   --devops=<name>                  Use this exact DevOps project name (skip resolution)
#   --devops-generate-name=<name>    Resolve DevOps project by generateName
#   --branch=<name>                  Multi-branch pipeline branch
#   --<PARAM>=<value>                Override any pipeline parameter (e.g. --POD_COUNT=2)
#   --yes                            Actually submit (without it, prints the payload only)
#   --dry-run                        Force preview even if KS_ASSUME_YES is set
#
# Exit code is non-zero on any error.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AUTH_MODE=""
TOKEN=""
JAR=""
# Temp file used to surface the last HTTP status code across the subshells that
# command substitution / pipelines create (a plain variable would be lost).
KS_CODE_FILE=""

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

die() { printf 'ksdeploy: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }

# URL-encode a string (for branch names etc. that may contain '/', '&', '#').
urlencode() { printf '%s' "${1:-}" | jq -sRr @uri; }

usage() {
  awk 'NR>2 && /^#/{sub(/^# ?/,""); print; next} NR>2{exit}' "${BASH_SOURCE[0]}"
}

# Read the HTTP status of the most recent ks_request (works across subshells).
last_code() {
  local c=""
  [ -n "$KS_CODE_FILE" ] && c=$(cat "$KS_CODE_FILE" 2>/dev/null)
  printf '%s' "${c:-0}"
}

cleanup() {
  [ -n "$JAR" ] && rm -f "$JAR" 2>/dev/null
  [ -n "$KS_CODE_FILE" ] && rm -f "$KS_CODE_FILE" 2>/dev/null
  return 0
}
trap cleanup EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1${2:+ ($2)}"
}

# Load configuration from a kubesphere.env file if one exists.
load_env() {
  local f="${KS_ENV_FILE:-}"
  if [ -z "$f" ]; then
    local cand
    for cand in "./kubesphere.env" "$SCRIPT_DIR/kubesphere.env" "$SCRIPT_DIR/../kubesphere.env"; do
      [ -f "$cand" ] && { f="$cand"; break; }
    done
  fi
  if [ -n "$f" ] && [ -f "$f" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$f"
    set +a
  fi
}

# ---------------------------------------------------------------------------
# auth
# ---------------------------------------------------------------------------

# Cache path is keyed by URL + username + auth method, so switching credential
# methods (or rotating creds) never reuses a token cached for another method.
cache_file() {
  local dir="${KS_CACHE_DIR:-${TMPDIR:-/tmp}}"
  local key
  key=$(printf '%s|%s|%s' "${KS_URL:-}" "${KS_USERNAME:-}" "${1:-}" | cksum | awk '{print $1}')
  printf '%s/ksdeploy-%s.token' "${dir%/}" "$key"
}

load_cached_token() {
  [ -z "${KS_NO_CACHE:-}" ] || return 1
  local f exp tok
  f=$(cache_file "${1:-}"); [ -f "$f" ] || return 1
  exp=$(sed -n '1p' "$f"); tok=$(sed -n '2p' "$f")
  [ -n "$tok" ] || return 1
  [ "$(date +%s)" -lt "${exp:-0}" ] 2>/dev/null || return 1
  TOKEN=$tok
  return 0
}

save_cached_token() {
  [ -z "${KS_NO_CACHE:-}" ] || return 0
  local mode=$1 tok=$2 ttl=${3:-0} f
  case "$ttl" in ''|*[!0-9]*) ttl=1800 ;; esac
  [ "$ttl" -gt 0 ] || ttl=1800
  f=$(cache_file "$mode")
  ( umask 077; printf '%s\n%s\n' "$(( $(date +%s) + ttl - 60 ))" "$tok" > "$f" ) 2>/dev/null || true
}

# Drop the cached bearer token (e.g. after a 401) so the next run re-authenticates.
invalidate_cached_token() {
  rm -f "$(cache_file password)" 2>/dev/null || true
}

# Acquire credentials, in priority order:
#   1. KS_TOKEN                       bearer token (best for CI / service accounts)
#   2. KS_USERNAME + KS_PASSWORD      OAuth2 password grant -> bearer token
#   3. KS_USERNAME + KS_ENCRYPT       console /login cookie flow (legacy fallback)
acquire_auth() {
  [ -n "$AUTH_MODE" ] && return 0
  [ -n "${KS_URL:-}" ] || die "KS_URL is not set (e.g. https://kubesphere.example.com)"

  if [ -n "${KS_TOKEN:-}" ]; then
    AUTH_MODE=bearer; TOKEN=$KS_TOKEN; return 0
  fi

  if [ -n "${KS_USERNAME:-}" ] && [ -n "${KS_PASSWORD:-}" ]; then
    if load_cached_token password; then AUTH_MODE=bearer; return 0; fi
    local resp
    resp=$(curl -sS ${KS_INSECURE:+-k} -X POST "${KS_URL%/}/oauth/token" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode 'grant_type=password' \
      --data-urlencode "username=${KS_USERNAME}" \
      --data-urlencode "password=${KS_PASSWORD}" \
      --data-urlencode "client_id=${KS_OAUTH_CLIENT_ID:-kubesphere}" \
      --data-urlencode "client_secret=${KS_OAUTH_CLIENT_SECRET:-kubesphere}") \
      || die "OAuth request to ${KS_URL%/}/oauth/token failed (network?)"
    TOKEN=$(printf '%s' "$resp" | jq -r '.access_token // empty')
    if [ -z "$TOKEN" ]; then
      local err
      err=$(printf '%s' "$resp" | jq -r '.error_description // .message // .error // "unknown error"' 2>/dev/null)
      die "OAuth login failed: ${err}. (Password grant requires a Trusted OAuth client; otherwise set KS_TOKEN.)"
    fi
    AUTH_MODE=bearer
    save_cached_token password "$TOKEN" "$(printf '%s' "$resp" | jq -r '.expires_in // 0')"
    return 0
  fi

  if [ -n "${KS_USERNAME:-}" ] && [ -n "${KS_ENCRYPT:-}" ]; then
    JAR=$(mktemp); chmod 600 "$JAR" 2>/dev/null || true
    curl -sS ${KS_INSECURE:+-k} -o /dev/null -c "$JAR" \
      -H 'Content-Type: application/json' \
      "${KS_URL%/}/login" \
      --data-raw "$(jq -n --arg u "$KS_USERNAME" --arg e "$KS_ENCRYPT" '{username:$u,encrypt:$e}')" \
      || die "console /login request failed (network?)"
    grep -q $'\ttoken\t' "$JAR" || die "console login failed: no token cookie returned"
    AUTH_MODE=cookie
    return 0
  fi

  die "no credentials found. Set KS_TOKEN, or KS_USERNAME+KS_PASSWORD, or KS_USERNAME+KS_ENCRYPT (see kubesphere.env.example)"
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

# ks_request METHOD PATH [DATA] [ACCEPT]
# Prints the response body to stdout and records the HTTP status (read it back
# with last_code, which survives subshells). Returns non-zero (without dying) on
# HTTP >= 400 so callers can inspect / fall back.
ks_request() {
  acquire_auth
  local method=$1 path=$2 data=${3:-} accept=${4:-application/json}
  local cluster_prefix=""
  [ -n "${KS_CLUSTER:-}" ] && cluster_prefix="/clusters/${KS_CLUSTER}"
  local url="${KS_URL%/}${cluster_prefix}${path}"

  local -a args=( -sS -X "$method" -H "Accept: ${accept}" )
  [ -n "${KS_INSECURE:-}" ] && args+=( -k )
  if [ "$AUTH_MODE" = bearer ]; then
    args+=( -H "Authorization: Bearer ${TOKEN}" )
  else
    args+=( -b "$JAR" )
  fi
  if [ -n "$data" ]; then
    args+=( -H 'Content-Type: application/json' -H "Origin: ${KS_URL%/}" --data-raw "$data" )
  fi

  local body_file code
  body_file=$(mktemp)
  # Reset first so a curl that dies leaves no stale code behind for last_code.
  [ -n "$KS_CODE_FILE" ] && printf '0' > "$KS_CODE_FILE"
  code=$(curl "${args[@]}" -o "$body_file" -w '%{http_code}' "$url") \
    || { rm -f "$body_file"; die "curl failed for ${method} ${path}"; }
  [ -n "$KS_CODE_FILE" ] && printf '%s' "$code" > "$KS_CODE_FILE"
  # A revoked/expired cached token surfaces as 401 — drop it so a re-run recovers.
  [ "$code" = 401 ] && invalidate_cached_token
  cat "$body_file"
  rm -f "$body_file"
  # Treat only 2xx/3xx as success; curl's "000" (no HTTP status) is a failure.
  [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 400 ] 2>/dev/null
}

# devops_request METHOD DEVOPS SUFFIX [DATA] [ACCEPT]
# Tries the v1alpha3 "/namespaces/<devops>/" path (KubeSphere 4.x and most 3.x),
# then falls back to "/devops/<devops>/" (older 3.x) on a 404.
devops_request() {
  local method=$1 devops=$2 suffix=$3 data=${4:-} accept=${5:-application/json}
  local base="/kapis/devops.kubesphere.io/v1alpha3"
  local resp
  if resp=$(ks_request "$method" "$base/namespaces/$devops/$suffix" "$data" "$accept"); then
    printf '%s' "$resp"; return 0
  fi
  # Older KubeSphere 3.x used /devops/<name>/ instead of /namespaces/<name>/.
  if [ "$(last_code)" = 404 ]; then
    ks_request "$method" "$base/devops/$devops/$suffix" "$data" "$accept"
    return
  fi
  printf '%s' "$resp"
  return 1
}

# ---------------------------------------------------------------------------
# resolution
# ---------------------------------------------------------------------------

list_workspaces_json() {
  ks_request GET "/kapis/tenant.kubesphere.io/v1alpha2/workspaces?sortBy=createTime&limit=200"
}

list_devops_json() {
  local ws=$1
  ks_request GET "/kapis/tenant.kubesphere.io/v1alpha2/workspaces/$ws/devops?sortBy=createTime&limit=200"
}

# resolve_devops WORKSPACE [GENERATE_NAME] [EXPLICIT_NAME]
resolve_devops() {
  local ws=$1 gen=${2:-} explicit=${3:-}
  if [ -n "$explicit" ]; then printf '%s' "$explicit"; return 0; fi
  [ -n "$ws" ] || die "workspace required to resolve DevOps project (set KS_WORKSPACE or pass --workspace)"
  local resp name=""
  resp=$(list_devops_json "$ws") || die "failed to list DevOps projects in workspace '$ws':"$'\n'"$resp"
  if [ -n "$gen" ]; then
    name=$(printf '%s' "$resp" | jq -r --arg g "$gen" '.items[]? | select(.metadata.generateName==$g) | .metadata.name' | head -n1)
    [ -n "$name" ] || name=$(printf '%s' "$resp" | jq -r --arg g "$gen" '.items[]? | select(.metadata.name==$g) | .metadata.name' | head -n1)
  fi
  if [ -z "$name" ]; then
    log "could not resolve DevOps project (workspace=$ws generateName=${gen:-<none>}). Available:"
    printf '%s' "$resp" | jq -r '.items[]? | "  name=\(.metadata.name)  generateName=\(.metadata.generateName // "-")"' >&2
    die "set KS_DEVOPS to one of the names above, or fix KS_DEVOPS_GENERATE_NAME"
  fi
  printf '%s' "$name"
}

# Fetch the parameter template for a pipeline -> JSON array. Dies if the pipeline
# does not exist (so a typo can't silently produce an empty/parameterless run).
pipeline_params_json() {
  local devops=$1 pipeline=$2 resp rc params match
  resp=$(devops_request GET "$devops" "pipelines/$pipeline"); rc=$?
  if [ "$rc" -eq 0 ]; then
    params=$(printf '%s' "$resp" | jq -c '.spec.pipeline.parameters // empty' 2>/dev/null)
    if [ -n "$params" ] && [ "$params" != "null" ]; then
      printf '%s' "$params"; return 0
    fi
    # Pipeline exists but the by-path response carried no parameters; some
    # versions only expose them via the list endpoint — try an exact-name match.
    resp=$(devops_request GET "$devops" "pipelines?limit=100&name=$pipeline") || resp=""
    match=$(printf '%s' "$resp" \
      | jq -c --arg n "$pipeline" '(.items // []) | map(select(.metadata.name == $n)) | .[0] // empty' 2>/dev/null)
    if [ -n "$match" ]; then
      printf '%s' "$match" | jq -c '.spec.pipeline.parameters // []'; return 0
    fi
    printf '[]'; return 0   # exists, genuinely no parameters
  fi
  # by-path lookup failed (404/auth/etc): require an exact-name match to prove it exists
  resp=$(devops_request GET "$devops" "pipelines?limit=100&name=$pipeline") \
    || die "failed to look up pipeline '$pipeline' in DevOps project '$devops':"$'\n'"$resp"
  match=$(printf '%s' "$resp" \
    | jq -c --arg n "$pipeline" '(.items // []) | map(select(.metadata.name == $n)) | .[0] // empty')
  [ -n "$match" ] || die "pipeline '$pipeline' not found in DevOps project '$devops'"
  printf '%s' "$match" | jq -c '.spec.pipeline.parameters // []'
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

cmd_auth() {
  acquire_auth
  printf 'OK: authenticated to %s (%s)\n' "${KS_URL%/}" "$AUTH_MODE"
}

cmd_workspaces() {
  list_workspaces_json | jq -r '.items[]?.metadata.name'
}

cmd_devops() {
  local ws=${1:-${KS_WORKSPACE:-}}
  [ -n "$ws" ] || die "usage: ksdeploy.sh devops <workspace>  (or set KS_WORKSPACE)"
  list_devops_json "$ws" | jq -r '.items[]? | "\(.metadata.name)\tgenerateName=\(.metadata.generateName // "-")"'
}

cmd_resolve_devops() {
  local ws=${1:-${KS_WORKSPACE:-}} gen=${2:-${KS_DEVOPS_GENERATE_NAME:-}}
  resolve_devops "$ws" "$gen" "${KS_DEVOPS:-}"
  printf '\n'
}

cmd_pipelines() {
  local devops=${1:-${KS_DEVOPS:-}}
  if [ -z "$devops" ]; then
    devops=$(resolve_devops "${KS_WORKSPACE:-}" "${KS_DEVOPS_GENERATE_NAME:-}" "${KS_DEVOPS:-}") || exit 1
  fi
  devops_request GET "$devops" "pipelines?limit=200" | jq -r '.items[]?.metadata.name'
}

cmd_params() {
  local devops=$1 pipeline=$2
  if [ -z "${devops:-}" ] || [ -z "${pipeline:-}" ]; then
    die "usage: ksdeploy.sh params <devops> <pipeline>"
  fi
  pipeline_params_json "$devops" "$pipeline" \
    | jq -r '.[] | "\(.name)\t[\(.type // "string")]\tdefault=\(.default_value // "")\t\(.description // "")"'
}

# Resolve the DevOps project for the monitoring commands: use --devops/positional
# if given, otherwise fall back to KS_DEVOPS / KS_DEVOPS_GENERATE_NAME like `run`.
resolve_devops_or_env() {
  local explicit=${1:-}
  if [ -n "$explicit" ]; then printf '%s' "$explicit"; return 0; fi
  resolve_devops "${KS_WORKSPACE:-}" "${KS_DEVOPS_GENERATE_NAME:-}" "${KS_DEVOPS:-}"
}

cmd_runs() {
  local devops="" branch="" a; local -a pos=()
  for a in "$@"; do
    case "$a" in
      --devops=*) devops="${a#*=}" ;;
      --branch=*) branch="${a#*=}" ;;
      --*)        die "unknown flag: $a" ;;
      *)          pos+=("$a") ;;
    esac
  done
  local pipeline=""
  case ${#pos[@]} in
    2) devops="${pos[0]}"; pipeline="${pos[1]}" ;;
    1) pipeline="${pos[0]}" ;;
    *) die "usage: ksdeploy.sh runs [<devops>] <pipeline> [--branch=<branch>]" ;;
  esac
  devops=$(resolve_devops_or_env "$devops") || exit 1
  local q="pipelines/$pipeline/pipelineruns?limit=20&backward=true"
  [ -n "$branch" ] && q="$q&branch=$(urlencode "$branch")"
  devops_request GET "$devops" "$q" \
    | jq -r '.items[]? | "\(.metadata.name)\t\(.status.state // "-")\t\(.status.result // "-")\t\(.metadata.creationTimestamp // "-")"'
}

cmd_status() {
  local devops="" a; local -a pos=()
  for a in "$@"; do
    case "$a" in
      --devops=*) devops="${a#*=}" ;;
      --*)        die "unknown flag: $a" ;;
      *)          pos+=("$a") ;;
    esac
  done
  local run=""
  case ${#pos[@]} in
    2) devops="${pos[0]}"; run="${pos[1]}" ;;
    1) run="${pos[0]}" ;;
    *) die "usage: ksdeploy.sh status [<devops>] <run>" ;;
  esac
  devops=$(resolve_devops_or_env "$devops") || exit 1
  devops_request GET "$devops" "pipelineruns/$run" \
    | jq '{name: .metadata.name, state: .status.state, result: .status.result, startTime: .status.startTime, completionTime: .status.completionTime}'
}

cmd_logs() {
  local devops="" branch="" a; local -a pos=()
  for a in "$@"; do
    case "$a" in
      --devops=*) devops="${a#*=}" ;;
      --branch=*) branch="${a#*=}" ;;
      --*)        die "unknown flag: $a" ;;
      *)          pos+=("$a") ;;
    esac
  done
  local pipeline="" run=""
  case ${#pos[@]} in
    3) devops="${pos[0]}"; pipeline="${pos[1]}"; run="${pos[2]}" ;;
    2) pipeline="${pos[0]}"; run="${pos[1]}" ;;
    *) die "usage: ksdeploy.sh logs [<devops>] <pipeline> <run> [--branch=<branch>]" ;;
  esac
  devops=$(resolve_devops_or_env "$devops") || exit 1
  # Logs only exist on the v1alpha2 path, even for v1alpha3 runs. Multi-branch
  # pipelines use a branch-scoped path.
  local base="/kapis/devops.kubesphere.io/v1alpha2/namespaces/$devops/pipelines/$pipeline"
  local path
  if [ -n "$branch" ]; then
    path="$base/branches/$(urlencode "$branch")/runs/$run/log?start=0"
  else
    path="$base/runs/$run/log?start=0"
  fi
  ks_request GET "$path" "" "text/plain"
}

cmd_run() {
  local pipeline="" workspace="${KS_WORKSPACE:-}" devops="${KS_DEVOPS:-}" \
        generate="${KS_DEVOPS_GENERATE_NAME:-}" branch="" assume_yes="${KS_ASSUME_YES:-}" dry_run=""
  local overrides='{}'
  local a key val
  for a in "$@"; do
    case "$a" in
      --workspace=*)             workspace="${a#*=}" ;;
      --devops=*)                devops="${a#*=}" ;;
      --devops-generate-name=*)  generate="${a#*=}" ;;
      --branch=*)                branch="${a#*=}" ;;
      --yes)                     assume_yes=1 ;;
      --dry-run)                 dry_run=1 ;;
      --*=*)
        key="${a%%=*}"; key="${key#--}"; val="${a#*=}"
        overrides=$(printf '%s' "$overrides" | jq -c --arg k "$key" --arg v "$val" '. + {($k): $v}')
        ;;
      --*) die "unknown flag: $a" ;;
      *)   pipeline="$a" ;;
    esac
  done
  [ -n "$pipeline" ] || pipeline="${KS_PIPELINE:-}"
  [ -n "$pipeline" ] || die "no pipeline given (pass a name or set KS_PIPELINE)"
  [ -n "$dry_run" ] && assume_yes=""

  if [ -z "$devops" ]; then
    devops=$(resolve_devops "$workspace" "$generate" "") || exit 1
  fi
  log "DevOps project: $devops"
  log "Pipeline:       $pipeline${branch:+ (branch: $branch)}"

  local template payload params
  template=$(pipeline_params_json "$devops" "$pipeline") || exit 1
  # Pick the first non-empty value per parameter. Using a candidate list (not
  # jq's `//`) keeps a legitimate boolean `false` or numeric `0` default instead
  # of treating it as absent.
  params=$(printf '%s' "$template" | jq -c \
    --argjson overrides "$overrides" \
    --arg appName "$pipeline" '
    def keep: select(. != null and . != "");
    map(
      .name as $n
      | { name: $n,
          value: ( [ $overrides[$n],
                     env["KS_PARAM_" + $n],
                     .default_value,
                     (if $n == "APP_NAME" then $appName else null end) ]
                   | map(keep) | .[0] ) }
    ) | map(select(.value != null and .value != ""))') \
    || die "failed to merge pipeline parameters"
  [ -n "$params" ] || die "failed to build pipeline parameters (empty result)"
  payload=$(jq -n --argjson p "$params" '{parameters: $p}') \
    || die "failed to build request payload"

  log "Payload:"
  printf '%s\n' "$payload" | jq . >&2

  if [ -z "$assume_yes" ]; then
    log ""
    log "Dry run — nothing submitted. Re-run with --yes to trigger the pipeline."
    return 0
  fi

  local suffix="pipelines/$pipeline/pipelineruns"
  [ -n "$branch" ] && suffix="$suffix?branch=$(urlencode "$branch")"
  local resp run_id
  resp=$(devops_request POST "$devops" "$suffix" "$payload") \
    || die "failed to trigger pipeline run (HTTP $(last_code)):"$'\n'"$resp"
  run_id=$(printf '%s' "$resp" | jq -r '.metadata.name // empty')
  [ -n "$run_id" ] || die "pipeline run submitted but no run id in response:"$'\n'"$resp"

  printf 'Triggered run: %s\n' "$run_id"
  printf 'Check status:  ksdeploy.sh status %s %s\n' "$devops" "$run_id"
  if [ -n "$workspace" ]; then
    printf 'Console URL:   %s/%s/clusters/%s/devops/%s/pipelines/%s\n' \
      "${KS_URL%/}" "$workspace" "${KS_CLUSTER:-default}" "$devops" "$pipeline"
  fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  require curl
  require jq "install with: brew install jq  |  apt-get install jq"
  load_env

  local cmd=${1:-help}
  if [ $# -gt 0 ]; then shift; fi

  case "$cmd" in
    help|-h|--help) usage; return 0 ;;
    "")             usage; return 0 ;;
  esac

  # Authenticate once in the parent shell so the auth state (and the cookie jar,
  # in console-login mode) is inherited by the subshells that ks_request runs in.
  KS_CODE_FILE=$(mktemp)
  acquire_auth

  case "$cmd" in
    auth)            cmd_auth "$@" ;;
    workspaces)      cmd_workspaces "$@" ;;
    devops)          cmd_devops "$@" ;;
    resolve-devops)  cmd_resolve_devops "$@" ;;
    pipelines)       cmd_pipelines "$@" ;;
    params)          cmd_params "${1:-}" "${2:-}" ;;
    runs)            cmd_runs "$@" ;;
    run)             cmd_run "$@" ;;
    status)          cmd_status "${1:-}" "${2:-}" ;;
    logs)            cmd_logs "$@" ;;
    *)               log "unknown command: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
