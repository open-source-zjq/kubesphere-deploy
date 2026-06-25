# Contributing to kubesphere-deploy

Thanks for your interest in improving this project! Contributions of all
kinds — bug reports, fixes, docs, and new features — are welcome.

## Ground rules

- **Never commit credentials.** Only `kubesphere.env.example` is tracked;
  `kubesphere.env`, tokens, kubeconfigs and keys are gitignored. Double-check
  your diff before pushing.
- Keep `SKILL.md` lean (orchestration only); put detail in `reference.md` and
  logic in `scripts/ksdeploy.sh`.
- The script must never print tokens, passwords, the `encrypt` blob, or cookies.

## Development setup

```bash
git clone https://github.com/open-source-zjq/kubesphere-deploy.git
cd kubesphere-deploy
# Install the linters used by CI:
#   macOS:   brew install shellcheck jq
#   Ubuntu:  sudo apt-get install -y shellcheck jq
```

## Before opening a PR

Run the same checks CI runs:

```bash
# 1. Shell script lints clean
shellcheck skills/kubesphere-deploy/scripts/ksdeploy.sh

# 2. Script parses
bash -n skills/kubesphere-deploy/scripts/ksdeploy.sh

# 3. JSON manifests are valid
jq empty .claude-plugin/plugin.json
jq empty .claude-plugin/marketplace.json

# 4. SKILL.md has YAML frontmatter with name + description
head -1 skills/kubesphere-deploy/SKILL.md   # should be: ---
```

If you have the Claude Code CLI, also run:

```bash
claude plugin validate .
```

## Testing changes against a cluster

The CLI is self-contained, so you can iterate without Claude Code:

```bash
cd skills/kubesphere-deploy
cp kubesphere.env.example kubesphere.env   # fill in a test cluster
./scripts/ksdeploy.sh auth
./scripts/ksdeploy.sh run <pipeline>       # dry run (no --yes)
```

Please describe how you tested any API-facing change, and note the KubeSphere
version(s) you tried (3.x vs 4.x behave slightly differently — see
`reference.md`).

## Commit / PR style

- One logical change per PR; keep diffs focused.
- Update `README.md` / `README.zh-CN.md` / `reference.md` when behavior changes.
- Add an entry to `CHANGELOG.md` under "Unreleased".
- Bump `version` in `.claude-plugin/plugin.json` for user-facing releases (this
  is what `/plugin update` keys off).

## License

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
