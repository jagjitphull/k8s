#!/bin/bash

set -e  # Exit on error
set -o pipefail  # Stop execution if any command in a pipeline fails

# Function to log messages
log() {
  echo -e "\e[1;32m[INFO]\e[0m $1"
}

# Function to detect the host system's IP address
detect_host_ip() {
  ip route get 1.1.1.1 | awk '{print $7; exit}'
}

# Function to get the current hostname
get_current_hostname() {
  hostnamectl status --static
}

# Function to update /etc/hosts dynamically
update_hosts() {
  local host_ip
  host_ip=$(detect_host_ip)
  local host_name
  host_name=$(get_current_hostname)

  log "Detected Host IP: $host_ip"
  log "Current Hostname: $host_name"

  # Ensure entry for current host exists in /etc/hosts
  if ! grep -q "$host_ip" /etc/hosts; then
    echo "$host_ip $host_name" | sudo tee -a /etc/hosts
    log "Added $host_ip $host_name to /etc/hosts."
  else
    log "/etc/hosts already contains an entry for this host."
  fi
}

# Function to set hostname dynamically based on detected IP
set_hostname() {
  local host_ip
  host_ip=$(detect_host_ip)

  if [[ "$host_ip" =~ ^192\.168\.1\. ]]; then
    local node_number=${host_ip##*.}  # Extract last octet of IP
    local new_hostname="node-$node_number"

    if [[ "$(get_current_hostname)" != "$new_hostname" ]]; then
      sudo hostnamectl set-hostname "$new_hostname"
      log "Hostname set to $new_hostname."
    else
      log "Hostname is already set to $new_hostname."
    fi
  else
    log "IP address does not match expected pattern; hostname not changed."
  fi
}

# Function to install Docker dependencies and configure repository
setup_docker_repo() {
  log "Setting up Docker repository..."
  sudo mkdir -p /etc/apt/keyrings
  if [ ! -f "/etc/apt/keyrings/docker.gpg" ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
}

# Function to configure kernel modules for Kubernetes
configure_kernel_modules() {
  log "Configuring kernel modules..."
  cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
  sudo modprobe overlay
  sudo modprobe br_netfilter
}

# Function to configure sysctl settings for Kubernetes
configure_sysctl() {
  log "Applying sysctl parameters..."
  cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sudo sysctl --system
}

# Function to disable swap permanently
disable_swap() {
  log "Disabling swap..."
  sudo swapoff -a
  sudo sed -i '/ swap / s/^/#/' /etc/fstab  # Comment out swap in fstab to persist after reboot
}

# Function to install required packages
install_packages() {
  log "Installing required packages..."
  sudo apt-get update -y
  sudo apt-get install -y software-properties-common curl apt-transport-https ca-certificates bash-completion
}

# Function to install containerd
install_containerd() {
  log "Installing containerd..."
  sudo apt-get install -y containerd.io
  sudo mkdir -p /etc/containerd
  containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
  sudo sed -i "s/SystemdCgroup = false/SystemdCgroup = true/g" /etc/containerd/config.toml
  sudo systemctl restart containerd
}

# Function to install Kubernetes components
install_kubernetes() {
  KUBERNETES_VERSION=1.29
  log "Setting up Kubernetes repository..."

  sudo mkdir -p /etc/apt/keyrings
  if [ ! -f "/etc/apt/keyrings/kubernetes-apt-keyring.gpg" ]; then
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v$KUBERNETES_VERSION/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  fi

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$KUBERNETES_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

  log "Installing kubeadm, kubelet, and kubectl..."
  sudo apt-get update -y
  sudo apt-get install -y kubelet kubeadm kubectl
}

# Function to enable bash completion for kubectl
enable_kubectl_completion() {
  log "Enabling kubectl bash completion..."
  echo 'source <(kubectl completion bash)' >>~/.bashrc
  source ~/.bashrc
}

# Function to install CRI-O (optional)
install_crio() {
  log "Installing CRI-O..."
  sudo mkdir -p /etc/apt/keyrings
  if [ ! -f "/etc/apt/keyrings/cri-o-apt-keyring.gpg" ]; then
    curl -fsSL https://pkgs.k8s.io/addons:/cri-o:/prerelease:/main/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
  fi

  echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/prerelease:/main/deb/ /" | sudo tee /etc/apt/sources.list.d/cri-o.list

  sudo apt-get update -y
  sudo apt-get install -y cri-o
  sudo systemctl daemon-reload
  sudo systemctl enable crio --now
  sudo systemctl start crio.service
}

# Main execution
log "Starting Kubernetes setup script..."
update_hosts
set_hostname
setup_docker_repo
configure_kernel_modules
configure_sysctl
disable_swap
install_packages
install_containerd
install_kubernetes
enable_kubectl_completion

log "Kubernetes setup completed successfully."
