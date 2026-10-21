# gitops

This repo holds the GitOps content for the `portfolio.seekeru.tech`, `diagram.seekeru.tech` and `maxterview.seekeru.tech` stack on Kubernetes. It is **not** the installer: cluster bootstrap, the root Application, Kubernetes secrets, and the kubeconfig are all provisioned by Terraform (see the separate `terraform` repo).

The repo uses ArgoCD **App of Apps**:

- `apps-of-apps/`: the **ArgoCD Application objects** (children) telling ArgoCD which workload paths to sync.
- `apps/`: the **workloads** (Deployments, Services) for each app.
- `infra/`: shared cluster resources (ingress, Cloudflare tunnel).
- `app.yaml`: the **root Application** (parent). Applied by Terraform, not by hand.

**Deploy model:** push commits to `main`; ArgoCD watches this repo and each child Application syncs its own path with `prune` + `selfHeal`. Never apply workloads by hand; that fights `selfHeal`.

## Prerequisites

The only hard requirement is `kubectl` pointed at the cluster Terraform provisioned.
`direnv allow` is optional: it loads the flake dev shell and sets `KUBECONFIG=~/kubeconfig`, the path Terraform writes.

## Ingress

Namespaces: `portfolio`, `diagram`, `maxterview`, Terraform-created, one per app.
`default` is left to `cloudflared`.

Backend refs are namespace-local, so every app's Ingress lives in the app's own path beside its Service; `infra/` holds only the tunnel.

## Secrets

All Kubernetes secrets are **created by the Terraform apply** (from Infisical values):
not manually. Do **not** create them with `kubectl`; Terraform owns them.
Manage their values in Infisical and re-run `make apply MOD=k3s` in the Terraform repo.

- `ghcr-login`: **Namespace-local**: `imagePullSecrets` never cross namespaces and the GHCR packages are private, so each app namespace needs its own copy (`infra/k3s` creates every copy).
- `maxterview-secrets`: injected wholesale with `envFrom`, so **keys must be UPPERCASE env names** or the backend pod will not schedule.
- `maxterview-owner-secrets`: the owner Neon DSN, mounted only by the PreSync migration Job so the backend pod never holds a credential that can `DROP`.
- `repo-secret` (`argocd`): the HTTPS credentials ArgoCD uses to pull this git repo. Terraform creates it, and ArgoCD cannot sync without it.

## Images

Images are pinned to immutable SHA tags in each app's `kustomization.yaml` (never `latest`),
which enables exact rollback. **All image tags auto-update via the CD pipeline** (CI → `workflow_run` on `main`):
for each service in the CD matrix it builds the image, then a job runs `kustomize edit set image` on
the owning `apps/<app>/kustomization.yaml` and pushes the SHA bump.

## How this repo gets applied

This repo is **not** applied by hand. The Terraform repo is the installer:

1. Terraform installs ArgoCD (Helm chart), creates the Kubernetes secrets, then applies
   `app.yaml`, the root Application, via the `kubectl` provider (`kubectl_manifest`,
   path default `${path.module}/../../../gitops/app.yaml`).
2. That root Application (App of Apps) creates the children in `apps-of-apps/`, each of
   which auto-syncs its own workload path (`apps/`, `infra/`) with `prune` + `selfHeal`.

So a fresh cluster is bootstrapped entirely by `make apply MOD=k3s` in
the Terraform repo. This repo's only job is to hold the YAML ArgoCD syncs.

> **Never** `kubectl apply` `app.yaml`, the secrets, or files under `apps/`/`infra/` directly:
> Terraform owns the root app and secrets; ArgoCD `selfHeal` owns the workload manifests. Either
> would fight the other and reconcile your changes away.

## Deploy workflow (normal operation)

1. Push changes to `main`: either a code PR that triggers the CD pipeline, or a direct edit
   to a manifest/kustomization.
2. ArgoCD's app controller picks up the new revision and auto-syncs each affected child
   (auto-sync: `prune` + `selfHeal` are on for every Application, root and children).
3. `kubectl get applications -n argocd` to observe status.

You generally never need to touch ArgoCD manually. Forcing a sync outside git is only for
recovery or poking ArgoCD's cached state.

## Kill switch (per app)

Each app's switch is its `resources:` list in `apps/<app>/kustomization.yaml`. Comment an
entry out, commit, and ArgoCD prunes it (`prune: true`); uncomment to bring it back.

