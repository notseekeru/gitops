# gitops

ArgoCD Application managing the portfolio.seekeru.tech stack on Kubernetes.

## Layout

| File               | Description                                                    |
| ------------------ | -------------------------------------------------------------- |
| `app.yml`          | ArgoCD Application (root)                                      |
| `backend.yaml`     | Backend Deployment + Service (`portfolio-prod-backend:5000`)   |
| `frontend.yaml`    | Frontend Deployment + Service (`portfolio-prod-frontend:8080`) |
| `cloudflared.yaml` | Cloudflare Tunnel client                                       |
| `ingress.yaml`     | ingress-nginx Ingress (routes, rate limits, security headers)  |

## Ingress

Routes `portfolio.seekeru.tech` to the backend and frontend services with
rate limiting and security headers — no custom nginx config needed.

```bash
# Temporary kubeconfig for kubectl access
export KUBECONFIG=~/kubeconfig

# Or Permanently add to bashrc
echo "export KUBECONFIG=~/kubeconfig" >> ~/.bashrc && source ~/.bashrc

# Install ingress-nginx
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/cloud/deploy.yaml

# Apply this repo
kubectl apply -f ingress.yaml -f backend.yaml -f frontend.yaml -f cloudflared.yaml
```

### Secrets

```bash
# Create Kubernetes secret for Cloudflare Tunnel token
kubectl create secret generic cloudflared-token --from-literal=token=$(cat ./credentials/.cloudflare-token.txt)

# Create Kubernetes secret for GitHub Container Registry (GHCR) authentication
kubectl create secret docker-registry ghcr-login \
         --docker-server=ghcr.io \
         --docker-username=$(cat ./credentials/.github-username.txt) \
         --docker-password=$(cat ./credentials/.github-pat.txt)
```

This replaces the old custom nginx Deployment, ConfigMap, Kustomize, and config files.
