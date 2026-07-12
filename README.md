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
├── apps/
│   ├── portfolio/          # Portfolio app — React frontend (static)
│   └── diagram/            # Diagram app   — Node backend + React frontend
├── infra/
│   ├── ingress.yaml        # nginx Ingress routes, CSP/CORS/rate-limit annotations
│   └── cloudflared.yaml    # Cloudflare Tunnel client (QUIC)
├── app.yaml                # ArgoCD Application (root, auto-sync, prune+selfHeal)
├── kustomization.yaml      # Root Kustomize — aggregates apps/ + infra/
├── flake.nix               # Nix flake for dev shell (kubectl, argocd)
├── .envrc                  # direnv: loads flake + sets KUBECONFIG
└── README.md
```

## Ingress

| Domain                   | /api →                       | / →                            |
| ------------------------ | ---------------------------- | ------------------------------ |
| `portfolio.seekeru.tech` | _(no API route)_             | `portfolio-prod-frontend:8080` |
| `diagram.seekeru.tech`   | `diagram-prod-backend:5050`  | `diagram-prod-frontend:8080`   |

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

| App         | Image                                      |
| ----------- | ------------------------------------------ |
| portfolio   | `ghcr.io/notseekeru/portfolio-frontend`    |
| diagram     | `ghcr.io/notseekeru/diagram_backend`       |
| diagram     | `ghcr.io/notseekeru/diagram_frontend`      |

## Manual Apply

ArgoCD auto-syncs (prune + self-heal). To apply outside of ArgoCD:

```bash
# Full stack (apps + infra)
kubectl kustomize . | kubectl apply -f -

# Single app
kubectl kustomize apps/diagram    | kubectl apply -f -
kubectl kustomize apps/portfolio  | kubectl apply -f -

# Infra only (ingress + cloudflared)
kubectl kustomize infra           | kubectl apply -f -
```

## ArgoCD Manual Sync

Auto-sync (prune + self-heal) is on, but you can force:

```bash
argocd app sync gitops               # standard sync
argocd app sync gitops --prune       # with prune
argocd app sync gitops --force       # hard refresh
```

### Sync Status

```bash
argocd app get gitops           # status + health
argocd app wait gitops --health # block until healthy
```
