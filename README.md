<p align="center">
  <h1 align="center">agentbox</h1>
  <p align="center">
    <strong>AI coding agents have full access to your filesystem.<br>agentbox changes that.</strong>
  </p>
  <p align="center">
    <a href="#installation">Installation</a> · <a href="#supported-agents">Agents</a> · <a href="#daily-usage">Usage</a> · <a href="#security-model">Security</a> · <a href="#configuration">Config</a>
  </p>
  <p align="center">
    🌍 <a href="./docs/README.de.md">Deutsch</a>
  </p>
</p>

---

**agentbox** runs AI coding agents in **disposable WSL2 distributions** with real filesystem and network isolation.

One command. No Docker. No Kubernetes. Just Windows + WSL2.

## Why?

AI coding agents are powerful — but they run with full privileges on your system. They can:

- Read and modify any file (SSH keys, browser profiles, other projects)
- Spawn arbitrary processes and open network connections
- Leave behind build artifacts, caches, and temp files that bloat WSL

agentbox gives you the productivity of AI agents **without the risk**.

## Supported Agents

| Agent | Default | Install | Activate |
|-------|---------|---------|----------|
| **Claude Code** (Anthropic) | Enabled | npm | — |
| **OpenAI Codex** (OpenAI) | Enabled | npm | — |
| **Gemini CLI** (Google) | Enabled | pip | — |
| **Aider** | Disabled | pip | Set `agent_aider_enabled` to `true` in `config.json` |
| **Goose** (Block) | Disabled | pip | Set `agent_goose_enabled` to `true` in `config.json` |

Enable additional agents → edit `config.json` → run `install.ps1` again to rebuild the template.

## Installation

One command in an admin PowerShell:

```powershell
irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex
```

That's it. Open a WSL terminal — agentbox starts automatically.

### Update

Same command. If agentbox is already installed, it pulls the latest version and rebuilds the template (including newly enabled agents).

<details>
<summary>What happens during installation?</summary>

1. Repository is cloned to `AI_Projects_Source\_control` (or your custom path)
2. WSL2 template is built (Ubuntu Minimal + Node.js + Python3 + enabled AI CLIs)
3. Windows Event Source and Scheduled Task are created
4. WSL `.bashrc` is configured (auto-start)
5. Desktop shortcut `agentbox.lnk` is created
6. `.wslconfig` with resource limits is set (configurable via `config.json`)

Duration: approx. 3–5 minutes, one-time only. Updates are faster.
</details>

### Storage Location

By default, agentbox uses `OneDrive\AI_Projects_Source\`. You can use **any folder** instead:

| Storage | How to configure |
|---------|-----------------|
| **OneDrive** (default) | Works out of the box |
| **Google Drive** | Set `base_path_override` in `config.json` to your Google Drive path |
| **Dropbox** | Set `base_path_override` in `config.json` to your Dropbox path |
| **Local folder** | Set `base_path_override` to any path, e.g. `D:\Dev\AgentProjects` |

Example in `config.json`:
```json
"base_path_override": "D:\\GoogleDrive\\AI_Projects"
```

## Daily Usage

Open a WSL terminal (or double-click the desktop shortcut):

```
Start agentbox? [Y/n] (auto in 5s)

=== agentbox ===

Which project?
  [1] MyProject (recent)
  [2] AnotherProject
Selection [1]: 1

Which agent?
  [1] Claude Code
  [2] OpenAI Codex
  [3] Gemini CLI
Selection [1]: 1

=== Starting Claude Code for MyProject ===
```

**Agent works → session ends → sandbox is deleted → code stays.**

Only agents that are both **enabled** in `config.json` and **installed** in the template are shown.

## Security Model

### Filesystem Isolation

The agent sees **only**:

```
/workspace/
  src/           (read-write)   Your code
  assets/        (read-only)    Static files
  _tasks/        (read-write)   Task triggers
  CLAUDE.md      (read-write)   Session context
  project.json   (read-only)    Configuration
