# gitops

ArgoCD Application managing the `portfolio.seekeru.tech` and `diagram.seekeru.tech` stack on Kubernetes.

## Prerequisites

- [Nix](https://nixos.org/download) with [flakes](https://nixos.wiki/wiki/Flakes) enabled
- [direnv](https://direnv.net/) (optional — auto-loads the shell)

```bash
direnv allow   # loads dev shell + exports KUBECONFIG
```

The dev shell installs `kubectl` and `argocd` via the [flake](./flake.nix).
The `.envrc` also exports `KUBECONFIG=$(pwd)/kubeconfig` — a local kubeconfig file
(see [.gitignore](./.gitignore)).

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
│   ├── ingress.yaml        # nginx Ingress routes, CSP/CORS/rate-limit annotations
│   └── cloudflared.yaml    # Cloudflare Tunnel client (QUIC)
├── app.yaml                # ArgoCD root Application (AppOfApps entry)
├── kustomization.yaml      # Root Kustomize — aggregates Applications for manual apply
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

```bash
# Cloudflare Tunnel
kubectl create secret generic cloudflared-token \
  --from-literal=token=$(cat ./credentials/.cloudflare-token.txt)

# GitHub Container Registry pull secret
kubectl create secret docker-registry ghcr-login \
  --docker-server=ghcr.io \
  --docker-username=notseekeru \
  --docker-password=$(cat ./credentials/.github-pat.txt)

# Diagram app secrets (API key + database URL)
kubectl create secret generic diagram-secrets \
  --from-literal=api_key="<api-key>" \
  --from-literal=database_url="postgresql://user:pass@<HOST>:25060/diagramdb?sslmode=require"
```

## Image versions

Image tags are pinned in each app's `kustomization.yaml`:

| App       | Image                                   |
| --------- | --------------------------------------- |
| portfolio | `ghcr.io/notseekeru/portfolio-frontend` |
| diagram   | `ghcr.io/notseekeru/diagram_backend`    |
| diagram   | `ghcr.io/notseekeru/diagram_frontend`   |

## Manual Apply

Applications are AppOfApps: the root app creates child Applications, and each child
syncs its own path (apps/portfolio, apps/diagram, infra) with prune + self-heal.

```bash
# Install/update the ArgoCD Application objects (children).
kubectl kustomize . | kubectl apply -f -

# Workloads are created by ArgoCD when each child syncs — don't apply them
# directly or selfHeal will fight your changes.
```

## ArgoCD Manual Sync

Auto-sync (prune + self-heal) is on, but you can force:

```bash
# Root (AppOfApps) — parent of portfolio, diagram, infra
argocd app sync gitops
argocd app sync gitops --prune
argocd app sync gitops --force

# Individual apps sync independently
argocd app sync portfolio
argocd app sync diagram
argocd app sync infra
```

### Sync Status

The parent `gitops` app shows **`Unknown` sync / Healthy health** — this is normal for an
AppOfApps: ArgoCD doesn't compare child `Application` objects the way it does workloads, so
the parent is never "Synced". Track the children instead:

```bash
kubectl get applications -n argocd     # diagram | gitops | infra | portfolio
argocd app get portfolio                   # per-app status + health (needs argocd CLI)
```

### Notes

- The `argocd` CLI is listed in `flake.nix` but needs the dev shell loaded to be on PATH.
  `direnv allow` then `argocd ...`, or drive syncs from `kubectl` (see below).
- To trigger a sync without the CLI, patch the operation annotation:

```bash
kubectl patch application gitops -n argocd --type merge -p \
  '{"metadata":{"annotations":{"argocd.argoproj.io/operation":"{\"sync\":{\"revision\":\"HEAD\",\"prune\":true,\"dryRun\":false,\"force\":false},\"syncOperationResult\":{}}"}}}'
```

## Known trade-offs (accepted, not fixed)

- **Probes are `tcpSocket`**: readiness/liveness only verify the port accepts TCP, not that the app actually serves HTTP. The diagram backend (`:3100`) has no `/health` route, so HTTP probes are deferred. Upgrade path: add `/health` to the backend, then swap all three deployments to `httpGet` probes — the two frontends (nginx, serves `/`) can be switched immediately regardless.

- **CORS `*.seekeru.tech` + CSP `'unsafe-inline'`**: the loosest security knobs in the stack. Fine for a personal deployment; tighten to explicit origins and nonces/hashes before adding third-party scripts or broadening exposure.

- **Health-probe `failureThreshold` left at the Kubernetes default of 3** (deliberate): matches the minimal-resource posture; a hung app is tolerated ~30s before liveness restarts it.
