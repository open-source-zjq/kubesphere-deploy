# kubesphere-deploy

> A [Claude Code](https://code.claude.com) skill (and plugin) that triggers and
> monitors **KubeSphere DevOps** pipeline runs over the KubeSphere REST API —
> so you can deploy applications by just asking.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Claude Code Skill](https://img.shields.io/badge/Claude%20Code-Skill%20%2F%20Plugin-7C5CFF.svg)](https://code.claude.com/docs/en/skills)
[![KubeSphere 3.x · 4.x](https://img.shields.io/badge/KubeSphere-3.x%20%C2%B7%204.x-1ABC9C.svg)](https://kubesphere.io)

[English](README.md) · [中文](README.zh-CN.md)

---

`kubesphere-deploy` wraps a small, dependency-light shell CLI (`curl` + `jq`) in
a Claude Code skill. Tell Claude *"deploy my-app to prod"* and it will
authenticate to your KubeSphere cluster, find the right workspace / DevOps
project / pipeline, merge parameter defaults, show you the exact payload, and —
after you confirm — trigger the run and report its id, status and logs.

> **Scope:** this deploys *applications* through KubeSphere **DevOps pipelines**.
> It does **not** install the KubeSphere platform itself.

## Features

- **Trigger & monitor** DevOps pipeline runs: list workspaces, DevOps projects,
  pipelines and parameters; preview, run, check status, and stream logs.
- **Generic & version-tolerant** — works against any KubeSphere **3.x or 4.x**
  cluster; auto-falls-back across the `namespaces/` ↔ `devops/` path change.
- **Three auth methods**, auto-selected: bearer token (CI/service account),
  OAuth2 password grant, or the legacy console `/login` flow.
- **Safe by default** — `run` previews the payload and does not submit unless you
  pass `--yes` (or opt in once via `KS_ASSUME_YES=1` for CI). Secrets are never
  printed.
- **No vendor lock-in** — the CLI also runs standalone, outside Claude Code.

## Requirements

- [`curl`](https://curl.se/) and [`jq`](https://jqlang.github.io/jq/)
- Network access to a KubeSphere cluster with the **DevOps** component enabled
  (in KubeSphere 4.x, install the `ks-devops` extension)
- A KubeSphere account (or token) with permission to run the target pipeline

## Installation

### Option A — as a Claude Code plugin (recommended)

```text
/plugin marketplace add open-source-zjq/kubesphere-deploy
/plugin install kubesphere-deploy@kubesphere-deploy
/reload-plugins
```

### Option B — as a manual skill

```bash
git clone https://github.com/open-source-zjq/kubesphere-deploy.git
# All users:
cp -r kubesphere-deploy/skills/kubesphere-deploy ~/.claude/skills/
# …or just this project:
cp -r kubesphere-deploy/skills/kubesphere-deploy <your-project>/.claude/skills/
```

### Option C — standalone CLI (no Claude Code)

```bash
git clone https://github.com/open-source-zjq/kubesphere-deploy.git
cd kubesphere-deploy/skills/kubesphere-deploy
cp kubesphere.env.example kubesphere.env   # then edit
./scripts/ksdeploy.sh workspaces
```

## Configuration

Copy the template and fill it in (it is gitignored):

```bash
cd skills/kubesphere-deploy
cp kubesphere.env.example kubesphere.env
```

Minimum: set `KS_URL`, one credential, and your workspace / DevOps / pipeline
defaults. Pick **one** credential method (checked in this order):

| Method | Variables | Best for |
| --- | --- | --- |
| Bearer token | `KS_TOKEN` | CI / service accounts |
| OAuth password grant | `KS_USERNAME` + `KS_PASSWORD` | interactive use |
| Console login (legacy) | `KS_USERNAME` + `KS_ENCRYPT` | clusters with the grant disabled |

See [`kubesphere.env.example`](skills/kubesphere-deploy/kubesphere.env.example)
for every option and [`reference.md`](skills/kubesphere-deploy/reference.md) for
full details.

## Usage

### In Claude Code

Just describe what you want — the skill activates from the request:

```text
> deploy my-app to prod with 2 replicas
> 触发 my-app 流水线，部署到 dev
> show the status of run my-app-d2jmj
> tail the logs for the last my-app run
```

Claude previews the resolved payload, asks you to confirm, then triggers the run
and reports the run id and console URL.

### From the CLI

```bash
ksdeploy.sh workspaces                       # list workspaces
ksdeploy.sh devops my-workspace              # list DevOps projects
ksdeploy.sh pipelines my-devops-abc12        # list pipelines
ksdeploy.sh params my-devops-abc12 my-app    # show parameter template

ksdeploy.sh run my-app --POD_COUNT=2         # preview (no submit)
ksdeploy.sh run my-app --POD_COUNT=2 --yes   # submit

ksdeploy.sh status my-devops-abc12 my-app-d2jmj
ksdeploy.sh logs   my-devops-abc12 my-app my-app-d2jmj
```

## How it works

`SKILL.md` is a thin orchestration guide; all logic lives in
`skills/kubesphere-deploy/scripts/ksdeploy.sh`. The script:

1. Authenticates (token → OAuth password → console login), caching bearer tokens
   securely between calls.
2. Resolves the DevOps project's real `metadata.name` (by `generateName` or
   directly).
3. Fetches the pipeline's parameter template and merges values with the
   precedence: `--flag` → `KS_PARAM_*` → template default → auto `APP_NAME`.
4. `POST`s a `PipelineRun` and returns the server-generated run id.

Endpoints and version notes are documented in
[`reference.md`](skills/kubesphere-deploy/reference.md).

## Security

- **Credentials never leave your machine.** `kubesphere.env` is gitignored; the
  script never prints tokens, passwords, the `encrypt` blob, or cookies.
- **Deploys require confirmation.** `run` is a dry run until you pass `--yes`
  (setting `KS_ASSUME_YES=1` opts out of the gate — intended for CI only).
- **Least privilege.** Prefer a scoped `KS_TOKEN` (ServiceAccount with RBAC for
  `devops.kubesphere.io` PipelineRun create/get) over a personal password.
- The bundled `SKILL.md` requests only the `Read` tool; running the CLI uses
  normal Claude Code permission prompts. Review skills before trusting a repo.

## Repository structure

```
kubesphere-deploy/
├── .claude-plugin/
│   ├── plugin.json              # plugin manifest
│   └── marketplace.json         # marketplace catalog (source: "./")
├── skills/
│   └── kubesphere-deploy/
│       ├── SKILL.md             # skill definition (orchestration guide)
│       ├── reference.md         # full command + API reference
│       ├── kubesphere.env.example
│       └── scripts/
│           └── ksdeploy.sh      # the CLI (curl + jq)
├── .github/workflows/validate.yml
├── CONTRIBUTING.md
├── CHANGELOG.md
├── LICENSE
└── README.md
```

## Troubleshooting

Common errors and fixes are in
[`reference.md`](skills/kubesphere-deploy/reference.md#troubleshooting).

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © open-source-zjq

> Not affiliated with or endorsed by KubeSphere or Anthropic. "KubeSphere" is a
> trademark of its respective owners.
