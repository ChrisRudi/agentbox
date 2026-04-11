<p align="center">
  <h1 align="center">agentbox</h1>
  <p align="center">
    <strong>AI coding agents have full access to your filesystem.<br>agentbox changes that.</strong>
  </p>
  <p align="center">
    <a href="#installation">Installation</a> · <a href="#daily-usage">Usage</a> · <a href="#security-model">Security</a> · <a href="#comparison">Comparison</a>
  </p>
  <p align="center">
    🌍 <a href="./docs/README.de.md">Deutsch</a>
  </p>
</p>

---

**agentbox** runs AI coding agents (Claude Code, OpenAI Codex, Gemini CLI) in **disposable WSL2 distributions** with real filesystem and network isolation.

One command. No Docker. No Kubernetes. Just Windows + WSL2.

## Why?

AI coding agents are powerful — but they run with full privileges on your system. They can:

- Read and modify any file (SSH keys, browser profiles, other projects)
- Spawn arbitrary processes and open network connections
- Leave behind build artifacts, caches, and temp files that bloat WSL

agentbox gives you the productivity of AI agents **without the risk**.

## Installation

One command in an admin PowerShell:

```powershell
irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex
```

That's it. Open a WSL terminal — agentbox starts automatically.

<details>
<summary>What happens during installation?</summary>

1. Repository is cloned to `OneDrive\AI_Projects_Source\_control`
2. WSL2 template is built (Ubuntu Minimal + Node.js + Python3 + AI CLIs)
3. Windows Event Source and Scheduled Task are created
4. WSL `.bashrc` is configured (auto-start)
5. Desktop shortcut `agentbox.lnk` is created
6. `.wslconfig` with resource limits is set (4 GB RAM, 2 CPUs)

Duration: approx. 3–5 minutes, one-time only.
</details>

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

### Where does the code live?

All projects live in `OneDrive\AI_Projects_Source\` — on your Windows filesystem. The sandbox bind-mounts only the project folder. The agent writes directly to your OneDrive directory:

| Benefit | Description |
|---------|-------------|
| **OneDrive sync** | Code is automatically backed up to the cloud |
| **No copying** | Changes land on Windows immediately |
| **Sandbox gone, code stays** | Only the distro is deleted, not your files |
| **Package cache persists** | npm/pip caches are persistent — no re-downloads |
| **WSL stays lean** | No growing VHDX from caches and artifacts |

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
| AI APIs (Anthropic, OpenAI, Google) | Everything else |
| Package registries (auto by project type) | Arbitrary outbound connections |
| DNS (port 53) | Access to local services |

Project type `node` → only `npmjs.org`. Project type `python` → only `pypi.org`. HTML/PowerShell → no package registries.

### Resource Limits

- `.wslconfig`: 4 GB RAM, 2 CPUs, 1 GB swap (adjustable)
- **RAM watchdog**: Warns via Windows dialog when sandbox uses > 90% RAM
- Protection against runaway loops that freeze the host

### Build/Deploy Control

The agent **cannot execute anything itself**. It writes a task file, a Windows-side runner validates:

- Build command on whitelist? (`npm run build`, `make`, etc.) → Execute
- Deploy target on whitelist? (`local`, `github`) → Execute
- Everything else → **Rejected. No wildcards, no prefix matching.**

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
OneDrive\AI_Projects_Source\
+-- _control\
|   +-- install.ps1              # Bootstrap from GitHub
|   +-- win-setup.ps1            # One-time: build template
|   +-- win-task-runner.ps1      # Build/deploy runner
|   +-- wsl-ai-start.sh          # Project/agent selection
|   +-- wsl-sandbox-init.sh      # Sandbox initialization
|   +-- type_defaults.json       # Type detection + defaults
|   +-- SYSTEM_META_PROMPT.md    # Agent contract
|   +-- sandbox\
|   |   +-- template.tar.gz      # Template distro
|   +-- cache\
|       +-- npm\                  # Persistent npm cache
|       +-- pip\                  # Persistent pip cache
+-- MyProject\
|   +-- project.json
|   +-- CLAUDE.md
|   +-- src\
|   +-- assets\
|   +-- _tasks\
```

Seven scripts, two folders. That's all.

## Prerequisites

- Windows 11 + WSL2
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
