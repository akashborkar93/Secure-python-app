# Secure Python Demo App on AWS (EKS + Helm + Argo CD + Prometheus/Grafana)

A small Python web app deployed on AWS with a production-style setup:
CI/CD, containers, Kubernetes, GitOps, and monitoring. It is a **demo project**
built to be read and understood by beginners, so every file is commented.

> Full design: see [MASTER-PLAN.md](MASTER-PLAN.md).

---

## 1. What are we building? (plain English)

| Piece | What it is | Why we use it |
|---|---|---|
| Python app | A tiny web service with health and metrics endpoints | The thing we deploy |
| Docker | Packs the app into a portable image | Runs the same everywhere |
| ECR | AWS storage for Docker images | Kubernetes pulls images from here |
| EKS | AWS-managed Kubernetes | Runs and scales the app |
| Terraform | Describes AWS resources as code | Repeatable, reviewable infrastructure |
| Helm | Packages Kubernetes manifests with settings | One chart, many environments (dev/prod) |
| GitHub Actions | CI: test, scan, build and push the image | Automates quality and delivery |
| Argo CD | CD: keeps the cluster matching what is in Git (GitOps) | Safe, auditable deploys |
| Gateway API (Envoy Gateway) | Routes internet traffic to the app | Modern replacement for Ingress |
| Prometheus + Grafana | Collect metrics and show dashboards | See app and cluster health |

## 2. Key decisions

- Region: **us-east-1 only**
- Domain: `akashcloud.online` (DNS delegated to Route53 by the owner)
- One cluster, two namespaces: `dev` and `prod`
- No WAF at this stage
- Budget: **about $2-5 total**, so we work in two stages (below)

## 3. Two-stage approach (to keep cost minimal)

- **Stage A (nearly free):** build and test everything on one EC2 instance
  (`t3.medium`, Ubuntu 24.04) using a small local Kubernetes (k3s). We stop the
  instance when not working.
- **Stage B (a few dollars):** create the real EKS cluster for a few hours with
  Terraform, demo it, then run `terraform destroy`.

## 4. Planned repository layout

```
app/                  Python source, tests, Dockerfile
charts/demo-app/      Helm chart for the app
platform/             Settings for add-ons (Argo CD, Envoy Gateway, Prometheus...)
infra/                Terraform code (VPC, ECR, EKS)
gitops/               Argo CD Application definitions
.github/workflows/    CI pipelines
docs/                 Extra notes and runbooks
```

## 5. Conventions (please keep following these)

1. Every file explains itself with plain-language comments.
2. Prefer simple, explicit code over clever tricks.
3. **Every action is added to the Action Log below** (what, why, command, result).

---

## 6. Action Log

Newest entries go at the bottom. Each entry: what we did, why, the command, the result.

### 2026-11-22: Planning
- Wrote the master plan in `MASTER-PLAN.md` (architecture, phases, security/HA/scale mapping, cost notes).
- Decisions confirmed: Terraform, GitHub Actions, Argo CD, one cluster with dev/prod namespaces,
  domain `akashcloud.online`, self-hosted Prometheus/Grafana, Gateway API (Envoy Gateway + NLB), no WAF,
  region us-east-1, alerts by email.
- Chose the two-stage low-cost approach (Stage A on EC2 with k3s, Stage B short EKS burst).

### 2026-11-22: Step 0, AWS access check (BLOCKED)
- Command: `aws sts get-caller-identity`
- Result: `InvalidClientTokenId`. The access key stored on the local machine is invalid.
- Next action: owner creates a new IAM access key and runs `aws configure` (region `us-east-1`),
  then we re-check. Secrets are never pasted into chat or committed to Git.

### 2026-11-22: Step 0, AWS access fixed
- Owner created a new IAM access key and ran `aws configure` in their own terminal
  (this session cannot answer interactive prompts).
- Verified: `aws sts get-caller-identity` returned account `<ACCOUNT_ID>`, user `skycloud`
  (policy: `AdministratorAccess`). Default VPC exists in us-east-1.

### 2026-11-22: Step 0b, Budget alert
- Why: protect the $2-5 cost ceiling.
- Created a monthly budget `demo-project-5usd` ($5) with email alerts to the owner at
  50% actual, 80% actual and 100% forecast. Files: `scripts/budget.json`, `scripts/budget-notifications.json`.
- Command: `aws budgets create-budget --account-id <ACCOUNT_ID> --budget file://scripts/budget.json --notifications-with-subscribers file://scripts/budget-notifications.json`
- Result: budget listed with limit 5.0.

