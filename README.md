<p align="center">
  <h1 align="center">agentbox</h1>
  <p align="center">
    <strong>AI coding agents have full access to your filesystem.<br>agentbox changes that.</strong>
  </p>
  <p align="center">
    <a href="#installation">Installation</a> · <a href="#supported-agents">Agents</a> · <a href="#daily-usage">Usage</a> · <a href="#vs-code-integration-optional">VS Code</a> · <a href="#security-model">Security</a> · <a href="#configuration">Config</a>
  </p>
  <p align="center">
    🌍 <a href="./docs/README.de.md">Deutsch</a>
  </p>
</p>

---

**AI coding agents solve problems — and wreck your system doing it:**

- They grind your machine to a halt — eating RAM and CPU without limits
- They trash your OS — caches, leftovers, until Windows won't boot clean anymore
- They steal your secrets — SSH keys, `.env` files, passwords
- They sit exposed on the network — your host and LAN are reachable
- They forget everything — once the session ends, the context is gone
- They keep pestering you for confirmation — because your system is on the line

**Not in a portable sandbox.**

One command. Clean environment. Full control. Fully portable.
Windows native. No Docker. No Kubernetes.

**agentbox** runs AI coding agents in **disposable WSL2 distributions** with real filesystem and network isolation — giving you the productivity of AI agents **without the risk**.

### Built for digital nomads

Hopping laptops shouldn't mean rebuilding your entire AI dev setup. agentbox is designed around that:

- **One PowerShell line installs everything** — on any fresh Windows box, in under two minutes. No image to ship, no container registry to pull from.
- **Your projects live in OneDrive** (or Dropbox, or whatever cloud sync you already use). The `_control/` folder is versioned and syncs by default, so your config, agent seeds, and project code follow you.
- **Sessions are disposable by design** — the whole point. Nothing to migrate, no state to drag along.
- **New machine = one line + one OAuth login per agent.** That's it. Keep coding.

Lose the laptop? Buy a new one, run one command, log in. Your work is already there.

## Performance

agentbox isn't just safer — it's **faster**. Example run on a modern laptop SSD under Windows 11 + WSL 2.x (2026-04-18):

| Metric                       | agentbox vs Host |
|------------------------------|------------------|
| Network download             | 1.1x             |
| Disk sequential write (1 GB) | **18.7x**        |
| Disk small files (10k x 4 B) | **9.1x**         |
| CPU SHA256 (500 MB)          | 1.9x             |
| Process spawn (500 procs)    | **17.3x**        |

The big wins come from the ext4-on-vhdx workspace overlays (`node_modules`, `.next`, `__pycache__` etc.) and Linux-native fork/exec — the same reason `npm install` and `pytest` feel snappier in WSL than on the Windows host.

Honest footnote: these ratios are measured against the **persistent host distro** (`agentbox_host`), without any session-time tuning. The **ephemeral agent session** layers BBR, dnsmasq caching, `force-unsafe-io` dpkg and additional ext4 overlays on top, so actual in-session numbers are typically higher.

Reproduce on your own hardware via the bundled demo project: agentbox → `[c] Konfiguration` → `[3] Benchmark ausfuehren` — code lives in [`tools/`](tools/).

## Supported Agents

| Agent | Default | Install | Activate |
|-------|---------|---------|----------|
| **Claude Code** (Anthropic) | Enabled | npm | — |
| **OpenAI Codex** (OpenAI) | Enabled | npm | — |
| **Gemini CLI** (Google) | Enabled | npm | — |
| **Aider** | Disabled | pip | Set `agent_aider_enabled` to `true` in `config.json` |
| **Goose** (Block) | Disabled | pip | Set `agent_goose_enabled` to `true` in `config.json` |

