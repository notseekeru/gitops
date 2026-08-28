# gitops

This repo holds the GitOps content for the `portfolio.seekeru.tech` and `diagram.seekeru.tech` stack on Kubernetes. It is **not** the installer — cluster bootstrap, the root Application, Kubernetes secrets, and the kubeconfig are all provisioned by Terraform (see the separate `terraform` repo).

The repo uses ArgoCD **App of Apps**:

- `apps-of-apps/`  — the **ArgoCD Application objects** (children) telling ArgoCD which workload paths to sync.
- `apps/`          — the **workloads** (Deployments, Services) for each app.
- `infra/`         — shared cluster resources (ingress, Cloudflare tunnel).
- `app.yaml`       — the **root Application** (parent). Applied by Terraform, not by hand.

**Deploy model:** push commits to `main`; ArgoCD watches this repo and each child Application syncs its own path with `prune` + `selfHeal`. Never apply workloads by hand — that fights `selfHeal`.

## Prerequisites

The only hard requirement is `kubectl` pointed at the cluster Terraform provisioned.
The following are **optional** conveniences:

- **Nix** + [flakes](https://nixos.wiki/wiki/Flakes) — optional dev shell that adds `kubectl`, `argocd`, `infisical` ([flake](./flake.nix)).
- **direnv** — auto-loads that shell and sets `KUBECONFIG=~/kubeconfig` on `cd` (the path Terraform writes).

```bash
direnv allow   # optional: dev shell + sets KUBECONFIG
```

Most operations here use `kubectl` only (see [Forcing a sync](#forcing-a-sync-outside-of-git));
the `argocd` CLI is listed in the flake but is not required.

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
├── kustomization.yaml      # Aggregates the Apps-of-Apps children (for `kubectl kustomize .` preview)
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
not manually. The ones consumed by workloads in this repo:

- `cloudflared-token`   (`default`) — Cloudflare Tunnel token.
- `ghcr-login`          (`default`) — GHCR pull secret.
- `diagram-secrets`     (`default`) — API key + PostgreSQL connection string.

Terraform also creates `repo-secret` (`argocd`) — the HTTPS credentials ArgoCD
uses to pull this git repo. It is not consumed by workloads but is required for ArgoCD
to sync.

Manage their values in Infisical and re-run `make apply MOD=k3s` (or `MOD=doks`) in the
Terraform repo. Do **not** create them with `kubectl` — Terraform owns them.

## Image versions

Images are pinned to immutable SHA tags in each app's `kustomization.yaml` (never `latest`),
which enables exact rollback. As of writing:

| App       | Image                                   | Tag               |
| --------- | --------------------------------------- | ----------------- |
| portfolio | `ghcr.io/notseekeru/portfolio-frontend` | `00fe8ae…7952e`   |
| diagram   | `ghcr.io/notseekeru/diagram_backend`    | `3e30429…9ab6d09` |
| diagram   | `ghcr.io/notseekeru/diagram_frontend`   | `3e30429…9ab6d09` |

**All image tags auto-update via the CD pipeline** (CI → `workflow_run` on `main`). For each
service in the CD matrix it builds the image, then a job runs `kustomize edit set image` on
the owning `apps/<app>/kustomization.yaml` and pushes the SHA bump. So deployments self
package — this table drifts on every release; read the live SHAs from the files.

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

1. Push changes to `main` — either a code PR that triggers the CD pipeline, or a direct edit
   to a manifest/kustomization.
2. ArgoCD's app controller picks up the new revision and auto-syncs each affected child
   (auto-sync: `prune` + `selfHeal` are on for every Application, root and children).
3. `kubectl get applications -n argocd` to observe status.

You generally never need to touch ArgoCD manually. Forcing a sync outside git is only for
recovery or poking ArgoCD's cached state.
---

## Port-Forward

```bash
PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d) && echo -e "\n---> Local Login: https://localhost:8080\n---> Network Login: https://<YOUR_COMPUTER_IP>:8080\n---> Username: admin\n---> Password: $PASS\n" && kubectl port-forward svc/argocd-server -n argocd --address 0.0.0.0 8080:443
```

---

## Forcing a sync (outside of git)

Auto-sync applies every change pushed to `main`. To force a refresh/sync (e.g. ArgoCD
lagging or manually triggered rollback):

Drive ArgoCD entirely with `kubectl` — patch the app's operation annotation (no `argocd`
CLI needed):

```bash
# Refresh the app's view of the repo, then run a sync with prune.
# The app name is one of: gitops (root) | portfolio | diagram | infra
APP=gitops
kubectl patch application $APP -n argocd --type merge -p \
  '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
kubectl patch application $APP -n argocd --type merge -p \
  '{"metadata":{"annotations":{"argocd.argoproj.io/operation":"{\"sync\":{\"revision\":\"HEAD\",\"prune\":true,\"dryRun\":false,\"force\":false},\"syncOperationResult\":{}}"}}}'
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
