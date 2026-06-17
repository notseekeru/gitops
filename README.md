# gitops

ArgoCD Application managing Kubernetes resources for portfolio.seekeru.tech.

## Layout

| File | Description |
|------|-------------|
| `app.yml` | ArgoCD Application (root) |
| `backend.yaml` | Backend Deployment + Service (`portfolio-prod-backend:5000`) |
| `frontend.yaml` | Frontend Deployment + Service (`portfolio-prod-frontend:8080`) |
| `cloudflared.yaml` | Cloudflare Tunnel client |
| `nginx/` | Nginx config + Kustomize |

## Nginx

```bash
# Apply the nginx ConfigMap + Deployment via Kustomize
kubectl apply -k nginx/
```

The Dockerfile in `nginx/config/` builds a self-contained image with configs baked in
(for local dev / non-K8s deployments).