Enable additional agents: at the agent-selection menu, press **`[c]`** (labelled `Konfiguration`) and toggle the agent you want — this writes to `config.json` directly. Then run `install.ps1` once more in an admin PowerShell so the template gets rebuilt with the new agent binaries (`irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex`).

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
5. You're asked once: Windows Terminal / VS Code / both? (see [VS Code Integration](#vs-code-integration-optional))
6. Desktop shortcut `agentbox.lnk` is created (plus `agentbox (VS Code).lnk` if you picked VS Code)
7. `.wslconfig` with resource limits is set (configurable via `config.json`)

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

## Quick Start: Adding Projects

### New project

Create a folder in your projects directory — agentbox auto-detects the type on first start:

```
AI_Projects_Source\
+-- MyNewApp\
    +-- src\
        +-- index.js      ← agentbox detects "node"
```

A `project.json` is generated automatically. You can also create it manually:

```json
{
  "name": "MyNewApp",
  "type": "node",
  "version": "1.0.0",
  "build": { "command": "npm run build", "output_dir": "build_out" },
  "deploy": { "target": "", "url": "" },
  "agent": { "working_dir": "src", "entry_point": "index.js" }
}
```

### Existing project

Move or copy your project folder into `AI_Projects_Source\`:

```powershell
# PowerShell — copy existing project
Copy-Item -Recurse "D:\Dev\my-existing-app" "$env:OneDrive\AI_Projects_Source\my-existing-app"
```

agentbox expects this structure (only `src/` is required):

```
my-existing-app\
+-- src\              ← your code (read-write in sandbox)
+-- assets\           ← static files (read-only in sandbox, optional)
```

If your project has no `src/` folder, the project root is mounted as `src/` instead.

### project.json reference

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Project name (matches folder name) |
| `type` | Yes | `node`, `python`, `html`, `powershell`, or `generic` |
| `version` | No | Semantic version (default: `1.0.0`) |
| `build.command` | No | Must be on the build whitelist (see `config.json`) |
| `build.output_dir` | No | Build output directory (default: `build_out`) |
| `deploy.target` | No | `local` or `github` (must be on deploy whitelist) |
| `agent.working_dir` | No | Working directory inside project (default: `src`) |
| `agent.entry_point` | No | Main file (informational, for the agent) |

Auto-detected types and their defaults:

| Files found | Detected type | Default build command |
|-------------|--------------|----------------------|
| `package.json` | `node` | `npm run build` |
| `*.py` | `python` | `pip install -r requirements.txt` |
| `*.ps1` | `powershell` | `powershell -File build.ps1` |
| `*.html` | `html` | — |
| (none of the above) | `generic` | — |

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

> **Agent works → session ends → sandbox is deleted → code stays.**

Only agents that are both **enabled** in `config.json` and **installed** in the template are shown.

## VS Code Integration (Optional)

Want to watch the agent edit files in **real-time**? agentbox can use VS Code as the launcher instead of (or alongside) Windows Terminal.

On the first `install.ps1` run you're asked once:

```
Pick launcher for the agentbox shortcut:
  [1] Windows Terminal  (default — lean, proven)
  [2] VS Code           (live file-watch + agent-terminal in the editor)
  [3] Both              (two shortcuts — you decide per click)
```

Pick **[2]** (or **[3]**) and agentbox wires everything for you — including `winget`-installing VS Code itself if it's missing (user-scope, no admin):

- An `agentbox` **terminal profile** is smart-merged into your user `settings.json` (existing settings untouched; JSONC with comments is left alone and shown as a copy-paste snippet).
- A **workspace file** (`agentbox.code-workspace`) opens your project root (`AI_Projects_Source\`) in VS Code.
- A task with `runOn: folderOpen` starts the agent in a **dedicated terminal panel** the moment the workspace opens — confirm VS Code's one-time "trust this workspace" prompt and it's hands-off from there.

**Result on double-click:** VS Code opens → agent boots in the terminal panel → every file the agent writes shows up **live** in the Explorer tree, auto-reloads in the editor, and shows diffs in the Git gutter. No container setup, no VS Code Server, no browser tab — native Windows fsnotify picks up the changes through the WSL bind-mount.

Unlike other "agentbox"-style projects that rely on Docker devcontainers (extension dance, trust prompts, devcontainer.json to maintain) or VS Code Server in a browser tab, this is your **local native VS Code** — zero plugins required, zero container overhead on file I/O.

To change later, edit `launch_ui` in `config.json` (`wt` | `vscode` | `both`) and re-run `install.ps1`. The choice persists across updates.

## Security Model

### Filesystem Isolation

The agent sees **only**:

```
/workspace/                    ← project root and agent start directory
  src/           (read-write)   Your code
  assets/        (read-only)    Static files
  _tasks/        (read-write)   Task triggers
  CLAUDE.md      (read-write)   Session context
  project.json   (read-only)    Configuration
