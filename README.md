# Proxmox NixOS LXC Manager

A streamlined script for creating and managing NixOS containers in Proxmox VE with secure defaults and an intuitive interface.

## ✨ Features

- **Interactive & Non-Interactive Modes**: Friendly `whiptail` interface or fully scriptable with command-line flags
- **Secure Defaults**: Containers are unprivileged with nesting enabled by default
- **Smart Network Configuration**: DHCP enabled by default with automatic host DNS inheritance
- **Minimal Configuration**: Only essential parameters required, with sensible defaults for everything else
- **Recreate Commands**: Automatically generates re-creation commands for easy container duplication
- **NixOS-First**: Properly handles NixOS configuration and updates within the container

## 🚀 Quick Start

### Option 1: Run from GitHub (Development Version)
```bash
# Download and run the latest development version
curl -sL https://raw.githubusercontent.com/devnullvoid/proxmox-nixos-lxc/main/proxmox-nixos-lxc.sh | sudo bash -s create
```

### Option 2: Clone and Run Locally (Recommended)
```bash
# Clone the repository
git clone https://github.com/devnullvoid/proxmox-nixos-lxc.git
cd proxmox-nixos-lxc

# Make executable and run
chmod +x proxmox-nixos-lxc.sh
sudo ./proxmox-nixos-lxc.sh create
```



## 📋 Usage

```
proxmox-nixos-lxc.sh <action> [options]
```

### 🔧 Available Actions

- `create`: Interactive container creation with guided prompts
- `shell <ctid>`: Enter the shell of a specified container
- `update <ctid>`: Update NixOS packages and configuration in a container
- `download`: Download the NixOS image to Proxmox template cache
- `help`: Show help message and usage examples

### ⚙️ `create` Options

When running non-interactively, you can specify these options:

#### Container Settings
- `--id <id>`: Container ID (auto-detected if not specified)
- `--name <name>`: Container hostname (required)
- `--cpus <count>`: Number of CPU cores (default: 2)
- `--memory <mb>`: RAM in MB (default: 2048)
- `--swap <mb>`: Swap space in MB (default: 512)
- `--disk <gb>`: Disk size in GB (default: 10)
- `--storage <pool>`: Storage pool (default: local-lvm)
- `--tags <tags>`: Comma-separated tags (optional)

#### Network Settings
- `--bridge <bridge>`: Network bridge (default: vmbr0)
- `--ip <ip/cidr|dhcp>`: IP address with CIDR or 'dhcp' (default: dhcp)
- `--gw <gateway>`: Network gateway (required with static IP)
- `--dns <server>`: DNS server (optional, inherits from host by default)

#### Security & Access
- `--password <password>`: Set root password (optional but recommended)
- `--ssh-keys <path>`: Path to public SSH keys file (optional)
- `--no-start-on-boot`: Disable auto-start on boot (enabled by default)
- `--no-unprivileged`: Run as privileged container (not recommended)
- `--no-nesting`: Disable container nesting (nesting enabled by default)

## 📌 Examples

### Interactive Container Creation
```bash
sudo ./proxmox-nixos-lxc.sh create
```

### Non-Interactive Example with Static IP
```bash
sudo ./proxmox-nixos-lxc.sh create \
    --name my-nixos-app \
    --cpus 2 \
    --memory 2048 \
    --disk 20 \
    --storage local-lvm \
    --bridge vmbr0 \
    --ip 192.168.1.100/24 \
    --gw 192.168.1.1 \
    --dns 1.1.1.1 \
    --password "your-secure-password" \
    --ssh-keys ~/.ssh/id_rsa.pub
```

### Minimal Non-Interactive Example (DHCP)
```bash
sudo ./proxmox-nixos-lxc.sh create \
    --name minimal-nixos \
    --password "another-secure-password"
```

## 🔄 Updating Containers

To update NixOS packages in a container:
```bash
sudo ./proxmox-nixos-lxc.sh update 101
```

## 🔧 Development Workflow

When developing or testing the script:

1. **Edit locally**: Make changes to `proxmox-nixos-lxc.sh` on your development machine
2. **Copy to Proxmox host**: Use `scp` to copy the script to your Proxmox environment
3. **Test**: Run the script on the Proxmox host to verify changes
4. **Commit and push**: Once tested, commit changes and push to GitHub

```bash
# Example workflow
scp proxmox-nixos-lxc.sh your-proxmox-host:/tmp/proxmox-nixos-lxc-test.sh
ssh your-proxmox-host
sudo chmod +x /tmp/proxmox-nixos-lxc-test.sh
sudo /tmp/proxmox-nixos-lxc-test.sh create
```

**Note**: The script must be run on the Proxmox host since it uses Proxmox-specific commands (`pct`, `pvesm`, etc.).

## 🔒 Security Notes

- Containers are created as unprivileged by default for better security
- Always use strong passwords or SSH keys for authentication
- The script will show a re-creation command after successful container creation for easy duplication
