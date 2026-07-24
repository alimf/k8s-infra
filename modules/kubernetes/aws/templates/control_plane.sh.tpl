#!/bin/bash
# Bootstrap script for Kubernetes control plane node.
# Rendered by Terraform templatefile(); $${VAR} escapes become $${VAR} in the final script.
set -euo pipefail
exec > >(tee /var/log/k8s-control-plane-bootstrap.log) 2>&1

echo "[bootstrap] Control plane init started at $$(date)"

# ── Terraform-injected variables ──────────────────────────────
CLUSTER_NAME="${cluster_name}"
K8S_VERSION="${kubernetes_version}"
CALICO_VERSION="${calico_version}"
API_ENDPOINT="${api_server_endpoint}"
POD_CIDR="${pod_cidr}"
SERVICE_CIDR="${service_cidr}"
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

# ── Install kubeadm / kubelet / kubectl ───────────────────────
echo "[bootstrap] Installing Kubernetes $${K8S_VERSION}"

K8S_MINOR=$$(echo "$${K8S_VERSION}" | cut -d. -f1,2)

curl -fsSL "https://pkgs.k8s.io/core:/stable:/v$${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v$${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y "kubelet=$${K8S_VERSION}-*" "kubeadm=$${K8S_VERSION}-*" "kubectl=$${K8S_VERSION}-*"
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

# ── kubeadm init ──────────────────────────────────────────────
echo "[bootstrap] Running kubeadm init"

cat > /etc/kubeadm-config.yaml <<KUBEADM
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
clusterName: $${CLUSTER_NAME}
kubernetesVersion: "v$${K8S_VERSION}"
controlPlaneEndpoint: "$${API_ENDPOINT}:6443"
networking:
  podSubnet: "$${POD_CIDR}"
  serviceSubnet: "$${SERVICE_CIDR}"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
KUBEADM

kubeadm init --config /etc/kubeadm-config.yaml --upload-certs

# ── kubectl setup ─────────────────────────────────────────────
echo "[bootstrap] Configuring kubectl"

mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config

if id ubuntu &>/dev/null; then
  mkdir -p /home/ubuntu/.kube
  cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
  chown -R ubuntu:ubuntu /home/ubuntu/.kube
fi

# ── Install Calico CNI ────────────────────────────────────────
echo "[bootstrap] Installing Calico CNI v$${CALICO_VERSION}"

kubectl --kubeconfig=/etc/kubernetes/admin.conf create -f \
  "https://raw.githubusercontent.com/projectcalico/calico/v$${CALICO_VERSION}/manifests/calico.yaml"

# ── Publish worker join command via SSM ───────────────────────
echo "[bootstrap] Writing worker join command to SSM $${SSM_PATH}"

JOIN_CMD=$$(kubeadm token create --print-join-command 2>/dev/null)

aws ssm put-parameter \
  --region "$${AWS_REGION}" \
  --name  "$${SSM_PATH}" \
  --value "$${JOIN_CMD}" \
  --type  SecureString \
  --overwrite

echo "[bootstrap] Control plane ready at $$(date)"