```

The agent starts in `/workspace/`, so the complete project layout is visible on the first `ls`. Projects without a `src/` subfolder get their root bind-mounted as `/workspace/src/`.

The agent does **not** see: `/mnt/c/`, OneDrive, `~/.ssh/`, other projects, `_control/`.

Directory mounts use `nosymfollow` + `nodev`; hardlink protection is enforced via `sysctl`.

### Network Isolation — What It Actually Does

**agentbox protects your machine from the agent, not the internet from the agent.**

iptables rules in the sandbox enforce:

| Allowed | Blocked |
|---------|---------|
| Outbound HTTPS/HTTP to any public IP | Access to private ranges (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `127/8`) |
| DNS (port 53) | All non-HTTP(S) ports |

The private-range drops are the important bit: they stop the agent from reaching your Windows host, LAN services, metadata endpoints, or other WSL distros. That's the client-protection threat model.

**What agentbox does NOT do:** per-domain egress filtering. iptables can't match hostnames reliably because CDNs rotate IPs mid-request, so there's no whitelist enforced on the actual packets. An agent with network access *can* reach any public HTTPS endpoint while a session is running. If that's in your threat model, you need an egress proxy — agentbox doesn't ship one.

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

### What Persists Across Sessions

The sandbox distro itself is disposable, but two layers on the Windows host survive session boundaries and get bind-mounted into each new sandbox:

- **Package caches**: `%LOCALAPPDATA%\agentbox\cache\npm` and `…\cache\pip` — so `npm install` / `pip install` don't re-download between sessions. Trade-off: an agent could theoretically poison the cache for a future session.
- **Per-agent auth dirs**: `%LOCALAPPDATA%\agentbox\auth\{claude,codex,gemini,aider,goose}` — so you don't have to log into each CLI on every session. Each agent gets its own subdir; within a session only the active agent's auth is mounted, so agents can't see each other's tokens.

Both live under `%LOCALAPPDATA%\agentbox\` (not in your `_control/` folder), so OneDrive doesn't sync binary caches or tokens. Delete either tree on the Windows side if you want a fully fresh start.

## Configuration

All settings live in `config.json` (optional — all values have built-in defaults):

| Setting | Default | Description |
|---------|---------|-------------|
| `base_path_override` | `""` (OneDrive) | Custom project storage path |
| `base_dir_name` | `AI_Projects_Source` | Project root folder name |
| `control_dir_name` | `_control` | Control directory name |
| `sandbox_user` | `agent` | Unprivileged user in sandbox |
| `resources_memory` | `4GB` | WSL2 memory limit |
| `resources_processors` | `2` | WSL2 CPU cores |
| `resources_swap` | `1GB` | WSL2 swap size |
| `resources_ram_warn_percent` | `90` | RAM watchdog threshold (%) |
| `resources_watchdog_interval` | `30` | Watchdog check interval (seconds) |
| `build_whitelist` | 8 commands | Allowed build commands |
| `deploy_whitelist` | `local`, `github` | Allowed deploy targets |
| `agent_*_enabled` | Big 3 on | Enable/disable agents |
| `auto_start_timeout` | `5` | Auto-start countdown (seconds) |
| `auto_update` | `true` | Check for updates at startup |
| `auto_update_interval_hours` | `24` | Hours between update checks |
| `launch_ui` | `""` (prompts once) | Shortcut target: `wt` (Windows Terminal), `vscode` (VS Code with live file-watch), or `both` |
| `event_log_source` | `AIProjects` | Windows Event Log source name |
| `scheduled_task_name` | `agentbox-task-runner` | Windows Scheduled Task name |

See [`config.json`](config.json) for the full list with all defaults.

## MCP Servers

agentbox can run any MCP server (Python or Node.js) on the host and make its tools available to the agent in every sandbox session. The bridge is **HTTP/SSE** with a single targeted firewall hole per activated MCP — all other sandbox isolation stays intact.

### In the menu (recommended)

```
agentbox  →  [c] Konfiguration  →  [4] MCP-Server einbinden

  [1] Neuen MCP-Server einbinden (Wizard findet alles automatisch)
  [2] MCP-Server entfernen
  [3] MCP-Hintergrund-Prozess neu laden (bei Problemen)
