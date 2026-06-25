# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `status`, `runs`, and `logs` now tolerate clusters that report run state under
  `.status.phase` / the `devops.kubesphere.io/jenkins-pipelinerun-*` annotations
  and return runs in BlueOcean shape (top-level `.name`/`.id`/`.result`/`.state`),
  in addition to the older `.status.state` / `.status.result` CRD fields — they
  no longer print `null`/`-` on such clusters.
- `logs` falls back to the v1alpha3 `pipelineruns/<run>/nodedetails` stage/step
  summary when the v1alpha2 raw-log route is unavailable (404/406 on some builds).

## [0.1.0] - 2026-06-25

### Added

- Initial release of the `kubesphere-deploy` Claude Code skill / plugin.
- `ksdeploy.sh` CLI with commands: `auth`, `workspaces`, `devops`,
  `resolve-devops`, `pipelines`, `params`, `runs`, `run`, `status`, `logs`.
- Three auto-selected authentication methods: bearer token, OAuth2 password
  grant, and the legacy console `/login` flow, with secure token caching.
- Version-tolerant DevOps API calls (KubeSphere 3.x and 4.x), with a
  `namespaces/` ↔ `devops/` path fallback.
- Parameter merging with precedence `--flag` → `KS_PARAM_*` → template default →
  auto `APP_NAME`, and a dry-run-by-default safety gate.
- Plugin (`plugin.json`) and marketplace (`marketplace.json`) manifests,
  `kubesphere.env.example`, `reference.md`, bilingual READMEs, and CI validation.

[Unreleased]: https://github.com/open-source-zjq/kubesphere-deploy/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/open-source-zjq/kubesphere-deploy/releases/tag/v0.1.0
