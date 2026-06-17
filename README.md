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
# Install ingress-nginx (one-time per cluster)
export KUBECONFIG=~/terraform/kubeconfig

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/cloud/deploy.yaml

# Apply this repo
kubectl apply -f ingress.yaml -f backend.yaml -f frontend.yaml -f cloudflared.yaml
```

## Cloudflare real-IP

After installing ingress-nginx, patch its ConfigMap so it trusts Cloudflare IPs:

```bash
kubectl patch configmap -n ingress-nginx ingress-nginx-controller \
  --set-data 'use-forwarded-headers=true' \
  --set-data 'forwarded-for-header=CF-Connecting-IP' \
  --set-data 'compute-full-forwarded-for=true'
```

This replaces the old custom nginx Deployment, ConfigMap, Kustomize, and config files.
