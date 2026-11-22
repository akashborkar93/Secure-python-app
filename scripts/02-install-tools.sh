#!/usr/bin/env bash
# =============================================================================
# 02-install-tools.sh  -  Install every tool we need on the EC2 workstation
# =============================================================================
# Run this ON the Ubuntu 24.04 server (as the normal "ubuntu" user):
#     bash 02-install-tools.sh
#
# Tools installed and what each one is for:
#   git        - download/upload code from GitHub
#   Docker     - build and run container images
#   AWS CLI v2 - talk to AWS from the command line
#   Terraform  - create AWS infrastructure from code
#   kubectl    - talk to a Kubernetes cluster
#   Helm       - install packaged apps on Kubernetes
#   k3s        - a small, real Kubernetes that runs on this one server (Stage A only)
# =============================================================================

# Stop immediately if any command fails, and treat unset variables as errors.
set -euo pipefail

echo "==> 1/8 Updating the package list and installing basic helpers"
sudo apt-get update -y
# curl = download files, unzip = open zip files, gnupg = verify downloads,
# jq = read JSON, ca-certificates = trust HTTPS sites.
sudo apt-get install -y curl unzip gnupg jq git ca-certificates apt-transport-https

echo "==> 2/8 Adding 2 GB of swap (extra 'virtual memory') so the 4 GB server doesn't run out"
if [ ! -f /swapfile ]; then
  sudo fallocate -l 2G /swapfile       # create a 2 GB empty file
  sudo chmod 600 /swapfile             # only root may read it
  sudo mkswap /swapfile                # format it as swap
  sudo swapon /swapfile                # turn it on now
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab   # keep it after reboot
fi

echo "==> 3/8 Installing Docker"
# Official Docker install script from docker.com.
curl -fsSL https://get.docker.com | sudo sh
# Let the 'ubuntu' user run docker without typing sudo (takes effect on next login).
sudo usermod -aG docker ubuntu

echo "==> 4/8 Installing AWS CLI v2"
if ! command -v aws >/dev/null; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  sudo /tmp/aws/install
fi

echo "==> 5/8 Installing Terraform (from HashiCorp's official package repository)"
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
sudo apt-get update -y
sudo apt-get install -y terraform

echo "==> 6/8 Installing kubectl (from the official Kubernetes package repository)"
# NOTE: kubectl must be within 1 minor version of the cluster. k3s "stable" is v1.37, so use v1.37.
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key | sudo gpg --dearmor --yes -o /usr/share/keyrings/kubernetes.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
sudo apt-get update -y
sudo apt-get install -y kubectl

echo "==> 7/8 Installing Helm"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "==> 8/8 Installing k3s (small Kubernetes) for Stage A"
# --disable traefik : we will use Envoy Gateway (Gateway API) instead of k3s's built-in ingress.
# --write-kubeconfig-mode 644 : lets our normal user read the cluster login file.
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh -
# Tell kubectl and helm where the cluster login file is (now and in future logins).
mkdir -p "$HOME/.kube"
cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
grep -q 'KUBECONFIG' "$HOME/.bashrc" || echo 'export KUBECONFIG=$HOME/.kube/config' >> "$HOME/.bashrc"
export KUBECONFIG="$HOME/.kube/config"

echo
echo "==================== Versions installed ===================="
git --version
sudo docker --version
aws --version
terraform version | head -1
kubectl version --client | head -1
helm version --short
echo "---- Kubernetes node status (should say Ready) ----"
kubectl wait --for=condition=Ready node --all --timeout=120s
kubectl get nodes
