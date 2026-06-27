# gitops

ArgoCD Application managing the `portfolio.seekeru.tech` and `diagram.seekeru.tech` stack on Kubernetes.

## Layout

```
├── apps/
│   ├── portfolio/          # Portfolio app — Node backend + React frontend
│   └── diagram/            # Diagram app   — Node backend + React frontend
├── infra/
│   ├── ingress.yaml        # nginx Ingress routes for both domains
│   └── cloudflared.yaml    # Cloudflare Tunnel client (QUIC)
├── app.yaml                # ArgoCD Application (root, auto-sync)
├── kustomization.yaml      # Root Kustomize — aggregates all resources
└── README.md
```

## Ingress

| Domain                   | /api →                       | / →                          |
| ------------------------ | ---------------------------- | ---------------------------- |
| `portfolio.seekeru.tech` | `portfolio-prod-backend:5000`| `portfolio-prod-frontend:8080`|
| `diagram.seekeru.tech`   | `diagram-prod-backend:5050`  | `diagram-prod-frontend:8080` |

## Secrets

```bash
# Cloudflare Tunnel
kubectl create secret generic cloudflared-token \
  --from-literal=token=$(cat ./credentials/.cloudflare-token.txt)

# GitHub Container Registry pull secret
kubectl create secret docker-registry ghcr-login \
  --docker-server=ghcr.io \
  --docker-username=$(cat ./credentials/.github-username.txt) \
  --docker-password=$(cat ./credentials/.github-pat.txt)

# Diagram app secrets (API key + database URL)
kubectl create secret generic diagram-secrets \
  --from-literal=api_key="<api-key>" \
  --from-literal=database_url="postgresql://user:pass@<HOST>:25060/diagramdb?sslmode=require"
```

## Manual Apply

ArgoCD auto-syncs from this repo (`.spec.syncPolicy.automated`). To apply
outside of ArgoCD:

```bash
# Full stack
kubectl kustomize . | kubectl apply -f -

# Single app
kubectl kustomize apps/diagram    | kubectl apply -f -
kubectl kustomize apps/portfolio  | kubectl apply -f -

# Infra only (ingress + cloudflared)
kubectl kustomize infra           | kubectl apply -f -
```

## ArgoCD Manual Sync

If auto-sync is disabled or you need to force a sync:

```bash
# Via CLI
argocd app sync gitops

# Via CLI — with prune (removes resources deleted from repo)
argocd app sync gitops --prune

# Via CLI — hard refresh (re-fetch manifests, not just diff)
argocd app sync gitops --force

# Via CLI — sync a single app (if split per-app)
argocd app sync diagram-app

# Via Web UI
#   1. Open ArgoCD UI → Applications → gitops
#   2. Click REFRESH  (fetches latest from repo)
#   3. Click SYNC    (applies to cluster)
#   4. Tick Prune if needed → SYNCHRONIZE
```

### Sync Status

```bash
argocd app get gitops               # status + health
argocd app wait gitops --health     # block until healthy
```
