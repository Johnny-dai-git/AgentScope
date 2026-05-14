#!/bin/bash
# =====================================================================
# Lambda Labs A100 — node bootstrap (all_install.sh)
# ---------------------------------------------------------------------
# Installation script for GCP_BRANCH on **Lambda Labs A100 bare metal**.
# Lambda base image comes pre-installed with:
#   - NVIDIA driver (580.x)
#   - containerd
#   - docker
#   - nvidia-container-toolkit (nvidia-ctk)
#
# So we **do not** repeat installing these components. We only install what Lambda is missing:
#   - kubelet / kubeadm / kubectl
#   - helm
# Plus some **mandatory aligned** configurations:
#   - swap off                              (k8s requirement)
#   - containerd SystemdCgroup = true       (k8s requirement; default cgroupfs causes
#                                            kubelet/control-plane crash loop — same
#                                            issue as laptop, see MEMORY)
#   - MIG status self-check                 (warn-only)
#
# Differences from script/laptop/all_install.sh:
#   - No GPU detection branch — this machine always has A100
#   - Do not install nvidia-container-toolkit — Lambda already has it
#   - Do not install docker — Lambda already has it
#   - Do not install containerd — Lambda already has it (but modify cgroup driver)
#   - Add MIG self-check — A100 uses 7× 1g.5gb hardware partitions
#
# Usage:
#   sudo bash script/lambda/all_install.sh
# =====================================================================
set -e
echo "===== Lambda A100 node initialization (all_install.sh) ====="

##############################################
# 1. Disable swap
# ----------------------------------------------------------------
# kubelet refuses nodes with swap enabled. Lambda base image usually
# has swap off, but run idempotently to ensure.
##############################################
echo "[1/6] Disable swap"
if [ "$(swapon --show | wc -l)" -gt 0 ]; then
    sudo swapoff -a
    sudo sed -i '/ swap / s/^/#/' /etc/fstab
    echo "  ✓ swap disabled"
else
    echo "  ➡ swap already disabled, skip"
fi

##############################################
# 1.5. Common utilities (jq, bc) — test suite dependencies
# ----------------------------------------------------------------
# Lambda base image does not include jq/bc. test/run_lambda.sh and
# troubleshooting commands need them; install once. curl/awk/git usually present.
##############################################
echo "[2/6] Install common utilities (jq, bc)"
NEED_INSTALL=()
command -v jq >/dev/null 2>&1 || NEED_INSTALL+=(jq)
command -v bc >/dev/null 2>&1 || NEED_INSTALL+=(bc)