```

**[1] Wizard** — point it at an MCP-server folder, everything else is automatic:

- Type detection: Python (`pyproject.toml` / `main.py`) or Node.js (`package.json`)
- Entry point: `[project.scripts]` / `main.py` / `server.py` / `bin` / `main` / `index.js`
- Dependencies: `pip install -e .[dev]` / `pip install -e .` / `npm install`
- Environment variables: `.env.example` auto-parsed, secrets (tokens/keys) explicitly prompted
- MCP-ID: from `name` field or folder name
- KiCad detection in background (uses KiCad's bundled Python instead of system Python because only that has `pcbnew`)

The wizard checks and installs Node.js + `mcp-proxy` on first use if missing — no manual Windows-side prep needed.

### Architecture

- Host-side **Scheduled Task** `agentbox-mcp-dispatcher` (AtLogon + RestartOnFailure) starts one `mcp-proxy` instance per activated MCP that exposes the stdio server over HTTP/SSE
- Port is auto-assigned from 9000 (or fixed via `"port": N` in `config.json`); mapping in `%LOCALAPPDATA%\agentbox\mcp-runtime\ports.json`
- Sandbox gets **exactly one** TCP port per MCP allowed to the host IP (iptables-ACCEPT before the DROP rules); firewall otherwise unchanged
- Agent config gets patched with URL `http://<host-ip>:<port>/sse` on each sandbox start

### Manual config (advanced)

```json
"mcp_servers": [
  {
    "id": "my-mcp",
    "command": "C:\\path\\to\\python.exe",
    "args": ["main.py"],
    "cwd": "C:\\Users\\me\\Projects\\MyMcp",
    "env": { "SOME_TOKEN": "..." },
    "port": 9099
  }
]
```

Apply with `agentbox --reload-mcp`.

### Trust boundary

Whatever `command` / `args` you put in runs on the host as your user. There is **no** command whitelist — matches Claude Desktop / Cursor behavior.

### Debugging

- `%LOCALAPPDATA%\agentbox\mcp-runtime\dispatcher.log` — dispatcher lifecycle
- `%LOCALAPPDATA%\agentbox\mcp-runtime\<id>\bridge.log` — per-MCP stdout/stderr
- `curl -N http://127.0.0.1:9000/sse` from the host — raw SSE stream for diagnostics

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

## Replay Mode: Cross-Agent Comparison

Run the same task with different agents and compare the results — deterministically.

### How it works

Every session automatically creates a **snapshot** (code + CLAUDE.md before the agent starts) and a **diff** (all changes the agent made). This enables:

```bash
# 1. Run a task with Claude Code
agentbox
#    → Session-ID: 20260411_143000_claude_MyProject

# 2. Replay the same starting point with a different agent
agentbox --replay 20260411_143000_claude_MyProject
#    → Choose a different agent (e.g., Codex or Aider)
#    → Session-ID: 20260411_150000_codex_MyProject

# 3. Compare what each agent did
agentbox --compare 20260411_143000_claude_MyProject 20260411_150000_codex_MyProject
```

### Commands

