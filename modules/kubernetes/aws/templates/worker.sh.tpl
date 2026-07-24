#!/bin/bash
# Bootstrap script for Kubernetes worker node.
# Rendered by Terraform templatefile(); $${VAR} escapes become $${VAR} in the final script.
set -euo pipefail
exec > >(tee /var/log/k8s-worker-bootstrap.log) 2>&1

echo "[bootstrap] Worker init started at $$(date)"

# ── Terraform-injected variables ──────────────────────────────
K8S_VERSION="${kubernetes_version}"
AWS_REGION="${aws_region}"
SSM_PATH="${ssm_join_command_path}"

# ── System prerequisites ──────────────────────────────────────
echo "[bootstrap] Disabling swap and loading kernel modules"

swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

cat > /etc/modules-load.d/k8s.conf <<'MODULES'
overlay
br_netfilter
MODULES

modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<'SYSCTL'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL

sysctl --system

# ── Install containerd ────────────────────────────────────────
echo "[bootstrap] Installing containerd"

apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

UBUNTU_CODENAME=$$(. /etc/os-release && echo "$${UBUNTU_CODENAME:-$${VERSION_CODENAME}}")
echo "deb [arch=$$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $${UBUNTU_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y containerd.io

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# ── Install kubeadm / kubelet ─────────────────────────────────
echo "[bootstrap] Installing Kubernetes $${K8S_VERSION}"

K8S_MINOR=$$(echo "$${K8S_VERSION}" | cut -d. -f1,2)

curl -fsSL "https://pkgs.k8s.io/core:/stable:/v$${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v$${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y "kubelet=$${K8S_VERSION}-*" "kubeadm=$${K8S_VERSION}-*"
apt-mark hold kubelet kubeadm
systemctl enable kubelet

# ── Wait for and execute join command from SSM ────────────────
echo "[bootstrap] Waiting for join command in SSM $${SSM_PATH}"

MAX_RETRIES=40
RETRY_INTERVAL=30

for i in $$(seq 1 $${MAX_RETRIES}); do
  JOIN_CMD=$$(aws ssm get-parameter \
    --region "$${AWS_REGION}" \
    --name   "$${SSM_PATH}" \
    --with-decryption \
    --query  Parameter.Value \
    --output text 2>/dev/null) && break
  echo "[bootstrap] Attempt $${i}/$${MAX_RETRIES}: control plane not ready, retrying in $${RETRY_INTERVAL}s..."
  sleep $${RETRY_INTERVAL}
done

if [ -z "$${JOIN_CMD:-}" ]; then
  echo "[bootstrap] ERROR: no join command found after $${MAX_RETRIES} attempts"
  exit 1
fi

echo "[bootstrap] Executing join"
eval "$${JOIN_CMD}"

echo "[bootstrap] Worker ready at $$(date)"
