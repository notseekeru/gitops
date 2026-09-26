# gitops

This repo holds the GitOps content for the `portfolio.seekeru.tech`, `diagram.seekeru.tech` and `maxterview.seekeru.tech` stack on Kubernetes. It is **not** the installer — cluster bootstrap, the root Application, Kubernetes secrets, and the kubeconfig are all provisioned by Terraform (see the separate `terraform` repo).

The repo uses ArgoCD **App of Apps**:

- `apps-of-apps/` — the **ArgoCD Application objects** (children) telling ArgoCD which workload paths to sync.
- `apps/` — the **workloads** (Deployments, Services) for each app.
- `infra/` — shared cluster resources (ingress, Cloudflare tunnel).
- `app.yaml` — the **root Application** (parent). Applied by Terraform, not by hand.

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
│   ├── maxterview.yaml     # ArgoCD App → apps/maxterview/overlays/prod
│   └── infra.yaml          # ArgoCD App → infra
├── apps/
│   ├── portfolio/          # Portfolio app — React frontend (static)
│   ├── diagram/            # Diagram app   — Node backend + React frontend
│   └── maxterview/         # Maxterview    — FastAPI backend + React frontend
│       ├── base/           #   env-neutral: Deployments, Services, Ingress, PreSync migrate Job
│       └── overlays/prod/
├── infra/
│   └── cloudflared.yaml    # Cloudflare Tunnel client (QUIC)
├── app.yaml                # ArgoCD root Application — applied by Terraform
├── kustomization.yaml      # Aggregates the Apps-of-Apps children (for `kubectl kustomize .` preview)
├── flake.nix               # Nix flake for dev shell (kubectl, argocd)
├── .envrc                  # direnv: loads flake + sets KUBECONFIG
└── README.md
```

## Ingress

| Domain                    | /api →                      | / →                            |
| ------------------------- | --------------------------- | ------------------------------ |
| `portfolio.seekeru.tech`  | _(no API route)_            | `portfolio-prod-frontend:8080` |
| `diagram.seekeru.tech`    | `diagram-prod-backend:3100` | `diagram-prod-frontend:8080`   |
| `maxterview.seekeru.tech` | `maxterview-backend:8000`   | `maxterview-frontend:8080`     |

Backend refs are namespace-local, so every app's Ingress lives in the app's own path beside its Service
(`apps/<app>/ingress.yaml`); `infra/` holds only the tunnel.

Namespaces: `portfolio`, `diagram`, `maxterview` — Terraform-created, one per app.
`default` is left to `cloudflared`.

maxterview renders from kustomize base + `overlays/prod`; the overlay patches namespace, host, env and image
tags, so a second env is a new overlay plus its own Terraform-created namespace + secrets (see the Terraform
repo's ADR 0003 for what that costs).

### Ingress annotations

- **CSP:** strict Content-Security-Policy allowing self, Cloudflare Insights, Google Fonts
- **CORS:** allows `seekeru.tech` and `*.seekeru.tech` origins
- **Rate limit:** 30 req/s, burst 20
- **Proxy timeouts:** connect 10s, send 30s, read 60s
- **Body size:** 10 MB max

## Secrets

All Kubernetes secrets are **created by the Terraform apply** (from Infisical values) —
not manually. The ones consumed by workloads in this repo:

- `cloudflared-token` (`default`) — Cloudflare Tunnel token.
- `ghcr-login` (`default`, `portfolio`, `diagram`, `maxterview`) — GHCR pull secret. **Namespace-local**:
  `imagePullSecrets` never cross namespaces and the GHCR packages are private, so each app namespace needs its
  own copy (`infra/k3s` creates every copy).
- `diagram-secrets` (`diagram`) — API key + PostgreSQL connection string.
- `maxterview-secrets` (`maxterview`) — Neon `DATABASE_URL` + Clerk/LLM/BYOK/PayMongo keys, injected wholesale
  with `envFrom`: **keys must be UPPERCASE env names** (`DATABASE_URL`, `CLERK_JWKS_URL`, `LLM_API_KEY`,
  `BYOK_ENCRYPTION_KEY`, `PAYMONGO_SECRET_KEY`, …) or the backend pod will not schedule. Created by the Terraform `k3s` module
  (commit `6727cf8`); the PayMongo pair now carries the live key + the prod `payment.paid` endpoint's secret.

Terraform also creates `repo-secret` (`argocd`) — the HTTPS credentials ArgoCD
uses to pull this git repo. It is not consumed by workloads but is required for ArgoCD
to sync.

Manage their values in Infisical and re-run `make apply MOD=k3s` in the
Terraform repo. Do **not** create them with `kubectl` — Terraform owns them.

## Image versions

Images are pinned to immutable SHA tags in each app's `kustomization.yaml` (never `latest`),
which enables exact rollback. As of writing:

| App        | Image                                    | Tag               |
| ---------- | ---------------------------------------- | ----------------- |
| portfolio  | `ghcr.io/notseekeru/portfolio-frontend`  | `00fe8ae…7952e`   |
| diagram    | `ghcr.io/notseekeru/diagram_backend`     | `3e30429…9ab6d09` |
| diagram    | `ghcr.io/notseekeru/diagram_frontend`    | `3e30429…9ab6d09` |
| maxterview | `ghcr.io/notseekeru/maxterview_backend`  | `71cf439…a5e29c`  |
| maxterview | `ghcr.io/notseekeru/maxterview_frontend` | `71cf439…a5e29c`  |

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

So a fresh cluster is bootstrapped entirely by `make apply MOD=k3s` in
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

## Kill switch (per app)

Each app's switch is its `resources:` list in `apps/<app>/kustomization.yaml`. Comment an
entry out, commit, and ArgoCD prunes it (`prune: true`); uncomment to bring it back:

```yaml
# Kill switch: comment an entry out to prune it (see README).
#- migration-job.yaml
resources:
  - backend.yaml
  - frontend.yaml
  - ingress.yaml