| Command | Description |
|---------|-------------|
| `agentbox --list-sessions` | List all recorded sessions |
| `agentbox --replay <session-id>` | Restore snapshot, run with another agent |
| `agentbox --compare <id1> <id2>` | Side-by-side diff of two sessions |

### What gets compared

- **Code changes**: Full unified diff of all files modified by each agent
- **CLAUDE.md changes**: How each agent documented their work
- **Session metadata**: Agent name, timestamp, project

This is useful for evaluating which agent handles specific tasks best, or for verifying that a refactoring produces equivalent results across agents.

## Post-Session Diagnostics

After each session, agentbox lists connection attempts the sandbox host-protection rules rejected — anything that tried to go somewhere other than HTTPS/HTTP on a public IP:

```
=== Blocked connection attempts ===
(not 443/80 or to private networks — host-protection rules matched)

  [BLOCKED] internal-service.local (10.0.0.42)
  [BLOCKED] 203.0.113.42
```

Typical entries: the agent tried to reach your Windows host (`172.x`, `127.0.0.1`), your LAN (`192.168.x`), or a non-web port. If you see hits on a domain you actually need — e.g. a private artifact mirror — the current build of agentbox has no per-host whitelist knob; you'd need to loosen the iptables rules in `wsl-sandbox-init.sh` yourself.

## File Structure

agentbox keeps **code/config** and **runtime state** in two separate trees
on purpose — the former is versioned and cloud-syncable, the latter is
binary/sensitive and stays on the local disk.

**Versioned tree** (your projects folder, OneDrive-friendly):

```
AI_Projects_Source\               (or your custom path)
+-- _control\                     # Cloned from this repo; syncs with OneDrive
|   +-- config.json               # Central configuration
|   +-- install.ps1               # Bootstrap from GitHub
|   +-- win-setup.ps1             # One-time: build template
|   +-- win-setup-core.ps1        # Template builder (called by install.ps1)
|   +-- win-task-runner.ps1       # Build/deploy runner
|   +-- wsl-ai-start.sh           # Project/agent selection
|   +-- wsl-sandbox-init.sh       # Sandbox initialization
|   +-- type_defaults.json        # Type detection + defaults
|   +-- SYSTEM_META_PROMPT.md     # Agent contract
|   +-- refactor.md               # Architecture-cleanup roadmap
|   +-- lib\
|       +-- config.sh             # Bash config helper
+-- MyProject\
|   +-- project.json
|   +-- CLAUDE.md
|   +-- src\
|   +-- assets\
|   +-- _tasks\
```

**Runtime tree** (local, never syncs to the cloud):

```
%LOCALAPPDATA%\agentbox\
+-- sandbox\
|   +-- template.vhdx             # Primary (WSL 2.0+); ~3-5s copy on SSD
|   +-- template.tar.gz           # Fallback for WSL < 2.0.x only
|   +-- .config_hash              # Skip-build check
+-- cache\
|   +-- npm\                      # Persistent npm cache
|   +-- pip\                      # Persistent pip cache
+-- sessions\                     # Replay snapshots + diffs
+-- auth\
|   +-- claude\                   # Claude Code OAuth + tokens
|   +-- codex\
|   +-- gemini\
|   +-- aider\
|   +-- goose\
+-- host-distro\                  # Persistent host-WSL distro (default)
```

> The split is enforced: `_control/` only holds versioned scripts + config,
> never cache or token data. OneDrive's Files-on-Demand can't place-hold
> binary state, and secrets have no business in the cloud by default.

## Prerequisites

- Windows 10 (2004+) or Windows 11 + WSL2 (auto-installed if missing)
- Admin privileges (one-time only)
- Git (optional — used for faster updates, not required)
- **No Docker. No Kubernetes. No cloud.**

## Transparency

### What agentbox does NOT protect against

- WSL2 kernel exploits (Microsoft's responsibility)
- Malicious code in the project folder (the agent has r/w there — by design)
- DNS tunneling (theoretically possible, practically irrelevant)
- Not a multi-user system (one developer, one machine)

We document this because security claims only count when you're honest about the boundaries.