### 2026-11-22: Step 1, Created the EC2 workstation (Stage A)
- Script: `scripts/01-create-ec2.ps1` (fully commented; read it to see each step).
- Created: SSH key pair `demo-key` (private key saved locally at `~/.ssh/demo-key.pem`),
  security group `demo-workstation-sg` (SSH only from owner's IP), IAM role/instance profile
  `demo-workstation-role` / `demo-workstation-profile` (AdministratorAccess, demo only, remove at the end),
  and EC2 instance `i-0f2b0cfadcc7dd530` (t3.medium, Ubuntu 24.04, 20 GB gp3, IMDSv2 required).
- Public IP: `54.88.96.129` (this changes if the instance is stopped and started).
- Verified: `ssh -i ~/.ssh/demo-key.pem ubuntu@54.88.96.129` works; 3.7 GB RAM, 17 GB free disk.
- Cost note: about $0.04/hour while running. **Stop the instance when not working:**
  `aws ec2 stop-instances --region us-east-1 --instance-ids i-0f2b0cfadcc7dd530`
- Note: the owner's home IP may change; if SSH stops working, update the security group rule.

### 2026-11-22: Step 2, Installed tools on the EC2 workstation
- Script: `scripts/02-install-tools.sh` (commented). Copied to the server with `scp` and run over SSH.
- Installed: git 2.43, Docker 29.10, AWS CLI 2.42, Terraform 1.17.2, kubectl 1.37.2, Helm 3.22.1,
  and **k3s v1.37.2** (single-node Kubernetes, Traefik disabled because we will use Envoy Gateway).
- Added a 2 GB swap file so the 4 GB server has headroom for Prometheus/Grafana/Argo CD.
- Issue found and fixed: the script first installed kubectl 1.31, which is too old for k3s 1.37
  (kubectl should be within one minor version of the cluster). Switched the repo to `v1.37` and reinstalled.
- Verified: `kubectl get nodes` shows the node `Ready`; system pods (coredns, metrics-server,
  local-path-provisioner) are running. k3s also pre-installed the Gateway API CRDs (`helm-install-gateway-api-crd` job).
- Kubeconfig on the server: `~/.kube/config` (exported through `~/.bashrc`).

### 2026-11-22: Step 3, Python app + Docker image
- Created `app/` (all files commented for beginners):
  - `main.py`: FastAPI app with `/`, `/healthz` (liveness), `/readyz` (readiness), `/metrics` (Prometheus).
    Settings come from env vars `APP_ENV` and `APP_VERSION`.
  - `tests/test_main.py` + `pytest.ini`: 4 automated tests.
  - `requirements.txt` (runtime) and `requirements-dev.txt` (tests/lint), versions pinned.
  - `Dockerfile`: multi-stage build, `python:3.12-slim`, runs as non-root user (UID 10001).
  - `.dockerignore`: keeps tests and junk out of the image.
- Ran on the server (files copied with `tar` + `scp`, work folder `~/work/app`):
  - `pytest -q` -> 4 passed. `ruff check .` -> all checks passed.
  - `docker build -t demo-app:local .` -> success, image size 251 MB.
  - `docker run -p 8000:8000 demo-app:local` and `curl` on all four endpoints -> all correct,
    the metrics counter increased per request.
  - `docker exec ... id` -> `uid=10001(appuser)`, so the container does NOT run as root.
- The image exists only on the server for now. Later it is pushed to ECR by CI.
- Try it yourself on the server: `sudo docker run --rm -p 8000:8000 demo-app:local` then `curl localhost:8000/`.

### 2026-11-22: Step 4, Helm chart deployed to dev and prod (on k3s)
- Created `platform/namespaces.yaml`: namespaces `dev` and `prod` (Pod Security `restricted`
  enforced, a ResourceQuota each, and a `gateway-access` label for the Gateway later).
- Created the chart `charts/demo-app/` (every file commented):
  - `values.yaml` (defaults), `values-dev.yaml` (1-2 pods), `values-prod.yaml` (2-4 pods + PDB).
  - Templates: `deployment.yaml` (rolling update with zero unavailable, 3 probes, non-root, read-only
    filesystem, all capabilities dropped, zone/node spreading), `service.yaml`, `hpa.yaml` (CPU 70%),
    `pdb.yaml` (prod only), `networkpolicy.yaml` (only `envoy-gateway-system` and `monitoring` namespaces
    and same-namespace pods may reach the app), `serviceaccount.yaml`, `_helpers.tpl`, `NOTES.txt`.
- On the server: `helm lint` passed. The image was loaded into k3s with
  `docker save demo-app:local | sudo k3s ctr images import -` (no registry yet).
  Installed with `helm upgrade --install demo-app charts/demo-app -n <dev|prod> -f charts/demo-app/values-<env>.yaml`.
- Verified: dev has 1 pod, prod has 2 pods, all Running. `port-forward` + `curl` returned
  `"environment":"dev"` and `"environment":"prod"` correctly. HPAs read CPU (4% of 70% target).
  The prod pod runs as `uid=10001`, and a write to `/app` is refused.
- Not yet included (added when their controllers are installed): HTTPRoute (Gateway API) and ServiceMonitor (Prometheus).
- Useful commands on the server: `kubectl get pods -n dev`, `helm list -A`,
  `kubectl port-forward -n prod svc/demo-app 8080:80` then `curl localhost:8080/`.
- Note: the prod PodDisruptionBudget, NetworkPolicy and the HPA are in place, but k3s has one node, so
  true multi-node/multi-AZ spreading is only demonstrated in Stage B on EKS.

### 2026-11-22: Step 5, Gateway API with Envoy Gateway (on k3s)
- Created (all commented): `scripts/05-install-envoy-gateway.sh`, `platform/envoy-gateway-values.yaml`,
  `platform/gateway.yaml` (GatewayClass `envoy` + Gateway `shared-gateway` in `envoy-gateway-system`,
  HTTP port 80, only namespaces labelled `gateway-access=true` may attach routes),
  and the chart template `charts/demo-app/templates/httproute.yaml` (+ `httpRoute` values:
  `dev.akashcloud.online` for dev, `app.akashcloud.online` for prod).
- Installed Envoy Gateway **v1.10.0** with Helm into `envoy-gateway-system`.
- Issue 1: k3s already installs the Gateway API CRDs (v1.6.3), so we install only Envoy Gateway's own
  CRDs and run the controller with `crds.enabled=false` to avoid a clash.
- Issue 2: `helm install` of the Envoy CRDs chart failed with `Secret ... Too long: may not be more than
  1048576 bytes` (Helm stores releases in a 1 MB Secret). Fix: `helm template ... | kubectl apply --server-side -f -`.
- Verified: GatewayClass `Accepted=True`, Gateway `Programmed=True` (address = node IP, via k3s ServiceLB).
  Both HTTPRoutes are `Accepted` and `ResolvedRefs`. From the server:
  `curl -H "Host: dev.akashcloud.online" localhost/` returns `"environment":"dev"`,
  `curl -H "Host: app.akashcloud.online" localhost/` returns `"environment":"prod"`,
  an unknown host returns HTTP 404.
- Not tested here: HTTPS/TLS and public DNS (they need Route53 + cert-manager, done in Stage B on EKS),
  and a clean load-balancing proof (pod request counters also include health probes).
- Editor note: red YAML errors on files in `charts/*/templates/` are false alarms; they contain `{{ }}`
  Helm placeholders. Use `helm lint` / `helm template` to validate them.
- Try it yourself on the server: `kubectl get gateway,httproute -A` and
  `curl -H "Host: app.akashcloud.online" localhost/`.

### 2026-11-22: Step 6, Observability: Prometheus + Alertmanager + Grafana (on k3s)
- Created (all commented): `scripts/06-install-monitoring.sh`, `platform/monitoring-values.yaml`
  (small sizes, 2-day retention, k3s-only scrape exclusions), `platform/grafana-httproute.yaml`
  (`grafana.akashcloud.online`), `platform/dashboards/demo-app.json` (Grafana dashboard: request rate,
  5xx errors, p95 latency, pods running, CPU per pod), and the chart template
  `charts/demo-app/templates/monitoring.yaml` (ServiceMonitor + 4 alerts: DemoAppDown,
  DemoAppHighErrorRate, DemoAppHighLatency, DemoAppAtMaxReplicas).
- Installed `kube-prometheus-stack` **93.7.0** into namespace `monitoring`. Grafana admin password is random:
  stored in Kubernetes Secret `grafana-admin` and in `~/.grafana-admin-password` on the server (mode 600,
  never in Git). Read it with `cat ~/.grafana-admin-password`. User name: `admin`.
- Issue 1: first install hit my 10-minute tool timeout, leaving the Helm release `failed`. Re-running
  `helm upgrade --install` fixed it. Lesson: run long installs on the server with `nohup` and read the log.
- Issue 2: Grafana kept restarting (liveness probe killed it because it needs over a minute to boot on this
  small server). Fix: more patient probes (`initialDelaySeconds: 120`, `failureThreshold: 10`) and memory
  limit raised from 256Mi to 384Mi in `platform/monitoring-values.yaml`.
- Upgraded both app releases (dev revision 4, prod revision 3) so they create their ServiceMonitor and alerts.
- Verified: all 3 app pods (1 dev + 2 prod) are `up=1` in Prometheus; the 4 alert rules are loaded and
  `inactive` (healthy); only the built-in `Watchdog` alert fires (it is meant to always fire);
  Grafana `/api/health` is OK, the "Demo App - Overview" dashboard is loaded, and Grafana answers
  through the Gateway (`Host: grafana.akashcloud.online` -> HTTP 200).
- Not verified: the dashboard panels were not viewed in a browser, and the request-rate query returned 0
  because my traffic burst finished before Prometheus's first scrape. Send traffic and watch the panels yourself.
- Alert email is NOT set up yet (Alertmanager uses a "null" receiver). Needs SMTP (Amazon SES), done in Stage B.
- Memory: about 1 GB left of 3.8 GB, so the server is getting full. Argo CD (Step 7) will be tight.
- See Grafana from your PC: `ssh -i ~/.ssh/demo-key.pem -L 3000:localhost:3000 ubuntu@<ip>` then on the server
  `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80`, and open http://localhost:3000.

<!-- New log entries are appended below this line. -->