images: ...
```

Comment one entry to drop a single workload. Commenting out **every** entry kills the whole
app — but that needs one extra step, because the desired state is then empty and ArgoCD's
auto-sync refuses to act on it (see below).

### Killing a whole app needs one explicit sync

With every entry commented out, auto-sync skips the app and **nothing is pruned**. The
Application reports this in its conditions:

```
Skipping sync attempt to <rev>: auto-sync will wipe out all resources
```

That guard exists so a commit that renders nothing can't silently delete a workload. So the
kill is two steps and the restore is one:

```bash
# kill:   comment out all entries, commit, push, then one explicit sync
kubectl patch application <app> -n argocd --type merge -p \
  '{"operation":{"sync":{"revision":"HEAD","prune":true}}}'

# restore: uncomment, commit, push — auto-sync handles it (render is non-empty again)
```

Partial kills (any entry left uncommented) never hit the guard and stay single-step.

**Commenting entries out of the root `kustomization.yaml` does nothing.** That file is a
preview-only aggregator for `kubectl kustomize .`; `app.yaml` syncs the `apps-of-apps`
directory, not that kustomization. Only `apps/<app>/kustomization.yaml` counts.

A kill survives releases: the CD pipeline runs `kustomize edit set image` on exactly this
file, and it does not re-enable commented entries (verified against kustomize 5.8.1). It does
hoist them — on the next release, commented entries collect under the marker comment at the
top of the file. Expect that reflow. A fully dark app stays dark through image bumps too: with
no resources left there is nothing for a new revision to change.

Caveats:

- **A dark app reports `Healthy` in ArgoCD.** With its entries pruned the Application has
  nothing left to assess and stays green, so the switch has no visible state. Kill an app and
  forget, and nothing will tell you.
- **maxterview's kill still migrates Neon unless you also comment out `migration-job.yaml`.**
  It is a `PreSync` hook and hooks run on every sync, so the kill sync migrates the database
  first — and a failing hook fails the whole sync, meaning the kill never applies and the app
  stays up. Comment the hook out too for a clean kill, and restore it in the same commit as
  the pods so PreSync migrates before they roll.
- **Off means deleted, not scaled.** The Deployment, Service and (where applicable) Ingress are
  pruned: a dark app is absent from `kubectl get deploy`, indistinguishable at a glance from a
  botched delete, and a restore is a cold start — objects recreated, images pulled.
- **A dark app serves 404/503**, not a maintenance page: prune everything and the host no
  longer matches an ingress rule; prune only the backends and nginx has no endpoints.

Propagation is two hops — root app → child app → workloads — so allow a poll interval or two:
seconds if a git webhook is configured, otherwise up to ~6 min at the 3 min default poll.

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
kubectl get deploy -A                     # workloads (`default` = the tunnel only)
```

## Known trade-offs (accepted, not fixed)

- **Probes are `tcpSocket`**: readiness/liveness only verify the port accepts TCP, not that the app actually serves HTTP. The diagram backend (`:3100`) has no `/health` route, so HTTP probes are deferred. Upgrade path: add `/health` to the backend, then swap all three deployments to `httpGet` probes — the two frontends (nginx, serves `/`) can be switched immediately regardless.

- **CORS `*.seekeru.tech` + CSP `'unsafe-inline'`**: the loosest security knobs in the stack. Fine for a personal deployment; tighten to explicit origins and nonces/hashes before adding third-party scripts or broadening exposure.

- **Health-probe `failureThreshold` left at the Kubernetes default of 3** (deliberate): matches the minimal-resource posture; a hung app is tolerated ~30s before liveness restarts it.