```

The agent does **not** see: `/mnt/c/`, OneDrive, `~/.ssh/`, other projects, `_control/`.

Mounts use `nosymfollow` + `nodev` + hardlink protection (`sysctl`).

### Network Isolation

Via `iptables` — only what's necessary:

| Allowed | Blocked |
|---------|---------|
| AI APIs (configurable in `config.json`) | Everything else |
| Package registries (auto by project type) | Arbitrary outbound connections |
| DNS (port 53) | Access to local services |

Project type `node` → only `npmjs.org`. Project type `python` → only `pypi.org`. HTML/PowerShell → no package registries.

### Resource Limits

- `.wslconfig`: configurable via `config.json` (default: 4 GB RAM, 2 CPUs, 1 GB swap)
- **RAM watchdog**: Warns via Windows dialog when sandbox exceeds threshold (default: 90%)
- Protection against runaway loops that freeze the host

### Build/Deploy Control

The agent **cannot execute anything itself**. It writes a task file, a Windows-side runner validates:

- Build command on whitelist? → Execute
- Deploy target on whitelist? → Execute
- Everything else → **Rejected. No wildcards, no prefix matching.**

Both whitelists are configurable in `config.json`.

## Configuration

All settings live in `config.json` (optional — all values have built-in defaults):

| Setting | Default | Description |
|---------|---------|-------------|
| `base_path_override` | `""` (OneDrive) | Custom project storage path |
| `resources_memory` | `4GB` | WSL2 memory limit |
| `resources_processors` | `2` | WSL2 CPU cores |
| `build_whitelist` | 8 commands | Allowed build commands |
| `deploy_whitelist` | `local`, `github` | Allowed deploy targets |
| `firewall_ai_apis` | 3 endpoints | Allowed AI API domains |
| `agent_*_enabled` | Big 3 on | Enable/disable agents |
| `auto_start_timeout` | `5` | Auto-start countdown (seconds) |
| `auto_update` | `true` | Check for updates at startup |
| `auto_update_interval_hours` | `24` | Hours between update checks |

See [`config.json`](config.json) for the full list with all defaults.

## Comparison

|                          | Docker Dev Container | GitHub Codespaces | **agentbox** |
|--------------------------|:-------------------:|:-----------------:|:------------:|
| Requires Docker          | Yes                 | No (cloud)        | **No**       |
| One-liner install        | No                  | No                | **Yes**      |
| Agent isolation          | Manual              | Partial           | **Automatic** |
| Network restriction      | Manual              | No                | **Automatic** |
| Build/deploy whitelist   | No                  | No                | **Yes**      |
| Disposable sessions      | Manual              | No                | **Automatic** |
| Works offline            | Yes                 | No                | **Yes**      |
| Cost                     | Free                | From $0/month     | **Free**     |
| Setup time               | 10–30 min           | 5 min             | **3–5 min**  |

## Session Continuity

Agents read `CLAUDE.md` at the start and update it at the end of each session. No context is lost. A backup (`CLAUDE.md.bak`) is automatically created before each session.

## File Structure

```
AI_Projects_Source\               (or your custom path)
+-- _control\
|   +-- config.json               # Central configuration
|   +-- install.ps1               # Bootstrap from GitHub
|   +-- win-setup.ps1             # One-time: build template
|   +-- win-task-runner.ps1       # Build/deploy runner
|   +-- wsl-ai-start.sh           # Project/agent selection
|   +-- wsl-sandbox-init.sh       # Sandbox initialization
|   +-- type_defaults.json        # Type detection + defaults
|   +-- SYSTEM_META_PROMPT.md     # Agent contract
|   +-- lib\
|   |   +-- config.sh             # Bash config helper
|   +-- sandbox\
|   |   +-- template.tar.gz       # Template distro
|   +-- cache\
|       +-- npm\                   # Persistent npm cache
|       +-- pip\                   # Persistent pip cache
+-- MyProject\
|   +-- project.json
|   +-- CLAUDE.md
|   +-- src\
|   +-- assets\
|   +-- _tasks\
```

## Prerequisites

- Windows 10 (2004+) or Windows 11 + WSL2 (auto-installed if missing)
- Git
- Admin privileges (one-time only)
- **No Docker. No Kubernetes. No cloud.**

## Transparency

### What agentbox does NOT protect against

- WSL2 kernel exploits (Microsoft's responsibility)
- Malicious code in the project folder (the agent has r/w there — by design)
- DNS tunneling (theoretically possible, practically irrelevant)
- Not a multi-user system (one developer, one machine)

We document this because security claims only count when you're honest about the boundaries.
