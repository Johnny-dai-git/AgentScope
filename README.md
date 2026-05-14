# LLM Deployment — Lambda Labs / A100 branch

Self-hosted, Kubernetes-based LLM inference platform. OpenAI-compatible API on top of vLLM, fully observable, with GitOps continuous deployment.

> **This branch targets a bare-metal Lambda Labs A100 80GB instance with mixed-profile MIG.** A single physical A100 is partitioned into one 3g.40gb slice (Qwen 14B, exclusive), one 2g.20gb slice (Qwen 7B, exclusive), and 2× 1g.10gb slices time-sliced into 8 schedulable slots for a small-model pool (Qwen 0.5B / TinyLlama 1.1B / Llama 3.2-3B). HPA has been removed — every Deployment runs at `replicas: 1` and the operator sizes things directly. For the laptop reference deployment (kubeadm + RTX 4050 + GPU time-slicing), see the [`telemetry`](https://github.com/Johnny-dai-git/llm-deployment/tree/telemetry) branch of llm-deployment.

```
┌─────────────────────────────────────────────────────────────────┐
│                    External Client (Browser / CLI)              │
└──────────────────────────────┬──────────────────────────────────┘
                               │ HTTP
                               ▼
                       ingress-nginx (host:80)
                               │
                ┌──────────────┴──────────────┐
                │ /api                        │ /web
                ▼                             ▼
    ┌──────────────────┐            ┌──────────────────┐
    │  llm-api         │            │  llm-web         │
    │  (FastAPI)       │            │  (nginx + SSE)   │
    │  - auth          │            └──────────────────┘
    │  - SSE streaming │
    └────────┬─────────┘
             │ HTTP (OpenAI compatible)
             ▼
    ┌──────────────────┐
    │  vllm-worker     │
    │  (vLLM + GPU)    │
    │  - PagedAttn     │
    │  - cont. batching│
    └──────────────────┘

   Sizing:       static replicas in each Deployment (no HPA)
   Observed by:  Prometheus + Grafana + DCGM exporter
   Deployed by:  ArgoCD + ArgoCD Image Updater (GitOps)
   Built by:     GitHub Actions self-hosted runner → GHCR
```

## What's Inside

- **OpenAI-compatible API** with SSE streaming for chat completions
- **Five GPU-inference workers**, one Deployment per model, each pinned to a MIG slice:

  | Worker pod | MIG slice | Model |
  |---|---|---|
  | `vllm-qwen14b` | `mig-3g.40gb` × 1 (exclusive) | Qwen2.5-14B-Instruct |
  | `vllm-qwen7b` | `mig-2g.20gb` × 1 (exclusive) | Qwen2.5-7B-Instruct |
  | `vllm-qwen-small` | `mig-1g.10gb` × 1 (time-sliced) | Qwen2.5-0.5B-Instruct |
  | `vllm-tinyllama` | `mig-1g.10gb` × 1 (time-sliced) | TinyLlama-1.1B-Chat |
  | `vllm-llama3` | `mig-1g.10gb` × 1 (time-sliced) | Llama-3.2-3B-Instruct |

- **Mixed-profile MIG** on one A100 80GB: big models get hardware isolation; small models share via software time-slicing on top of the 1g.10gb slices.
- **GitOps deployment** via ArgoCD; ArgoCD fully owns `Deployment.spec.replicas` (no HPA tug-of-war).
- **Auto image updates** via ArgoCD Image Updater watching GHCR for `v-YYYYMMDD-HHMMSS` tags.
- **Full observability**: Prometheus + Grafana + DCGM (GPU metrics) + a ServiceMonitor per worker.
- **Self-hosted CI**: GitHub Actions self-hosted runner builds and pushes images on every commit.

## Quick Start (laptop)

Three commands. The whole thing comes up in 5–15 minutes.

```bash
# 1. Clone and enter the repo
git clone https://github.com/Johnny-dai-git/llm-deployment.git
cd llm-deployment
git checkout telemetry            # current dev mainline

# 2. Download the model weights once (~1 GB, idempotent)
bash script/laptop/download-model.sh

# 3. Bootstrap the cluster + everything on top
sudo bash script/laptop/launch.sh
```

Once the script finishes you'll see a list of access URLs:

| URL | What |
|---|---|
| `http://localhost/web` | Chat UI with markdown + streaming |
| `http://localhost/api/v1/chat/completions` | OpenAI-compatible endpoint |
| `http://localhost/grafana` | Dashboards (anonymous Admin) |
| `http://localhost/prometheus` | Metrics querying |
| `http://localhost/argocd` | GitOps UI |
| `http://localhost/` | Landing page with links |

## Prerequisites

- **OS**: Ubuntu 22.04+ (the `all_install.sh` script targets the apt ecosystem)
- **GPU** (recommended): NVIDIA GPU with 6 GB+ VRAM. The repo runs in CPU-only mode but `vllm-worker` will Pend without a GPU.
- **Disk**: ~30 GB free for K8s state + model weights + container images
- **Docker** + **kubeadm** + **helm**: installed automatically by `all_install.sh`

## Project Structure

```
llm-deployment/
├── app/                              # Source for our own services
│   ├── gateway/                      # FastAPI: auth + SSE + forward (= "llm-api")
│   ├── worker/vllm/                  # vLLM worker Dockerfile
│   └── web/                          # nginx + chat UI (HTML + marked.js)
│
├── tools/                            # Kubernetes manifests (GitOps source of truth)
│   ├── llm/                          # Business namespace (kustomized)
│   │   ├── api/                      # llm-api Deployment + Service + ServiceMonitor
│   │   ├── workers/
│   │   │   ├── vllm-qwen14b/         # 3g.40gb MIG (exclusive)
│   │   │   ├── vllm-qwen7b/          # 2g.20gb MIG (exclusive)
│   │   │   ├── vllm-qwen-small/      # 1g.10gb time-slice slot (also exports vllm-worker-service alias)
│   │   │   ├── vllm-tinyllama/       # 1g.10gb time-slice slot
│   │   │   └── vllm-llama3/          # 1g.10gb time-slice slot
│   │   ├── web/                      # web Deployment + Service + nginx ConfigMap
│   │   ├── ingress/                  # /api and /web routing
│   │   ├── landing/                  # /landing page
│   │   └── kustomization.yaml
│   ├── argocd-image-updater/         # SA, RBAC, Deployment, Application
│   ├── helm/                         # Helm values for ArgoCD, monitoring stack
│   │   ├── argocd/values.yaml
│   │   └── monitoring/
│   │       ├── kps-values.yaml       # kube-prometheus-stack values
│   │       └── dcgm/values.yaml      # NVIDIA DCGM exporter values
│   └── system/                       # Cluster-level: NVIDIA device plugin (mixed MIG strategy), RuntimeClass
│
├── script/                           # Bootstrap scripts split per environment
│   ├── laptop/                       # Single-node laptop bootstrap
│   │   ├── all_install.sh            # Docker + kubeadm + helm
│   │   ├── system.sh                 # kubeadm reset + init + Calico CNI
│   │   ├── launch.sh                 # one-shot orchestrator (calls the above)
│   │   ├── build-and-push.sh         # local image build (when CI is too slow)
│   │   └── download-model.sh         # fetch Qwen2.5-0.5B from HuggingFace
│   └── lambda/                       # Lambda Labs A100 bootstrap (this branch)
│       ├── all_install.sh            # k8s tools + helm + auto MIG (7× 1g.5gb)
│       ├── system.sh                 # kubeadm reset + init (private IP autodetect)
│       ├── launch.sh                 # orchestrator: pre-pull + chown + helm installs
│       └── download-model.sh         # fetch Qwen2.5-0.5B to /mnt/models
│
├── description/                      # ASCII architecture diagrams (zh + en)
└── .github/workflows/local-build.yml # CI: build + push images on push to main/telemetry
```

## CI/CD Flow

```
You push code to telemetry
        │
        ▼
GitHub Actions detects push, dispatches workflow
        │
        ▼
Self-hosted runner on this laptop picks up the job
        │
        ├─ Docker build changed images (paths-filter)
        │  - app/gateway/**       → rebuild gateway
        │  - app/worker/vllm/**   → rebuild vllm-worker
        │  - app/web/**           → rebuild web
        │
        └─ docker push ghcr.io/johnny-dai-git/llm-deployment/<svc>:v-<timestamp>
                │
                ▼
        ArgoCD Image Updater (running in cluster) scans GHCR every 2 min
                │
                ▼
        Detects new tag matching regex ^v-[0-9]{8}-[0-9]{6}$
                │
                ▼
        Patches the ArgoCD Application's image-list
                │
                ▼
        ArgoCD performs a rolling update of the Deployment
                │
                ▼
        New version live, browser refresh shows it
```

For local debugging without going through CI:

```bash
bash script/laptop/build-and-push.sh
```

This builds and pushes all three service images directly to GHCR using the same timestamp tag scheme.

## Components

### Application Layer (we own)

| Service | Purpose | Image |
|---|---|---|
| `llm-api` (gateway) | OpenAI-compatible HTTP frontend; auth + request validation + forward to vllm-worker; SSE streaming | `ghcr.io/.../gateway` |
| `vllm-worker` | GPU inference; vLLM with PagedAttention and continuous batching | `ghcr.io/.../vllm-worker` |
| `llm-web` | Static chat UI (nginx + HTML + marked.js for markdown) | `ghcr.io/.../web` |

### Platform Layer (third-party, Helm-installed)

| Component | Purpose |
|---|---|
| `ingress-nginx` | L7 ingress; binds host network on port 80 |
| `argocd` | GitOps controller |
| `argocd-image-updater` | Watches GHCR for new tags |
| `kube-prometheus-stack` | Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics |
| `dcgm-exporter` | NVIDIA GPU metrics |
| `metrics-server` | Cluster resource metrics (used by `kubectl top`; left in even after HPA removal) |

### Probes Strategy

Every Pod has the full `startupProbe + readinessProbe + livenessProbe` triplet:

- `vllm-worker`: startup/readiness on `/v1/models` (returns 200 only after model is loaded), liveness on `/health` (process-level, gentle restarts)
- `llm-api`, `llm-web`, `landing-nginx`: same endpoint for all three probes (no meaningful intermediate state), differentiated by timing parameters

### Monitoring Layer

Business metrics flow into Prometheus via `ServiceMonitor` resources — one per worker plus one for the gateway:

- `tools/llm/api/api-servicemonitor.yaml` — exposes `llm_api_requests_total`, `llm_api_request_latency_seconds`
- `tools/llm/workers/vllm-qwen14b/vllm-qwen14b-servicemonitor.yaml` (and equivalents for `vllm-qwen7b`, `vllm-qwen-small`, `vllm-tinyllama`, `vllm-llama3`) — each exposes vLLM's metrics (`vllm:e2e_request_latency_seconds`, `vllm:gpu_cache_usage_perc`, `vllm:num_requests_running`, `vllm:num_requests_waiting`, etc.) labeled by pod so you can compare models in Grafana.

The `kube-prometheus-stack` selectors are wide open (`{}`) so any ServiceMonitor in any namespace gets scraped — appropriate for a single-team setup.

### Scaling Strategy (no HPA)

This branch deliberately runs every Deployment at `replicas: 1`. Capacity is sized by giving each model the MIG slice that fits it, not by adding pods:

- **Big models** (14B / 7B) are GPU-bound and bottlenecked by VRAM; each owns a dedicated MIG instance so KV cache and prefill compute aren't fighting anyone.
- **Small models** time-slice the 1g.10gb pool — adding more replicas of the *same* small model wouldn't help much because they'd just compete for the same 10 GB.

If you need more headroom, the supported moves are:

1. Add a second A100 node and double the MIG budget (and bump `replicas:` on whichever model is hot).
2. Swap to a bigger MIG profile for a specific model (e.g. give Qwen 7B its own 3g.40gb if 14B isn't in use).
3. Reintroduce HPA on a specific worker — manifests under `tools/llm/workers/` are independent, so you can add an `*-hpa.yaml` to just one of them without it spreading.

## Common Tasks

### Iterate on application code

```bash
# Edit app/gateway/gateway.py or wherever
git add -A
git commit -m "fix: ..."
git push origin telemetry
# → CI builds and pushes new image
# → Image Updater detects new tag (~2 min)
# → ArgoCD rolling-updates the Deployment (~1 min)
# → Refresh browser to see your change live
```

### Inspect the cluster

```bash
kubectl get pods -A                                           # everything
kubectl get pods -n llm                                       # business namespace
kubectl logs -n llm -l app=vllm-qwen14b -f                    # live logs for one worker
kubectl describe pod -n llm <pod>                             # one pod's full state
kubectl get servicemonitor -n llm                             # what Prometheus is scraping
kubectl top pod -n llm                                        # CPU / memory (via metrics-server)
```

### Verify metrics flow

```bash
# After launch, open Prometheus targets:
http://localhost/prometheus/targets

# Should see UP for each ServiceMonitor (one per worker + the gateway):
#   serviceMonitor/llm/llm-api/0
#   serviceMonitor/llm/vllm-qwen14b/0
#   serviceMonitor/llm/vllm-qwen7b/0
#   serviceMonitor/llm/vllm-qwen-small/0
#   serviceMonitor/llm/vllm-tinyllama/0
#   serviceMonitor/llm/vllm-llama3/0
#   serviceMonitor/monitoring/dcgm-exporter/0

# Useful PromQL (per-pod via {pod="..."} or {served_model_name="..."}):
llm_api_requests_total
vllm:num_requests_running
vllm:gpu_cache_usage_perc
DCGM_FI_DEV_GPU_UTIL
```

### Send a real request to one model

```bash
# Hit the small-pool gateway alias (which the existing llm-api still points at):
curl -sS -X POST http://localhost/api/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-0.5b","messages":[{"role":"user","content":"hi"}],"max_tokens":50}' | jq

# Or hit a specific worker directly via its ClusterIP service (port-forward first):
kubectl -n llm port-forward svc/vllm-qwen14b-service 8002:8002 &
curl -sS -X POST http://localhost:8002/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-14b","messages":[{"role":"user","content":"hi"}],"max_tokens":50}' | jq
```

## Historical Performance — earlier A100 40 GB run (7× 1g.5gb MIG + HPA)

> ⚠️ The headline numbers below come from an earlier iteration of this
> branch that ran on an A100 **40 GB** with **7× 1g.5gb MIG** and HPA
> autoscaling Qwen2.5-0.5B from 1↔7 replicas. The current layout
> (A100 80 GB, mixed-profile MIG, 5 different models, no HPA) targets
> a very different question — *multi-model service-quality and
> isolation*, not single-model throughput. The old run is kept here for
> reference because it's still the cleanest demonstration of an A100
> being driven near 100 % GR Engine Active under vLLM.

End-to-end stress test, hammered through the public ingress
(`http://<public-ip>/api/v1/chat/completions`):

### 08 — Extreme Stress (12 min, concurrency 60, ~2 000-token prompts)

| Metric | Value |
|---|---|
| Total requests served | **3,460** |
| Wall time | 12 min 13 s |
| **Peak GPU compute (DCGM_FI_PROF_GR_ENGINE_ACTIVE)** | **91.3 %** |
| Mean GPU compute (12 min average) | 83.4 % |
| Peak Tensor Core (DCGM_FI_PROF_PIPE_TENSOR_ACTIVE) | 14.5 % |
| Mean Tensor Core | 12.5 % |
| Replicas (start → peak, HPA-driven) | 1 → **5** (of max 7) |
| MIG instances saturated simultaneously | **5 / 7** |

A 12-min window only fits ~3-4 full HPA scale-up steps after accounting for vLLM cold-start (30-60 s per pod) and the stabilization windows. Running the test longer drove the old setup all the way to 7 / 7 replicas.

The 14.5 % Tensor Core peak is **expected for this model size** — Qwen2.5-0.5B has ~1 GB of fp16 weights, so even fully batched decode is dominated by memory-bandwidth, not Tensor Core math. To push Tensor Core utilization above 30 %, swap in a 7B-class model (planned, not in this branch yet).

### vs. Laptop Baseline

The laptop branch (`telemetry`, RTX 4050 6 GB, GPU time-slicing 2 slots) was the lower-bound reference. Hardware change → orchestration change → user-visible result:

| Dimension | Laptop (`telemetry`) | Lambda A100 (this branch) |
|---|---|---|
| GPU sharing | software time-slicing, 2 slots | **hardware MIG**, 7 instances |
| HPA range | 1 ↔ 2 | 1 ↔ **7** |
| Noisy neighbor risk | high (shared SMs/VRAM) | **none** (MIG enforces isolation) |
| Peak compute under load | not separable per slot | **91.3 % per MIG, 5 MIGs simultaneously** |
| Sustained throughput (real-world prompts) | 434 tok/s | (see 06 below — same rig, different stage) |
| Realistic P95 latency | 5.9 s | (see 06 below) |

---

## Performance Baseline (laptop reference)

> ⚠️ The numbers below come from the **laptop reference deployment**
> (kubeadm + RTX 4050 + time-slicing) on the `telemetry` branch.
> They're kept here as the lower-bound baseline; the test suite under
> `test/` still produces apples-to-apples vLLM behavior across hardware.

End-to-end benchmark on the laptop reference setup: **single-node K8s, NVIDIA RTX 4050 Laptop (6 GB VRAM, ~192 GB/s mem bandwidth), Qwen2.5-0.5B fp16, vLLM 0.11**. Full raw results live in [`test/results/baseline-pre-optimization/`](test/results/baseline-pre-optimization). Reproduce with:

```bash
cd test
./run_all.sh                 # ~15 min, 5 stages (smoke/latency/throughput/stability/realistic), generates SUMMARY.md
```

### 01 — Functional (7 / 7 passed)

`/v1/models` · single completion · SSE streaming · multi-turn · `max_tokens` enforcement · unknown-model 4xx · empty-messages 4xx — all green.

### 02 — Latency (fixed prompt, prefix-cache hit; 30 req per level)

| Concurrency | Mean | P50 | P90 | P95 | P99 |
|---|---|---|---|---|---|
| 1 | 649 ms | 672 ms | 722 ms | 725 ms | 737 ms |
| 4 | 737 ms | 751 ms | 774 ms | 789 ms | 800 ms |
| 8 | 809 ms | 825 ms | 883 ms | 883 ms | 884 ms |

Concurrency 8 P50 only **23% higher** than single-stream — vLLM continuous batching works as advertised.

### 03 — Throughput (fixed prompt, prefix-cache hit; 16 req per scenario, concurrency 8)

| Scenario | Output tok/s | Wall | Avg latency |
|---|---|---|---|
| Short prompt + short output | 366.0 | 1.19 s | 420 ms |
| Short prompt + long output  | 437.2 | 1.16 s | 432 ms |
| Long prompt + short output  | 644.1 | 1.24 s | 606 ms |
| **Long prompt + long output** | **824.2** | 5.82 s | 2.9 s |

Peak **~824 tok/s** under 8-way batched load — about **70-80% of the theoretical memory-bandwidth-bound ceiling** for fp16 Qwen2.5-0.5B on this GPU.

### 05 — Sustained Load Stability (300 s, concurrency 4)

| Metric | Value |
|---|---|
| Total requests | 842 |
| Errors | **0** (0.00%) |
| RPS | 2.81 |
| `vllm-worker` pod restarts | **0** |

### 06 — Realistic Load (300 s, concurrency 8, **60 random prompts** to defeat prefix cache)

| Metric | Value |
|---|---|
| Total OK requests | 680 |
| Errors | 3 (0.44%) |
| **Output tok/s (sustained)** | **433.8** |
| Total tok/s (incl. prompt) | 554.3 |
| RPS | 2.27 |
| **P50 latency** | **2 484 ms** |
| P95 latency | 5 881 ms |
| P99 latency | 6 379 ms |

### 02/03 vs 06 — Why the Two Numbers Both Matter

| | 02 / 03 (fixed prompt, cache 100% hit) | 06 (random prompts, cache miss) | Ratio |
|---|---|---|---|
| Single-stream P50 latency | 672 ms | 2 484 ms | **3.7× slower without cache** |
| Output throughput | ~824 tok/s **peak** | ~434 tok/s **sustained** | **0.53× under real traffic** |

Stages 02 and 03 reuse the same prompt for every request, so vLLM's automatic prefix caching hits ~100% and prompt-processing time collapses to near zero — these numbers represent the **theoretical ceiling**. Stage 06 samples randomly from a 60-prompt pool covering Chinese & English, programming, math, and creative writing, so cache hit rate ≈ 0% — these numbers represent **real production throughput and latency**.

**Capacity planning should use the 06 numbers (~434 tok/s sustained, P95 5.9 s), not the 824 tok/s peak.**

## Branches

| Branch | Target | GPU | GPU sharing | Replicas | Storage |
|---|---|---|---|---|---|
| [`telemetry`](https://github.com/Johnny-dai-git/llm-deployment/tree/telemetry) | laptop, kubeadm | RTX 4050 6 GB | time-slicing (software, 2 slots) | HPA 1↔2 | hostPath |
| **this branch** | Lambda Labs (bare A100 80 GB, kubeadm) | A100 80 GB | **MIG mixed** (1× 3g.40gb + 1× 2g.20gb + 2× 1g.10gb) | static `replicas: 1` per model | hostPath (`/mnt/models`) |

The telemetry branch deploys a single Qwen2.5-0.5B and uses HPA to demonstrate autoscaling. This branch deploys **five models** with hand-sized MIG slices and no HPA — the focus shifts from "scale one model on demand" to "serve a fleet of mixed-size models with hardware isolation where it matters".

## Real Bugs Hit During Deployment ("War Stories")

Every non-trivial fix in this repo is documented under
[`docs/war-stories.md`](docs/war-stories.md) (also as a
[printable PDF](docs/war-stories.pdf)). Each entry has the symptom,
root cause, and the actual fix that landed.

Topics covered (18 issues across two hardware generations):

- **Laptop / RTX 4050**: containerd cgroup driver mismatch causing
  control-plane crash loops; `nvidia-container-toolkit` vs
  `nvidia-device-plugin` — both required, neither installs the other;
  vLLM 0.11 incompatible with `transformers` 5.x; `vllm-worker` over-
  requesting 16 GiB RAM when actual RSS is 1.8 GiB; gateway wrapping
  every upstream error as 502; HPA `<unknown>/5` from a missed
  prometheus-adapter URL path; ArgoCD selfHeal fighting HPA over
  `replicas`; monitoring evicted under node pressure; consumer-card
  vLLM workarounds.
- **Lambda Labs / A100 + MIG**: MIG mode disabled by default and how
  we automate enabling + 7-instance GI/CI creation; helper pods
  silently stuck in `ContainerCreating` for 14 minutes due to Docker
  Hub rate limit on Lambda's egress IP pool; `mirror.gcr.io` registry
  mirror + `helm template`-driven image pre-pull as the systemic fix;
  Grafana `init-chown-data` hitting `Permission denied` because modern
  charts run init containers as non-root with `CAP_CHOWN` dropped;
  Grafana login page rendering blank because nested YAML maps under
  `grafana.ini.auth.anonymous` get serialized as JSON instead of an
  INI section; upstream DCGM dashboard collapsing 7 MIG instances
  into 7 rows of "GPU 0"; Prometheus' ServiceMonitor relabel moving
  the workload pod label to `exported_pod`; HPA timing budget that
  caps practical scale-up to 5/7 in a 12-min window; Tensor Core
  utilization being model-size-bound, not infrastructure-bound.

The PDF is generated by `docs/_make_pdf.py` from the source
markdown — re-run after editing the war stories.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| A worker Pod stuck in `CrashLoopBackOff` | Model files not present at the hostPath | Extend `script/lambda/download-model.sh` to fetch the model into `/mnt/models/<name>/` |
| A worker Pod `Pending` | No MIG instance of the requested profile is available | `kubectl describe pod -n llm <pod>` (look for "Insufficient nvidia.com/mig-…"); rerun `script/lambda/all_install.sh` to rebuild MIG |
| All worker Pods of one profile Pending after node reboot | MIG mode reverted to disabled, or instances destroyed | Re-run `script/lambda/all_install.sh` (idempotent — re-enables MIG and rebuilds the 4 instances) |
| `llm-api` returns 502 | The pod behind `vllm-worker-service` (the legacy alias = vllm-qwen-small) is down or model not loaded | `kubectl logs -n llm -l app=vllm-qwen-small` |
| Streaming response arrives all at once instead of token-by-token | ingress-nginx is buffering | Confirm `unified-ingress.yaml` has `nginx.ingress.kubernetes.io/proxy-buffering: "off"` |
| GHCR push fails with `unauthenticated` during build-and-push.sh | Token revoked or wrong scope | Regenerate GitHub PAT with `write:packages` scope, then `docker logout ghcr.io && docker login ghcr.io -u <user> --password-stdin <<< $TOKEN` |
| ArgoCD shows `OutOfSync` | Probably normal mid-deploy. If persistent, check the Application's status in `http://localhost/argocd` |

## License

This is a personal learning project; no formal license. Use at your own risk.
