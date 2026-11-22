# Master Plan: Python Demo App on AWS (ECR + EKS + Helm + Prometheus/Grafana)

Goals: **Scalable**, **Highly Available**, **Secure**, **Observable**, fully automated via CI/CD and IaC.

---

## 1. Architecture Overview

```
Developer -> GitHub -> GitHub Actions (CI) -> ECR (image, scanned, signed)
                                  |
                                  v  (CI bumps image tag in GitOps path)
                           Argo CD (GitOps, in-cluster)
                                  |
   Route53 (akashcloud.online) -> NLB (AWS LB Controller)
                                  -> Envoy Gateway (Kubernetes Gateway API)
                                  -> HTTPRoute -> EKS (3 AZs)
                                  |                |- ns dev / ns prod: app pods (HPA, PDB)
                                  |                |- ns monitoring: kube-prometheus-stack
                                  |                |- Karpenter / Cluster Autoscaler
                                  v
                    Private subnets, NAT per AZ, VPC endpoints
```

**Confirmed decisions:** Terraform, GitHub Actions, Argo CD (from the start), one EKS cluster with `dev` and `prod` namespaces, domain `akashcloud.online`, self-hosted Prometheus + Grafana, Kubernetes Gateway API for ingress.

| Layer | Choice |
|---|---|
| Region/AZ | 1 region, 3 AZs |
| IaC | Terraform (S3 + DynamoDB state backend, or S3 native locking) |
| Registry | Amazon ECR (immutable tags, scan on push, lifecycle policy) |
| Cluster | EKS (managed control plane, managed node groups or Karpenter) |
| Packaging | Helm chart for the app; Helm for platform add-ons |
| CI/CD | GitHub Actions (CI) + Argo CD (CD, GitOps) |
| Observability | kube-prometheus-stack (Prometheus, Alertmanager, Grafana), self-hosted |
| Ingress | **Kubernetes Gateway API** via Envoy Gateway, fronted by NLB (AWS LB Controller) |
| DNS / TLS | Route53 zone `akashcloud.online`, ExternalDNS, cert-manager (Let's Encrypt DNS-01) |

---

## 2. Phased Roadmap

### Phase 0 – Foundations (Day 1–2)
- [ ] AWS account structure: separate `dev` / `prod` accounts (or at minimum separate clusters), AWS Organizations, SSO/IAM Identity Center.
- [ ] Enable CloudTrail, GuardDuty, AWS Config, billing alarms.
- [ ] Git repo layout (see §3). Branch protection, required reviews, signed commits.
- [ ] Terraform remote state bucket (versioned, encrypted) + locking.

### Phase 1 – Application (Day 2–3)
- [ ] Simple Python app (FastAPI/Flask): `/` , `/healthz` (liveness), `/readyz` (readiness), `/metrics` (prometheus_client).
- [ ] Unit tests (pytest), lint (ruff), type check (mypy optional).
- [ ] Dockerfile: multi-stage, slim/distroless base, non-root user, pinned versions, `.dockerignore`, read-only filesystem compatible, gunicorn/uvicorn with graceful shutdown.
- [ ] 12-factor config through env vars / ConfigMap / Secrets.

### Phase 2 – Infrastructure with Terraform (Day 3–5)
- [ ] **VPC**: 3 AZs, public subnets (ALB only), private subnets (nodes), one NAT GW per AZ, VPC endpoints (ECR api/dkr, S3, STS, CloudWatch Logs).
- [ ] **ECR**: immutable tags, scan on push, KMS encryption, lifecycle (keep last N).
- [ ] **EKS**: private+public (restricted CIDR) or fully private endpoint, secrets envelope encryption (KMS), control-plane logging, IRSA/Pod Identity, managed addons (VPC CNI, CoreDNS, kube-proxy, EBS CSI).
- [ ] **Nodes**: managed node groups spanning 3 AZs (min 3), or Karpenter for spot+on-demand mix. IMDSv2 enforced, encrypted EBS.
- [ ] **Platform add-ons** (bootstrap Argo CD with Terraform, then Argo manages the rest): AWS LB Controller, metrics-server, ExternalDNS, cert-manager, External Secrets Operator, Cluster Autoscaler/Karpenter, **Gateway API CRDs + Envoy Gateway** (see Phase 4a).
- [ ] Route53 hosted zone for `akashcloud.online` (update registrar nameservers to the zone's NS records).
- [ ] Remote state per environment; `terraform fmt/validate/plan` in CI; `tfsec`/`checkov` scanning.

### Phase 3 – CI Pipeline (Day 5–6) — GitHub Actions
Triggers: PR (validate) and push to `main` (build + deploy).

1. Checkout, set up Python, cache deps.
2. Lint + unit tests + coverage.
3. SAST (CodeQL/Bandit), dependency scan (pip-audit), secret scan (gitleaks).
4. Docker build (Buildx, cache) tagged with **git SHA** (never `latest`).
5. Image scan (Trivy) – fail on HIGH/CRITICAL.
6. Generate SBOM (Syft), sign image (cosign keyless).
7. Auth to AWS via **OIDC role** (no long-lived keys), push to ECR.
8. Helm `lint` + `template` + `kubeconform` + policy checks (conftest/Kyverno CLI).

### Phase 4 – Helm Chart (Day 6–7)
Chart `charts/demo-app/` with `values-dev.yaml`, `values-prod.yaml`:
- Deployment: replicas ≥ 3, rolling update (`maxUnavailable: 0`, `maxSurge: 1`), resource requests/limits, liveness/readiness/startup probes, `topologySpreadConstraints` across AZs + pod anti-affinity.
- **HPA** (CPU/memory, optionally custom metrics via Prometheus Adapter/KEDA).
- **PodDisruptionBudget** (`minAvailable: 2`).
- Service (ClusterIP) and **HTTPRoute** (attaches to the shared Gateway; hostnames `dev.akashcloud.online` / `app.akashcloud.online`). No Ingress resource.
- ServiceAccount with IRSA (least privilege), ConfigMap, ExternalSecret.
- **NetworkPolicy** (default deny; allow ingress from ALB + Prometheus).
- SecurityContext: `runAsNonRoot`, `readOnlyRootFilesystem`, drop ALL caps, `seccompProfile: RuntimeDefault`.
- **ServiceMonitor** + **PrometheusRule** (alerts) + Grafana dashboard ConfigMap.
- Helm tests (`helm test`) hitting `/healthz`.

### Phase 4a – Gateway API (Day 7)
Replaces a classic Ingress controller with the Kubernetes Gateway API (role-oriented: platform team owns `GatewayClass`/`Gateway`, app team owns `HTTPRoute`).

- [ ] Install Gateway API CRDs (standard channel, pinned version) via Argo CD.
- [ ] Install **Envoy Gateway** (Helm, 2+ replicas, PDB, spread across AZs). Gateway API implementation chosen for conformance, HTTPRoute weights (canary), rate limiting, and header/path routing.
- [ ] `GatewayClass` + shared `Gateway` (`platform` namespace):
  - Listeners: 80 (redirect to 443) and 443 (TLS terminate, cert from cert-manager `Certificate` for `*.akashcloud.online` or per-host).
  - `allowedRoutes` restricted to labeled namespaces (`dev`, `prod`).
- [ ] Gateway's Service of type LoadBalancer provisioned as an internet-facing **NLB** (AWS LB Controller annotations, cross-zone enabled, subnets in 3 AZs).
- [ ] ExternalDNS watches Gateway/HTTPRoute and creates Route53 records for `dev.akashcloud.online`, `app.akashcloud.online`, and internal `grafana.akashcloud.online`.
- [ ] Policies: `ClientTrafficPolicy`/`BackendTrafficPolicy` for timeouts, retries, rate limits; HTTPRoute for Grafana restricted by auth/IP allowlist.
- [ ] Add `ReferenceGrant` only where cross-namespace backends are needed.
- [ ] Validate: HTTPS works, HTTP redirects, route status `Accepted/ResolvedRefs`, canary traffic split 90/10 test.

Trade-off note: the NLB has no native WAF. If WAF is mandatory, alternative is the AWS Load Balancer Controller's native Gateway API support (ALB + WAF); decide before Phase 4a.

### Phase 5 – CD with Argo CD (Day 7–8)
- Argo CD installed via Terraform bootstrap; app-of-apps / ApplicationSet manages platform add-ons and the `demo-app` for `dev` and `prod` namespaces.
- CI (GitHub Actions) only builds/pushes the image and commits the new image tag (git SHA) to the GitOps path; Argo syncs automatically to `dev`, and `prod` requires a PR approval (or manual sync).
- Argo settings: automated sync with `prune` + `selfHeal` on dev, manual sync on prod, sync waves for ordering (CRDs -> controllers -> apps), notifications to Slack.
- Argo CD itself: HA mode, SSO/OIDC (GitHub), RBAC, exposed via HTTPRoute at `argocd.akashcloud.online`, restricted access.
- Optional: Argo Rollouts for canary/blue-green (integrates with Gateway API plugin).
- Promotion flow: `dev` (auto) -> `prod` (approved PR/manual sync) in the same cluster, separated by namespace.
- Rollback: Argo CD rollback / `git revert`; health checks gate syncs.

### Phase 6 – Observability (Day 8–10)
- [ ] Install **kube-prometheus-stack** (Prometheus Operator, Alertmanager, Grafana, node-exporter, kube-state-metrics).
- [ ] Prometheus: persistent EBS volume, retention 15d, 2 replicas (HA), optional remote_write to Amazon Managed Prometheus / Thanos for long-term.
- [ ] Alertmanager: 3 replicas, routes to Slack/PagerDuty/SNS.
- [ ] Grafana: persistent storage, SSO (OIDC), admin password in Secrets Manager, dashboards-as-code (provisioned).
- [ ] Dashboards: cluster/node health, app RED metrics (Rate, Errors, Duration), HPA/scaling, deployment events.
- [ ] Alerts: pod crashloop, high 5xx rate, p95 latency, HPA at max, node NotReady, PVC filling, cert expiry.
- [ ] Define SLOs (e.g., 99.9% availability, p95 < 300 ms) and burn-rate alerts.
- [ ] Logging: Fluent Bit -> CloudWatch Logs (or Loki). Optional tracing: OpenTelemetry -> X-Ray/Tempo.
- [ ] Grafana/Prometheus exposed internally only (VPN/SSO-protected ingress or port-forward).

### Phase 7 – Hardening & Validation (Day 10–12)
- [ ] Load test (k6/Locust): verify HPA scale-out and node scale-out.
- [ ] Chaos/HA test: kill pods, drain a node, simulate AZ loss; verify zero downtime.
- [ ] Security review: kube-bench, Trivy operator/kubescape, Kyverno/OPA Gatekeeper policies (no privileged, no `latest`, signed images only, required limits).
- [ ] Backup: Velero (cluster state + PVs) with restore drill.
- [ ] Runbooks + documentation; cost review.

---

## 3. Repository Layout

```
.
├── app/                      # Python source, tests, Dockerfile
├── charts/demo-app/          # App Helm chart (+ values-{dev,prod}.yaml)
├── platform/                 # Helm values for add-ons (prom stack, LB ctrl, etc.)
├── infra/
│   ├── modules/              # vpc, eks, ecr, iam
│   └── envs/{dev,prod}/      # Terraform root modules
├── gitops/                   # Argo CD Applications (Phase 5b)
├── .github/workflows/        # ci.yaml, cd.yaml, terraform.yaml
└── docs/                     # runbooks, ADRs
```

---

## 4. Non-Functional Requirements Mapping

### Scalability
- Pod level: HPA (min 3, max ~10+), resource requests tuned from load tests.
- Node level: Karpenter or Cluster Autoscaler; mixed spot/on-demand.
- Stateless app; ALB with target-type `ip`.

### High Availability
- 3 AZs; EKS managed multi-AZ control plane.
- ≥3 replicas, topology spread across AZs, PDBs, rolling updates with zero unavailability.
- NAT GW per AZ; HA Prometheus/Alertmanager; multi-replica CoreDNS.
- Probes + graceful termination (`preStop` sleep, `terminationGracePeriodSeconds`).
- Optional DR: second region with Route53 failover (out of scope for demo, noted).

### Security (defense in depth)
| Area | Controls |
|---|---|
| Identity | SSO, least-privilege IAM, GitHub OIDC (no static keys), IRSA/Pod Identity, EKS access entries (no wide `system:masters`) |
| Network | Private subnets, SGs, NetworkPolicies default-deny, WAF on ALB, TLS everywhere (ACM), restricted API endpoint CIDRs |
| Supply chain | Trivy/pip-audit, SBOM, cosign signing, admission policy verifying signatures, immutable ECR tags, pinned base image digests |
| Runtime | Non-root, read-only FS, dropped caps, seccomp, Pod Security Admission `restricted`, Kyverno policies |
| Secrets | AWS Secrets Manager + External Secrets Operator; KMS envelope encryption; no secrets in Git/images |
| Data | Encrypted EBS/ECR/S3 (KMS), IMDSv2 |
| Audit | EKS control-plane logs, CloudTrail, GuardDuty (EKS protection), Config |

---

## 5. Environments & Promotion

| Env | Where | Host | Deploy trigger |
|---|---|---|---|
| dev | namespace `dev` | `dev.akashcloud.online` | Auto sync on merge to `main` |
| prod | namespace `prod` | `app.akashcloud.online` | Approved PR / manual Argo sync |

Single cluster with namespace isolation (decided for cost). Compensating controls: ResourceQuotas + LimitRanges per namespace, default-deny NetworkPolicies, separate ServiceAccounts/IRSA roles, Pod Security `restricted`, Gateway `allowedRoutes` scoping, and optionally a dedicated prod node group via taints. Trade-off: shared control plane and blast radius; revisit with a separate prod cluster if this goes beyond a demo.

---

## 6. Cost Notes (approximate, check current pricing)
- EKS control plane ≈ $73/month per cluster.
- NAT Gateways ≈ $32/month each (×3 AZs) + data; reduce to 1 for dev.
- Nodes: 3 × t3.medium/m5.large; use Spot for non-critical.
- ALB, EBS, CloudWatch logs, ECR storage.
- Tear down dev when idle (`terraform destroy`), set AWS Budgets alerts.

---

## 7. Risks & Mitigations
| Risk | Mitigation |
|---|---|
| Cost overrun | Budgets/alarms, single NAT in dev, auto-teardown |
| Misconfigured IAM | IaC review, IAM Access Analyzer, least privilege |
| Bad deploy | `--atomic`, probes, canary, fast rollback |
| Prometheus data loss | PVC + replicas + remote_write |
| Add-on version drift | Pin chart versions, Renovate/Dependabot |
| Single-region outage | Documented DR plan, backups with Velero |

---

## 8. Definition of Done
- [ ] `git push` to `main` builds, scans, signs, pushes image and deploys to dev with no manual steps.
- [ ] App reachable over HTTPS via ALB + custom domain.
- [ ] Surviving loss of one AZ/node with no failed requests (verified).
- [ ] HPA scales under load; nodes scale accordingly.
- [ ] Grafana shows app + cluster dashboards; alerts fire to Slack on test failure.
- [ ] No critical vulnerabilities; policies enforced; no static AWS credentials anywhere.
- [ ] Rollback tested; runbooks documented; infra fully reproducible from Terraform.

---

## 9. Suggested Timeline
| Week | Deliverable |
|---|---|
| 1 | Phases 0–3: foundations, app, Terraform infra, CI |
| 2 | Phases 4–6: Helm chart, CD, observability |
| 3 | Phase 7: hardening, load/chaos tests, docs, optional GitOps |

## 10. Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | IaC | Terraform |
| 2 | CI | GitHub Actions |
| 3 | CD | Argo CD from the start (GitOps) |
| 4 | Cluster topology | One cluster, `dev` + `prod` namespaces |
| 5 | Domain | `akashcloud.online` (Route53 + cert-manager) |
| 6 | Monitoring | Self-hosted kube-prometheus-stack |
| 7 | Ingress | Kubernetes Gateway API (Envoy Gateway + NLB) |

| 8 | WAF | Not required now (Envoy Gateway + NLB confirmed; revisit later via ALB + WAF if needed) |
| 9 | DNS | Registrar is external; after Terraform creates the Route53 zone, manually set the registrar nameservers to the zone's NS records |
| 10 | AWS region | `us-east-1` (N. Virginia) — request said "us-east-01", interpreted as us-east-1 |
| 11 | Repo | https://github.com/akashborkar93/Secure-python-app.git |
| 12 | Let's Encrypt contact / alerts | akash.borkar2@gmail.com; Alertmanager sends email (needs SMTP, e.g. Amazon SES in us-east-1 with verified sender) |

**Still open:** none blocking. Notes: cert-manager DNS-01 will not issue certs until the registrar nameservers are delegated to Route53; Gmail SMTP needs an app password, so SES is recommended for Alertmanager email.
