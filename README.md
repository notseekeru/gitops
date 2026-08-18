# gitops

This repo holds the GitOps content for the `portfolio.seekeru.tech` and `diagram.seekeru.tech` stack on Kubernetes. It is **not** the installer — cluster bootstrap, the root Application, Kubernetes secrets, and the kubeconfig are all provisioned by the Terraform repo ([`../terraform`]).

The repo uses ArgoCD **App of Apps**:

- `apps-of-apps/`  — the **ArgoCD Application objects** (children) telling ArgoCD which workload paths to sync.
- `apps/`          — the **workloads** (Deployments, Services) for each app.
- `infra/`         — shared cluster resources (ingress, Cloudflare tunnel).
- `app.yaml`       — the **root Application** (parent). Applied by Terraform, not by hand.

**Deploy model:** push commits to `main`; ArgoCD watches this repo and each child Application syncs its own path with `prune` + `selfHeal`. Never apply workloads by hand — that fights `selfHeal`.

## Prerequisites

- [Nix](https://nixos.org/download) with [flakes](https://nixos.wiki/wiki/Flakes) enabled
- [direnv](https://direnv.net/) (optional — auto-loads the shell)

```bash
direnv allow   # loads dev shell + exports KUBECONFIG
```

The dev shell installs `kubectl` and `argocd` via the [flake](./flake.nix). The `.envrc` exports `KUBECONFIG=~/kubeconfig` — the kubeconfig **written by the Terraform apply** (see the Terraform repo), so you target the cluster Terraform provisioned.

## Layout

```
├── apps-of-apps/
│   ├── portfolio.yaml      # ArgoCD App → apps/portfolio
│   ├── diagram.yaml        # ArgoCD App → apps/diagram
│   └── infra.yaml          # ArgoCD App → infra
├── apps/
│   ├── portfolio/          # Portfolio app — React frontend (static)
│   └── diagram/            # Diagram app   — Node backend + React frontend
├── infra/
│   ├── diagram-ingress.yaml   # nginx Ingress for diagram.seekeru.tech (/api + /)
│   ├── portfolio-ingress.yaml # nginx Ingress for portfolio.seekeru.tech (/)
│   └── cloudflared.yaml    # Cloudflare Tunnel client (QUIC)
├── app.yaml                # ArgoCD root Application — applied by Terraform
├── kustomization.yaml      # Aggregates the Apps-of-Apps children (informational / local preview only)
├── flake.nix               # Nix flake for dev shell (kubectl, argocd)
├── .envrc                  # direnv: loads flake + sets KUBECONFIG
└── README.md
```

## Ingress

| Domain                   | /api →                      | / →                            |
| ------------------------ | --------------------------- | ------------------------------ |
| `portfolio.seekeru.tech` | _(no API route)_            | `portfolio-prod-frontend:8080` |
| `diagram.seekeru.tech`   | `diagram-prod-backend:3100` | `diagram-prod-frontend:8080`   |

### Ingress annotations

- **CSP:** strict Content-Security-Policy allowing self, Cloudflare Insights, Google Fonts
- **CORS:** allows `seekeru.tech` and `*.seekeru.tech` origins
- **Rate limit:** 30 req/s, burst 20
- **Proxy timeouts:** connect 10s, send 30s, read 60s
- **Body size:** 10 MB max

## Secrets

All Kubernetes secrets are **created by the Terraform apply** (from Infisical values) —
not manually. The deployments in this repo reference them by name:

- `cloudflared-token`   (`default`) — Cloudflare Tunnel token.
- `ghcr-login`          (`default`) — GHCR pull secret.
- `diagram-secrets`     (`default`) — API key + PostgreSQL connection string.

Manage their values in Infisical and re-run `make apply MOD=k3s` (or `MOD=doks`) in the
Terraform repo. Do **not** create them with `kubectl` — Terraform owns them.

## Image versions

Images are pinned to immutable digest-like SHA tags in each app's `kustomization.yaml`
(never `latest`), which enables exact rollback. Current pins:

| App       | Image                                   | Tag               |
| --------- | --------------------------------------- | ----------------- |
| portfolio | `ghcr.io/notseekeru/portfolio-frontend` | `00fe8ae…7952e`   |
| diagram   | `ghcr.io/notseekeru/diagram_backend`    | `3e30429…9ab6d09` |
| diagram   | `ghcr.io/notseekeru/diagram_frontend`   | `3e30429…9ab6d09` |

Bump a tag by editing `apps/<app>/kustomization.yaml` → commit → push.

## How this repo gets applied

This repo is **not** applied by hand. The Terraform repo is the installer:

1. Terraform installs ArgoCD (Helm chart), creates the Kubernetes secrets, then applies
   `app.yaml` — the root Application — via the `kubectl` provider (`kubectl_manifest`,
   path default `${path.module}/../../../gitops/app.yaml`).
2. That root Application (App of Apps) creates the children in `apps-of-apps/`, each of
   which auto-syncs its own workload path (`apps/`, `infra/`) with `prune` + `selfHeal`.

So a fresh cluster is bootstrapped entirely by `make apply MOD=k3s` (or `MOD=doks`) in
the Terraform repo. This repo's only job is to hold the YAML ArgoCD syncs.

> **Never** `kubectl apply` `app.yaml`, the secrets, or files under `apps/`/`infra/` directly —
> Terraform owns the root app and secrets; ArgoCD `selfHeal` owns the workload manifests. Either
> would fight the other and reconcile your changes away.

## Deploy workflow (normal operation)

1. Commit + push changes to `main`.
2. ArgoCD's app controller picks up the new revision and auto-syncs each affected child
   (auto-sync: `prune` + `selfHeal` are on for every Application, root and children).
3. `kubectl get applications -n argocd` to observe status.

You generally never need to touch ArgoCD manually. Forcing a sync outside git is only for
recovery or poking ArgoCD's cached state.

---

## Forcing a sync (outside of git)

Auto-sync applies every change pushed to `main`. To force a refresh/sync (e.g. ArgoCD
lagging or manually triggered rollback):

The `argocd` CLI is listed in `flake.nix` but only on PATH if the dev shell is loaded
(`direnv allow`). It's faster to drive ArgoCD via kubectl — patch the app's operation
annotation:

```bash
# Refresh the app's view of the repo, then run a sync with prune.
# The app name is one of: gitops (root) | portfolio | diagram | infra
APP=gitops
kubectl patch application $APP -n argocd --type merge -p \
  '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
kubectl patch application $APP -n argocd --type merge -p \
  '{"metadata":{"annotations":{"argocd.argoproj.io/operation":"{\"sync\":{\"revision\":\"HEAD\",\"prune\":true,\"dryRun\":false,\"force\":false},\"syncOperationResult\":{}}"}}}'
```

If the `argocd` CLI is available in the dev shell, the equivalent is:

```bash
argocd app sync gitops          # parent
argocd app sync portfolio       # each child syncs independently
argocd app sync diagram
argocd app sync infra
```

### Sync status

The parent `gitops` app reports **`Unknown` sync / `Healthy` health** — expected for
AppOfApps: ArgoCD doesn't compare child `Application` objects the way it does workloads,
so the parent never reads as "Synced". Judge deployment state by the children:

```bash
kubectl get applications -n argocd        # one row per app
kubectl get deploy -n default             # actual workloads
```

## Known trade-offs (accepted, not fixed)

- **Probes are `tcpSocket`**: readiness/liveness only verify the port accepts TCP, not that the app actually serves HTTP. The diagram backend (`:3100`) has no `/health` route, so HTTP probes are deferred. Upgrade path: add `/health` to the backend, then swap all three deployments to `httpGet` probes — the two frontends (nginx, serves `/`) can be switched immediately regardless.

- **CORS `*.seekeru.tech` + CSP `'unsafe-inline'`**: the loosest security knobs in the stack. Fine for a personal deployment; tighten to explicit origins and nonces/hashes before adding third-party scripts or broadening exposure.

- **Health-probe `failureThreshold` left at the Kubernetes default of 3** (deliberate): matches the minimal-resource posture; a hung app is tolerated ~30s before liveness restarts it.
