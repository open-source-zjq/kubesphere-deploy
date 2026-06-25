# kubesphere-deploy — Reference

Full reference for `scripts/ksdeploy.sh`: commands, configuration, the KubeSphere
REST endpoints it calls, version differences, and troubleshooting.

## Contents

- [Command reference](#command-reference)
- [Configuration](#configuration)
- [Authentication](#authentication)
- [KubeSphere API endpoints](#kubesphere-api-endpoints)
- [Version differences (3.x vs 4.x)](#version-differences-3x-vs-4x)
- [Troubleshooting](#troubleshooting)

## Command reference

```
ksdeploy.sh <command> [args]
```

| Command | Description |
| --- | --- |
| `auth` | Verify credentials work. Prints `OK` and the auth mode, never the token. |
| `workspaces` | List workspace names. |
| `devops [workspace]` | List DevOps projects in a workspace, with `name` and `generateName`. |
| `resolve-devops [ws] [generate]` | Print the real DevOps project name (`metadata.name`). |
| `pipelines <devops>` | List pipelines in a DevOps project. |
| `params <devops> <pipeline>` | Show a pipeline's parameter template (`name`, type, default, description). |
| `runs <devops> <pipeline> [--branch=<b>]` | List recent runs of a pipeline. |
| `run [pipeline] [flags]` | Trigger a pipeline run. Previews only unless `--yes` is given. |
| `status <devops> <run>` | Show a pipeline run's status. |
| `logs <devops> <pipeline> <run> [--branch=<b>]` | Print a run's console log. |
| `help` | Show usage. |

### `run` flags

| Flag | Meaning |
| --- | --- |
| `--workspace=<name>` | Override `KS_WORKSPACE`. |
| `--devops=<name>` | Use this exact DevOps project name; skips resolution. |
| `--devops-generate-name=<name>` | Resolve the DevOps project by `generateName`. |
| `--branch=<name>` | Branch for a multi-branch pipeline. |
| `--<PARAM>=<value>` | Override any pipeline parameter (e.g. `--POD_COUNT=2`). |
| `--yes` | Actually submit. Without it, `run` only prints the payload. |
| `--dry-run` | Force preview even when `KS_ASSUME_YES=1`. |

### Examples

```bash
# Inspect, then deploy with overrides
ksdeploy.sh params my-devops-abc12 my-app
ksdeploy.sh run my-app --POD_COUNT=2 --PROJECT_NAMESPACE=my-app-prod      # preview
ksdeploy.sh run my-app --POD_COUNT=2 --PROJECT_NAMESPACE=my-app-prod --yes # submit

# Resolve a DevOps project by its friendly name, then run
ksdeploy.sh run my-app --devops-generate-name=my-devops-prod --yes

# Monitor
ksdeploy.sh status my-devops-abc12 my-app-d2jmj
ksdeploy.sh logs   my-devops-abc12 my-app my-app-d2jmj
```

## Configuration

All settings are environment variables, normally provided via `kubesphere.env`
(see `kubesphere.env.example`). The script looks for the env file at
`$KS_ENV_FILE`, then `./kubesphere.env`, then next to the script.

| Variable | Required | Description |
| --- | --- | --- |
| `KS_URL` | yes | Base URL of ks-apiserver / console gateway. No trailing slash needed. |
| `KS_INSECURE` | no | `1` to accept self-signed TLS certs (`curl -k`). |
| `KS_CLUSTER` | no | Member cluster name for multi-cluster setups (adds `/clusters/<name>`). |
| `KS_TOKEN` | one of | Bearer token. |
| `KS_USERNAME` + `KS_PASSWORD` | one of | OAuth2 password grant. |
| `KS_USERNAME` + `KS_ENCRYPT` | one of | Legacy console `/login` flow. |
| `KS_OAUTH_CLIENT_ID` / `KS_OAUTH_CLIENT_SECRET` | no | Default `kubesphere` / `kubesphere`. |
| `KS_WORKSPACE` | for resolution | Workspace holding the DevOps project. |
| `KS_DEVOPS` | one of | Exact DevOps project `metadata.name`. |
| `KS_DEVOPS_GENERATE_NAME` | one of | Friendly name; resolved to `metadata.name`. |
| `KS_PIPELINE` | no | Default pipeline for `run`. |
| `KS_PARAM_<NAME>` | no | Default value for pipeline parameter `<NAME>`. |
| `KS_ASSUME_YES` | no | `1` to submit without the dry-run gate. |
| `KS_NO_CACHE` | no | `1` to disable on-disk bearer-token caching. |
| `KS_CACHE_DIR` | no | Directory for the token cache (default `$TMPDIR`). |

## Authentication

The script authenticates with the first method whose variables are set:

1. **`KS_TOKEN`** — sent as `Authorization: Bearer <token>`. Best for CI; use a
   ServiceAccount or kubeconfig token scoped with RBAC for
   `devops.kubesphere.io` PipelineRun create/get.
2. **`KS_USERNAME` + `KS_PASSWORD`** — `POST /oauth/token` with
   `grant_type=password` (form-encoded, `client_id`/`client_secret` default to
   `kubesphere`), yielding a bearer token. The OAuth client must be **Trusted**
   (KubeSphere's default). Successful tokens are cached (mode `600`, honoring
   `expires_in`) to avoid re-login on every call.
3. **`KS_USERNAME` + `KS_ENCRYPT`** — the console's `POST /login` flow. The
   `encrypt` value is the console's own reversible obfuscation of the password
   (not AES); copy it from the browser's `/login` request payload. Only needed
   when the OAuth password grant is disabled.

The script never prints tokens, passwords, the `encrypt` blob, or cookie jar
contents.

## KubeSphere API endpoints

All paths are prefixed with `KS_URL` (and `/clusters/<KS_CLUSTER>` when set).

| Purpose | Method & path |
| --- | --- |
| OAuth token | `POST /oauth/token` (form-encoded) |
| List workspaces | `GET /kapis/tenant.kubesphere.io/v1alpha2/workspaces` |
| List DevOps projects | `GET /kapis/tenant.kubesphere.io/v1alpha2/workspaces/{ws}/devops` |
| List pipelines | `GET /kapis/devops.kubesphere.io/v1alpha3/namespaces/{devops}/pipelines` |
| Pipeline detail / params | `GET …/namespaces/{devops}/pipelines/{pipeline}` → `spec.pipeline.parameters[]` |
| Trigger run | `POST …/namespaces/{devops}/pipelines/{pipeline}/pipelineruns` |
| Run status | `GET …/namespaces/{devops}/pipelineruns/{run}` |
| Run logs | `GET /kapis/devops.kubesphere.io/v1alpha2/namespaces/{devops}/pipelines/{pipeline}/runs/{run}/log?start=0` |
| Run logs (multi-branch) | `GET …/pipelines/{pipeline}/branches/{branch}/runs/{run}/log?start=0` |

Notes:

- Pipeline parameters are `spec.pipeline.parameters[]`, each
  `{name, default_value, type, description}` — the JSON key is snake_case
  `default_value`.
- The trigger payload is `{"parameters":[{"name":"…","value":"…"}]}`. The run id
  is the server-generated `metadata.name` in the response.
- Override values from the CLI are submitted as JSON **strings** (e.g.
  `--POD_COUNT=2` → `"2"`), matching what the KubeSphere console sends. A
  parameter that resolves to an empty value is omitted from the payload, so an
  empty override falls back to the template default rather than clearing it.
- Run **logs** only exist on the `v1alpha2` path, even for runs created via
  `v1alpha3`.
- Multi-branch pipelines need the branch on the trigger, runs, and logs calls —
  pass `--branch=<name>` to `run`, `runs`, and `logs`.

## Version differences (3.x vs 4.x)

- The DevOps per-project path segment is `…/namespaces/{devops}/…` in current
  KubeSphere (a DevOps project is a namespace). Some older 3.x builds used
  `…/devops/{devops}/…`. The script tries `namespaces/` first and falls back to
  `devops/` on a `404`, so both work.
- In KubeSphere 4.x (LuBan), DevOps is an **installable extension**. If
  `ks-devops` is not enabled, the `devops.kubesphere.io` routes will not exist —
  install/enable the DevOps extension first.
- DevOps project `metadata.name` is usually a generated id with a random suffix
  (e.g. `my-devops-abc12`), not the display name. Resolve it via
  `devops`/`resolve-devops`, or set `KS_DEVOPS` directly.

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `KS_URL is not set` | Set `KS_URL` in `kubesphere.env` or the environment. |
| `no credentials found` | Set one of: `KS_TOKEN`; `KS_USERNAME`+`KS_PASSWORD`; `KS_USERNAME`+`KS_ENCRYPT`. |
| `OAuth login failed` | Wrong username/password, or the password grant client is not Trusted — use `KS_TOKEN` instead. |
| `console login failed: no token cookie` | Stale/incorrect `KS_ENCRYPT`; re-copy it from the browser, or switch to `KS_PASSWORD`/`KS_TOKEN`. |
| `could not resolve DevOps project` | The printed list shows valid names; set `KS_DEVOPS` to one, or fix `KS_DEVOPS_GENERATE_NAME`. |
| `pipeline '…' not found` | Check the pipeline name with `pipelines <devops>`; check workspace/DevOps. |
| `HTTP 401` mid-run | Token expired; the script re-authenticates on the next call. Run again. |
| `HTTP 404` on all DevOps routes | On 4.x, enable the `ks-devops` extension. Otherwise check `KS_URL`. |
| TLS / certificate errors | Set `KS_INSECURE=1` for self-signed certs (development only). |
| `missing dependency: jq` | Install jq: `brew install jq` (macOS) / `apt-get install jq` (Debian/Ubuntu). |
| Network unreachable | Confirm VPN / firewall and that `KS_URL` is reachable from this host. |
| `status`/`runs` show `null`/`-` | The cluster reports state under `.status.phase` / the `devops.kubesphere.io/jenkins-pipelinerun-*` annotations (or BlueOcean run objects); the script reads both shapes — update to the latest `ksdeploy.sh` if you still see `null`. |
| `logs` prints a stage/step summary instead of raw text | The v1alpha2 raw-log route is unavailable on this cluster (404/406); the script falls back to the v1alpha3 `pipelineruns/<run>/nodedetails` breakdown. Pass the pipelinerun **name** (not the build id) and open the console URL for full per-step text. |
