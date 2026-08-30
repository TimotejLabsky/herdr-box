# herdr-box

A persistent dev box for coding agents, built to run in the k3s cluster.
[herdr](https://herdr.dev) keeps the agents alive between SSH sessions;
the pod's home volume keeps everything else.

```
phone / laptop ──ssh dev@192.168.200.106──▶ herdr-box pod
                                              sshd ─▶ herdr
                                                       ├─ pane: claude
                                                       ├─ pane: codex
                                                       ├─ pane: opencode
                                                       └─ pane: shell
                                              /home/dev ─▶ Longhorn PVC
```

## What's inside

| | |
| --- | --- |
| Base | Debian 13 slim, sshd (key-only, user `dev`), passwordless sudo, tini |
| Multiplexer | herdr (pinned release binary) |
| Agents | Claude Code, Codex CLI, opencode |
| Runtimes | Node.js, Python 3 + uv |
| Tools | git, git-lfs, gh, kubectl, vim, ripgrep, fd, fzf, jq, build-essential |

Everything outside `/home/dev` is ephemeral — `sudo apt install` works for a
session, but durable software belongs in the Dockerfile.

## State & identity

- `/home/dev` — PVC (repos, agent credentials, herdr session state)
- `/etc/ssh/hostkeys` — PVC subPath; SSH host identity survives pod rescheduling
- `authorized_keys` — mounted ConfigMap at `/etc/herdr-box/authorized_keys`,
  applied on every boot (manage keys in git, not on the box)
- `CLAUDE_CODE_OAUTH_TOKEN` — injected as container env, exported into SSH
  sessions via `/run/herdr-box/env.sh` (Claude Code shares the Max subscription)
- Codex / opencode — one-time `codex login` / `opencode auth login` inside the
  box; credentials persist on the volume

## CI / releases

- PRs build the image (no push)
- Pushes to `main` publish `ghcr.io/timotejlabsky/herdr-box:main` + `:sha-*`
- Tags `vX.Y.Z` publish `:vX.Y.Z` and create a GitHub release

Pinned versions in the Dockerfile (`ARG *_VERSION`) are bumped by Renovate.

## Deployment

Kubernetes manifests live in
[personal-infratructure](https://github.com/TimotejLabsky/personal-infratructure)
under `kubernetes/herdr/` — StatefulSet (one box per replica, per-pod
LoadBalancer IP for SSH), Longhorn `data-protection` volume, deployed via
ArgoCD. No docker-in-docker: agents use kubectl + the GitOps flow, image
builds go through the ARC buildah runners.
