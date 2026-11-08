# Install the `vmware-wsl-lab` skill (instructions for Claude Code and Codex)

> 사람용 요약: Claude Code나 Codex에게 "https://github.com/naelonambul/wsl-vmware-lab/blob/main/INSTALL.md 를 읽고 설치해 줘"라고 말하면, 아래 절차대로 저장소를 받고 스킬을 설치한 뒤 `preflight.sh`로 점검합니다. 직접 하려면 같은 명령을 순서대로 실행하면 됩니다.

You are an AI coding agent (Claude Code or OpenAI Codex) installing the `vmware-wsl-lab` skill and the repository it drives. The skill only works together with a checkout of this repository (it runs the repository's scripts), so install both. Follow the steps in order and keep the user informed.

## Rules

- Ask before every step that changes the machine: cloning, copying the skill, overwriting an existing skill, installing packages. Show the exact path first.
- Never ask for, read, print or write the vmrest password. The user writes `%USERPROFILE%\.env` themselves (see the README).
- Do not install VMware Workstation, WSL, Terraform or Ansible as part of this file. If preflight reports them missing, stop and offer the skill's new-PC path (`reference/install-new-pc.md`) instead.
- Host name, Windows user, WSL user, distro and folders differ on every PC. Discover them; never copy values from examples.

## 1. Find where you run

```bash
uname -s; uname -r; echo "WSL_DISTRO_NAME=${WSL_DISTRO_NAME:-}"
```

- `Linux` with `microsoft` in the kernel release, or `WSL_DISTRO_NAME` set (it is empty in SSH sessions, so the kernel release is the reliable check): you are in WSL. Run the bash steps below directly.
- Windows (PowerShell, Git Bash): the scripts must still run in WSL. Run bash steps with `wsl.exe -e bash -lc '<command>'`, and check `wsl.exe -l -v` first. If WSL or a usable distribution is missing, distinguish a skill-only install from a full lab setup request. For an authorized lab setup, the repository is not available yet, so read section 2 of `reference/install-new-pc.md` from GitHub (https://github.com/naelonambul/wsl-vmware-lab/blob/main/.claude/skills/vmware-wsl-lab/reference/install-new-pc.md) and follow update, resource sizing, Ubuntu install and restart/resume from Windows PowerShell. Then continue with step 2 here, inside WSL. If Git for Windows is present you may clone first from PowerShell (`git clone https://github.com/naelonambul/wsl-vmware-lab.git C:\wsl-vmware-lab`) and read the local copy. Otherwise report the missing prerequisite and offer that path.
- Anything else (macOS, plain Linux): this lab needs Windows + WSL2 + VMware Workstation. Stop and tell the user.

## 2. Find or clone the repository

Look for an existing checkout first (any folder name):

```bash
{ find "$HOME" /mnt/c/Users -maxdepth 6 -name preflight.sh 2>/dev/null
  find /mnt/c /mnt/d -maxdepth 3 -name preflight.sh 2>/dev/null; } | sort -u \
  | while read -r f; do [ -f "$(dirname "$f")/lib/config.sh" ] && dirname "$f"; done
```

- One path printed: use it, and offer `git -C <path> pull --ff-only` to update.
- Several: ask the user which one.
- None: clone. Put it on the Windows drive, because the base VM files are created inside the repository and VMware Workstation must open them. Suggested place is the Windows user profile; if antivirus blocks writes there, use a folder outside it such as `C:\wsl-vmware-lab`:

```bash
profile=$(/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -NonInteractive \
  -Command '[Environment]::GetFolderPath("UserProfile")' </dev/null | tr -d '\r')
repo="$(wslpath -u "$profile")/wsl-vmware-lab"
echo "$repo"        # show the user and ask before cloning
git clone https://github.com/naelonambul/wsl-vmware-lab.git "$repo"
```

## 3. Install the skill

The repository carries the same skill twice, kept identical by `tools/sync-agent-skills.sh`:

| Agent | Copy in the repository | Personal install folder (all projects) | Project-only folder |
|---|---|---|---|
| Claude Code | `.claude/skills/vmware-wsl-lab` | `~/.claude/skills/vmware-wsl-lab` | `<project>/.claude/skills/vmware-wsl-lab` |
| Codex | `.agents/skills/vmware-wsl-lab` | `~/.agents/skills/vmware-wsl-lab` | `<project>/.agents/skills/vmware-wsl-lab` |

Install for the agent you are (ask whether the user also wants the other one). `~` is the home of the system the agent runs on: inside WSL, `$HOME`; on Windows, `%USERPROFILE%` (from WSL: `$(wslpath -u "$profile")`). Prefer the personal folder; ask if the user wants a project-only install. Inside a checkout of this repository both agents already see the skill without installing.

```bash
src="$repo/.claude/skills/vmware-wsl-lab"; dest="$HOME/.claude/skills/vmware-wsl-lab"   # Claude Code
# src="$repo/.agents/skills/vmware-wsl-lab"; dest="$HOME/.agents/skills/vmware-wsl-lab" # Codex
# Already installed: identical -> stop here (nothing to do); different -> show the list and ask before replacing.
if [ -e "$dest" ]; then diff -rq "$src" "$dest" && echo "already up to date"; fi
mkdir -p "$(dirname "$dest")"
rm -rf -- "$dest.new" && cp -r "$src" "$dest.new"
[ -e "$dest" ] && mv -- "$dest" "$dest.bak.$(date +%Y%m%d%H%M%S)"
mv -- "$dest.new" "$dest"
head -4 "$dest/SKILL.md"                        # must show: name: vmware-wsl-lab
```

Codex alternative for the skill only (the repository is still needed, step 2): in Codex run `$skill-installer install https://github.com/naelonambul/wsl-vmware-lab/tree/main/.agents/skills/vmware-wsl-lab`. It installs into `$CODEX_HOME/skills/vmware-wsl-lab` (default `~/.codex/skills`), which Codex also reads; that folder is outside the workspace, so the session needs write access there (the default sandbox refuses it). Do not install both there and in `~/.agents/skills`: Codex would list the skill twice.

A replaced skill is kept as `vmware-wsl-lab.bak.<time>`; tell the user, and delete it only if they ask.

## 4. Check the lab with preflight

```bash
bash "$repo/preflight.sh"; echo "exit=$?"
```

- `exit=0`: vmrest answers and the stored account is accepted. The API side is ready; preflight does not test SSH from another PC, the base VM or a clone lifecycle (the skill's verification checklist does).
- Anything else: read the `[ERROR]`/`[WARN]` lines and use the failure table in the skill's `SKILL.md` section 0. Typical first-time results: the vmrest account file `%USERPROFILE%\.env` does not exist yet (the user creates it; README section "vmrest 계정"), vmrest is not running, or tools are missing (new-PC path). Ask before fixing anything.

Installing the skill is done even when preflight fails; report both results separately.

## 5. Tell the user

Report: where you run, the repository path, the skill path (and any `.bak` copy), and the preflight result. Then:

- Claude Code watches existing skill folders and picks the new skill up in the running session. If the `skills` folder did not exist when the session started, run `/reload-skills` (or restart). It is invoked as `/vmware-wsl-lab`, or automatically when the request matches.
- Codex detects new skills automatically; if it does not show up in `/skills`, restart Codex. It is invoked with `$vmware-wsl-lab`, or automatically when the request matches.
- Update later: `git -C <repo> pull --ff-only`, then repeat step 3.
- Remove: delete the skill folder from step 3 (ask first). The repository and any VMs are separate; remove VMs with `./lab destroy`, never by deleting folders.
