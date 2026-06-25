# kubesphere-deploy

> 一个 [Claude Code](https://code.claude.com) 技能（同时也是插件），通过 KubeSphere
> REST API **触发并监控 KubeSphere DevOps 流水线**——用一句话就能部署应用。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Claude Code Skill](https://img.shields.io/badge/Claude%20Code-Skill%20%2F%20Plugin-7C5CFF.svg)](https://code.claude.com/docs/en/skills)
[![KubeSphere 3.x · 4.x](https://img.shields.io/badge/KubeSphere-3.x%20%C2%B7%204.x-1ABC9C.svg)](https://kubesphere.io)

[English](README.md) · [中文](README.zh-CN.md)

---

`kubesphere-deploy` 把一个轻量的 Shell CLI（仅依赖 `curl` 与 `jq`）封装成 Claude Code
技能。你只需说一句「把 my-app 部署到 prod」，它就会登录你的 KubeSphere 集群，定位到正确的
workspace / DevOps 项目 / 流水线，合并参数默认值，展示最终请求体，并在你确认后触发流水线，
返回运行 id、状态与日志。

> **范围说明：** 本技能通过 KubeSphere **DevOps 流水线**部署*应用*，
> 而**不是**安装 KubeSphere 平台本身。

## 功能特性

- **触发与监控**流水线运行：列出 workspace、DevOps 项目、流水线、参数；预览、运行、查状态、看日志。
- **通用且版本兼容**——支持任意 KubeSphere **3.x / 4.x** 集群，自动在 `namespaces/` ↔ `devops/`
  路径变化间回退。
- **三种鉴权方式**自动选择：Bearer Token（CI / 服务账号）、OAuth2 密码模式、传统控制台 `/login`。
- **默认安全**——`run` 默认只预览请求体，不加 `--yes` 不会提交（也可用 `KS_ASSUME_YES=1` 一次性放开，仅建议 CI 使用）；任何密钥都不会被打印。
- **无绑定**——CLI 也能脱离 Claude Code 独立运行。

## 环境要求

- [`curl`](https://curl.se/) 与 [`jq`](https://jqlang.github.io/jq/)
- 能访问已启用 **DevOps** 组件的 KubeSphere 集群（4.x 需安装 `ks-devops` 扩展）
- 一个有权限运行目标流水线的 KubeSphere 账号（或 Token）

## 安装

### 方式 A —— 作为 Claude Code 插件（推荐）

```text
/plugin marketplace add open-source-zjq/kubesphere-deploy
/plugin install kubesphere-deploy@kubesphere-deploy
/reload-plugins
```

### 方式 B —— 作为手动技能

```bash
git clone https://github.com/open-source-zjq/kubesphere-deploy.git
# 对所有项目生效：
cp -r kubesphere-deploy/skills/kubesphere-deploy ~/.claude/skills/
# 或仅当前项目：
cp -r kubesphere-deploy/skills/kubesphere-deploy <你的项目>/.claude/skills/
```

### 方式 C —— 独立 CLI（不使用 Claude Code）

```bash
git clone https://github.com/open-source-zjq/kubesphere-deploy.git
cd kubesphere-deploy/skills/kubesphere-deploy
cp kubesphere.env.example kubesphere.env   # 然后编辑
./scripts/ksdeploy.sh workspaces
```

## 配置

复制模板并填写（该文件已被 gitignore）：

```bash
cd skills/kubesphere-deploy
cp kubesphere.env.example kubesphere.env
```

至少需要设置 `KS_URL`、一种凭据，以及 workspace / DevOps / 流水线默认值。
**任选一种**凭据方式（按以下顺序判定）：

| 方式 | 变量 | 适用场景 |
| --- | --- | --- |
| Bearer Token | `KS_TOKEN` | CI / 服务账号 |
| OAuth 密码模式 | `KS_USERNAME` + `KS_PASSWORD` | 人工交互使用 |
| 控制台登录（传统） | `KS_USERNAME` + `KS_ENCRYPT` | 关闭了密码模式的集群 |

完整选项见 [`kubesphere.env.example`](skills/kubesphere-deploy/kubesphere.env.example)，
详细说明见 [`reference.md`](skills/kubesphere-deploy/reference.md)。

## 使用

### 在 Claude Code 中

直接描述需求，技能会自动触发：

```text
> 把 my-app 部署到 prod，副本数 2
> 触发 my-app 流水线，部署到 dev
> 查一下 my-app-d2jmj 这次运行的状态
> 看下 my-app 最近一次运行的日志
```

Claude 会先展示解析出的请求体，请你确认后再触发，并报告运行 id 与控制台链接。

### 命令行

```bash
ksdeploy.sh workspaces                       # 列出 workspace
ksdeploy.sh devops my-workspace              # 列出 DevOps 项目
ksdeploy.sh pipelines my-devops-abc12        # 列出流水线
ksdeploy.sh params my-devops-abc12 my-app    # 查看参数模板

ksdeploy.sh run my-app --POD_COUNT=2         # 预览（不提交）
ksdeploy.sh run my-app --POD_COUNT=2 --yes   # 提交

ksdeploy.sh status my-devops-abc12 my-app-d2jmj
ksdeploy.sh logs   my-devops-abc12 my-app my-app-d2jmj
```

## 工作原理

`SKILL.md` 只是一层薄薄的编排说明，全部逻辑都在
`skills/kubesphere-deploy/scripts/ksdeploy.sh`。脚本会：

1. 鉴权（Token → OAuth 密码 → 控制台登录），并在多次调用之间安全缓存 Bearer Token；
2. 解析 DevOps 项目真实的 `metadata.name`（按 `generateName` 匹配或直接指定）；
3. 拉取流水线参数模板并按优先级合并：`--flag` → `KS_PARAM_*` → 模板默认值 → 自动注入 `APP_NAME`；
4. `POST` 一个 `PipelineRun`，返回服务端生成的运行 id。

端点与版本说明见 [`reference.md`](skills/kubesphere-deploy/reference.md)。

## 安全

- **凭据不出本机。** `kubesphere.env` 已被 gitignore；脚本不会打印 Token、密码、`encrypt` 或 Cookie。
- **部署需确认。** `run` 在加上 `--yes` 之前只是预演（设置 `KS_ASSUME_YES=1` 会跳过该确认，仅限 CI 使用）。
- **最小权限。** 推荐使用受限的 `KS_TOKEN`（具备 `devops.kubesphere.io` PipelineRun create/get RBAC 的
  服务账号），而非个人密码。
- 随附的 `SKILL.md` 仅申请 `Read` 工具；运行 CLI 会走 Claude Code 常规的权限确认。安装第三方技能前请先审阅。

## 目录结构

```
kubesphere-deploy/
├── .claude-plugin/
│   ├── plugin.json              # 插件清单
│   └── marketplace.json         # 市场目录（source: "./"）
├── skills/
│   └── kubesphere-deploy/
│       ├── SKILL.md             # 技能定义（编排说明）
│       ├── reference.md         # 完整命令与 API 参考
│       ├── kubesphere.env.example
│       └── scripts/
│           └── ksdeploy.sh      # CLI（curl + jq）
├── .github/workflows/validate.yml
├── CONTRIBUTING.md
├── CHANGELOG.md
├── LICENSE
└── README.md
```

## 故障排查

常见错误与解决办法见
[`reference.md`](skills/kubesphere-deploy/reference.md#troubleshooting)。

## 贡献

欢迎提交 Issue 与 PR，详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

[MIT](LICENSE) © open-source-zjq

> 本项目与 KubeSphere、Anthropic 无任何隶属或背书关系。「KubeSphere」为其各自所有者的商标。
