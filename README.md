# gitops

ArgoCD Application managing the portfolio.seekeru.tech and diagram.seekeru.tech stack on Kubernetes.

## Layout

```
├── apps/
│   ├── portfolio/          # Portfolio app (backend + frontend)
│   └── crud/               # CRUD app — Node + React + Postgres
├── infra/
│   ├── ingress.yaml        # Routes for both domains
│   ├── cloudflared.yaml    # Cloudflare Tunnel client
│   └── db.yaml             # DO Managed Postgres ExternalName service
├── app.yaml                # ArgoCD Application (root)
├── kustomization.yaml      # Root Kustomize — aggregates all resources
└── README.md
```

## Ingress

| Domain                   | /api →                 | / →                     |
| ------------------------ | ---------------------- | ----------------------- |
| `portfolio.seekeru.tech` | portfolio-backend:5000 | portfolio-frontend:8080 |
| `diagram.seekeru.tech`   | crud-backend:4000      | crud-frontend:3000      |

## Apply

ArgoCD auto-syncs from this repo. For manual apply:

```bash
kubectl kustomize . | kubectl apply -f -
```

Or per-app:

```bash
kubectl kustomize apps/crud | kubectl apply -f -
```

### Initial Secrets

```bash
# Cloudflare Tunnel
kubectl create secret generic cloudflared-token \
  --from-literal=token=$(cat ./credentials/.cloudflare-token.txt)

# GitHub Container Registry pull secret
kubectl create secret docker-registry ghcr-login \
  --docker-server=ghcr.io \
  --docker-username=$(cat ./credentials/.github-username.txt) \
  --docker-password=$(cat ./credentials/.github-pat.txt)

# DO Managed Postgres connection string (update host + creds)
kubectl create secret generic db-credentials \
  --from-literal=database-url="postgresql://user:pass@<HOST>:25060/cruddb?sslmode=require"
```