if [ ${#NEED_INSTALL[@]} -gt 0 ]; then
    sudo apt-get update -y
    sudo apt-get install -y "${NEED_INSTALL[@]}"
    echo "  ✓ Installed: ${NEED_INSTALL[*]}"
else
    echo "  ➡ jq / bc already present, skip"
fi

##############################################
# 2. Install Kubernetes trio (kubelet / kubeadm / kubectl)
# ----------------------------------------------------------------
# Lambda does not install these by default. Version lock v1.30
# (consistent with laptop branch; manifests use v1.30 + autoscaling/v2).
##############################################
echo "[3/6] Install kubelet / kubeadm / kubectl (v1.30)"
if ! command -v kubeadm >/dev/null 2>&1; then
    sudo mkdir -p /etc/apt/keyrings

    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
        | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/k8s.gpg

    echo "deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

    sudo apt-get update -y
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
    echo "  ✓ kubeadm/kubelet/kubectl installed: $(kubeadm version -o short)"
else
    echo "  ➡ kubeadm already present, skip (version: $(kubeadm version -o short))"
fi

##############################################
# 3. Align containerd cgroup driver (k8s requires systemd)
# ----------------------------------------------------------------
# ⚠️ This step is **mandatory**.
# Lambda base image containerd defaults to cgroupfs cgroup driver,
# but k8s v1.30 requires systemd — mismatch causes:
#   - kubelet continuous SIGTERM restart
#   - control plane (etcd / apiserver) enters CrashLoopBackOff
#   - kubeadm init hangs at "waiting for control plane to be healthy"
# Hit the same issue on laptop; enforce SystemdCgroup=true here.
#
# Order matters: this step writes only SystemdCgroup; nvidia runtime injection
# left for launch.sh Phase 2.5 (nvidia-ctk runtime configure needs incremental
# changes on a config with SystemdCgroup=true already).
##############################################
echo "[4/6] Align containerd cgroup driver = systemd"
if ! command -v containerd >/dev/null 2>&1; then
    echo "  ⚠️  containerd not installed — Lambda image should have it, check system"
    exit 1
fi

sudo systemctl enable containerd >/dev/null 2>&1 || true
sudo mkdir -p /etc/containerd

if [ ! -f /etc/containerd/config.toml ] || ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
    echo "  ➡ /etc/containerd/config.toml is not SystemdCgroup=true, regenerating"
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    sudo systemctl restart containerd
    echo "  ✓ Wrote SystemdCgroup=true and restarted containerd"
else
    echo "  ✓ /etc/containerd/config.toml already has SystemdCgroup=true, keep"
fi

##############################################
# 4. Helm
# ----------------------------------------------------------------
# kube-prometheus-stack / argocd-image-updater / argo-cd are all
# installed via helm charts, so helm is required.
##############################################
echo "[5/6] Install Helm"
if ! command -v helm >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "  ✓ Helm installed: $(helm version --short)"
else
    echo "  ➡ Helm already present, skip ($(helm version --short))"
fi

##############################################
# 5. Auto-configure MIG (A100 80GB, mixed profile layout)
# ----------------------------------------------------------------
# Layout (consumes the full 7-GPC budget on a single A100 80GB):
#
#   ┌──────────────────┬─────────┬───────────────────────────────────┐
#   │ MIG profile      │ Count   │ Purpose                           │
#   ├──────────────────┼─────────┼───────────────────────────────────┤
#   │ 3g.40gb          │   1     │ Qwen 14B  (exclusive, no sharing) │
#   │ 2g.20gb          │   1     │ Qwen 7B   (exclusive, no sharing) │
#   │ 1g.10gb          │   2     │ small models pool (time-sliced)   │
#   └──────────────────┴─────────┴───────────────────────────────────┘
#
#   GPC budget : 3 + 2 + 1 + 1 = 7 ✓
#   VRAM total : 40 + 20 + 10 + 10 = 80 GB ✓
#   K8s sees   : nvidia.com/mig-3g.40gb, nvidia.com/mig-2g.20gb,
#                nvidia.com/mig-1g.10gb (with replicas=4 per MIG via
#                time-slicing → 8 schedulable slots for small models)
#
# Why 2× 1g.10gb instead of 1× 2g.20gb for the small pool:
#   With nvidia-device-plugin `mixed` strategy, K8s sees two same-profile
#   MIG instances as a single fungible resource — you can't say "Qwen 7B
#   gets one 2g.20gb exclusively and the other gets shared". Using a
#   distinct profile (1g.10gb) for the pool gives K8s a clean way to
#   keep Qwen 7B's MIG truly exclusive.
#
# Fully automatic & idempotent: enables MIG if needed, cleans up
# partial state, dynamically queries profile IDs (driver version
# independent), and skips creation when the expected 4-instance layout
# is already in place.
#
# ⚠️ Prerequisite: no CUDA processes on GPU, else -mig 1 fails.
# Lambda bare metal usually fine at boot.
##############################################
echo "[6/6] Auto-configure MIG (1× 3g.40gb + 1× 2g.20gb + 2× 1g.10gb)"

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "  ⚠️  nvidia-smi not found — Lambda image should have driver, check system"
    exit 1
fi

# ---- 5.1 Enable MIG mode ----
MIG_MODE=$(nvidia-smi -i 0 --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null | tr -d ' ')
echo "  ➡ Current MIG mode = ${MIG_MODE}"

if [ "$MIG_MODE" != "Enabled" ]; then
    echo "  ➡ MIG not enabled, enabling..."
    if sudo nvidia-smi -i 0 -mig 1; then
        echo "  ✓ MIG mode enabled"
    else
        echo "  ⚠️  nvidia-smi -mig 1 failed"
        echo "      Most common cause: CUDA processes still running on GPU"
        echo "      Check: nvidia-smi   (see if Processes table is empty)"
        echo "      If processes exist: kill them and re-run this script"
        echo "      If no processes and still fails: usually needs machine restart"
        exit 1
    fi
fi

# ---- 5.2 Count current instances (target = 4) ----
TARGET_COUNT=4
MIG_INSTANCES=$(nvidia-smi -L 2>/dev/null | grep -c "MIG" || true)
echo "  ➡ Current MIG instance count = ${MIG_INSTANCES} (target=${TARGET_COUNT})"

# Verify existing layout matches expectation before skipping
if [ "$MIG_INSTANCES" -eq "$TARGET_COUNT" ]; then
    EXISTING_3G=$(nvidia-smi -L 2>/dev/null | grep -c "MIG 3g\.40gb" || true)
    EXISTING_2G=$(nvidia-smi -L 2>/dev/null | grep -c "MIG 2g\.20gb" || true)
    EXISTING_1G=$(nvidia-smi -L 2>/dev/null | grep -c "MIG 1g\.10gb" || true)
    if [ "$EXISTING_3G" -eq 1 ] && [ "$EXISTING_2G" -eq 1 ] && [ "$EXISTING_1G" -eq 2 ]; then
        echo "  ✓ Layout already correct (3g.40gb×1 + 2g.20gb×1 + 1g.10gb×2), skip creation"
        SKIP_CREATE=1
    else
        echo "  ➡ ${MIG_INSTANCES} instances exist but layout differs (3g=${EXISTING_3G}, 2g=${EXISTING_2G}, 1g=${EXISTING_1G}); will rebuild"
        SKIP_CREATE=0
    fi
else
    SKIP_CREATE=0
fi

if [ "${SKIP_CREATE:-0}" -ne 1 ]; then
    # ---- 5.3 Clean up any residual instances ----
    if [ "$MIG_INSTANCES" -gt 0 ]; then
        echo "  ➡ Destroying all existing CI + GI to start fresh"
        # Order matters: must destroy CI first, then GI
        sudo nvidia-smi mig -dci 2>/dev/null || true
        sudo nvidia-smi mig -dgi 2>/dev/null || true
    fi

    # ---- 5.4 Dynamically query profile IDs (driver-version independent) ----
    # `nvidia-smi mig -lgip` lists rows like:
    #   |   0  MIG 3g.40gb        9      1/1        40192 MB ...
    #   |   0  MIG 2g.20gb       14      2/2        19968 MB ...
    #   |   0  MIG 1g.10gb       19      4/4         9728 MB ...
    # 5th whitespace-token (after the leading "|") is the profile ID.
    query_profile_id() {
        local label="$1"
        nvidia-smi mig -lgip 2>/dev/null \
          | grep -E "MIG[[:space:]]+${label}([[:space:]]|$)" \
          | head -1 \
          | awk '{print $5}'
    }

    PID_3G=$(query_profile_id '3g\.40gb')
    PID_2G=$(query_profile_id '2g\.20gb')
    PID_1G=$(query_profile_id '1g\.10gb')

    for triple in "3g.40gb:${PID_3G}" "2g.20gb:${PID_2G}" "1g.10gb:${PID_1G}"; do
        label=${triple%%:*}
        pid=${triple##*:}
        if [ -z "$pid" ]; then
            echo "  ⚠️  Cannot find profile ${label} — wrong GPU model?"
            echo "      Available profiles on this card:"
            nvidia-smi mig -lgip
            echo ""
            echo "      Reminder: this layout is for A100 80GB. On A100 40GB"
            echo "      the largest profile is 3g.20gb (not 3g.40gb)."
            exit 1
        fi
    done
    echo "  ➡ Profile IDs:   3g.40gb=${PID_3G}, 2g.20gb=${PID_2G}, 1g.10gb=${PID_1G}"

    # ---- 5.5 Create 4 GI + CI ----
    # Order matters: nvidia-smi places GIs in decreasing-size order, so
    # listing 3g first guarantees it gets the contiguous slice it needs.
    # `-C` auto-creates the default (full-size) Compute Instance inside
    # each GI in one shot.
    echo "  ➡ Creating GI+CI: 1× 3g.40gb, 1× 2g.20gb, 2× 1g.10gb"
    sudo nvidia-smi mig -cgi \
        "${PID_3G},${PID_2G},${PID_1G},${PID_1G}" \
        -C

    # ---- 5.6 Verify ----
    FINAL_COUNT=$(nvidia-smi -L 2>/dev/null | grep -c "MIG" || true)
    FINAL_3G=$(nvidia-smi -L 2>/dev/null | grep -c "MIG 3g\.40gb" || true)
    FINAL_2G=$(nvidia-smi -L 2>/dev/null | grep -c "MIG 2g\.20gb" || true)
    FINAL_1G=$(nvidia-smi -L 2>/dev/null | grep -c "MIG 1g\.10gb" || true)
    if [ "$FINAL_COUNT" -eq "$TARGET_COUNT" ] && [ "$FINAL_3G" -eq 1 ] && [ "$FINAL_2G" -eq 1 ] && [ "$FINAL_1G" -eq 2 ]; then
        echo "  ✓ MIG layout created (3g.40gb×1 + 2g.20gb×1 + 1g.10gb×2)"
    else
        echo "  ⚠️  Got 3g=${FINAL_3G}, 2g=${FINAL_2G}, 1g=${FINAL_1G} (total=${FINAL_COUNT}, expected 1/1/2). Check:"
        nvidia-smi -L
        exit 1
    fi
fi

echo ""
echo "===== Lambda A100 all_install.sh complete ====="
echo ""
echo "Final MIG status confirmation:"
nvidia-smi -L | grep MIG || echo "  (empty — abnormal, review log above)"
echo ""
echo "Next step: sudo bash script/lambda/launch.sh"