Comment one entry to drop a single workload. Commenting out **every** entry kills the whole
app, but that needs one extra step, because the desired state is then empty and ArgoCD's
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

# restore: uncomment, commit, push, auto-sync handles it (render is non-empty again)
```

Partial kills (any entry left uncommented) never hit the guard and stay single-step.

**Commenting entries out of the root `kustomization.yaml` does nothing.** That file is a
preview-only aggregator for `kubectl kustomize .`; `app.yaml` syncs the `apps-of-apps`
directory, not that kustomization. Only `apps/<app>/kustomization.yaml` counts.

A kill survives releases: the CD pipeline runs `kustomize edit set image` on exactly this
file, and it does not re-enable commented entries. It does hoist them: on the next release,
commented entries collect under the marker comment at the top of the file. Expect that reflow.
A fully dark app stays dark through image bumps too: with no resources left there is nothing
for a new revision to change.

Caveats:

- **A dark app reports `Healthy` in ArgoCD.** With its entries pruned the Application has
  nothing left to assess and stays green, so the switch has no visible state. Kill an app and
  forget, and nothing will tell you.
- **maxterview's kill still migrates Neon unless you also comment out `migration-job.yaml`.**
  It is a `PreSync` hook and hooks run on every sync, so the kill sync migrates the database
  first, and a failing hook fails the whole sync, meaning the kill never applies and the app
  stays up. Comment the hook out too for a clean kill, and restore it in the same commit as
  the pods so PreSync migrates before they roll.
- **Off means deleted, not scaled.** The Deployment, Service and (where applicable) Ingress are
  pruned: a dark app is absent from `kubectl get deploy`, indistinguishable at a glance from a
  botched delete, and a restore is a cold start: objects recreated, images pulled.
- **A dark app serves 404/503**, not a maintenance page: prune everything and the host no
  longer matches an ingress rule; prune only the backends and nginx has no endpoints.

Propagation is two hops (root app → child app → workloads), so allow a poll interval or two:
seconds if a git webhook is configured, otherwise up to ~6 min at the 3 min default poll.

---

## Port-Forward

```bash
PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d) && echo -e "\n---> Local Login: https://localhost:8080\n---> Network Login: https://<YOUR_COMPUTER_IP>:8080\n---> Username: admin\n---> Password: $PASS\n" && kubectl port-forward svc/argocd-server -n argocd --address 0.0.0.0 8080:443
```

---

## Forcing a sync (outside of git)

Auto-sync applies every change pushed to `main`, so this is for a stuck controller or a manual
rollback. Two different operations, and only one works from `kubectl`.

A refresh re-reads the repo and redoes the comparison:

```bash
kubectl annotate application maxterview -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

```bash
# From the flake dev shell, after `argocd login`
argocd app sync maxterview

# The same call over HTTP
curl -X POST -H "Authorization: Bearer $ARGOCD_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"maxterview"}' "$ARGOCD_URL/api/v1/applications/maxterview/sync"
```

A hook-only change never starts a sync: ArgoCD leaves hook resources out of the comparison, so
editing `migration-job.yaml` alone keeps the app `Synced` and the PreSync job unrun until the next
real sync, such as an image bump. Force one when the hook itself changed.

### Sync status

The parent `gitops` app reports **`Unknown` sync / `Healthy` health**: expected for
AppOfApps: ArgoCD doesn't compare child `Application` objects the way it does workloads,
so the parent never reads as "Synced". Judge deployment state by the children:

```bash
kubectl get applications -n argocd        # one row per app
kubectl get deploy -A                     # workloads (`default` = the tunnel only)
```

## Known trade-offs (accepted, not fixed)

- **Probes are `tcpSocket`**: readiness/liveness only verify the port accepts TCP, not that the app actually serves HTTP. The diagram backend (`:3100`) has no `/health` route, so HTTP probes are deferred. Upgrade path: add `/health` to the backend, then swap all three deployments to `httpGet` probes, the two frontends (nginx, serves `/`) can be switched immediately regardless.

- **CORS `*.seekeru.tech` + CSP `'unsafe-inline'`**: the loosest security knobs in the stack. Fine for a personal deployment; tighten to explicit origins and nonces/hashes before adding third-party scripts or broadening exposure.

- **Health-probe `failureThreshold` left at the Kubernetes default of 3** (deliberate): matches the minimal-resource posture; a hung app is tolerated ~30s before liveness restarts it.
