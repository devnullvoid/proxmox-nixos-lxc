# Proxmox NixOS LXC Manager

A streamlined script for creating and managing NixOS containers in Proxmox VE with secure defaults, template support, and flake integration.

## ✨ Features

- **Interactive & Non-Interactive Modes**: Friendly `whiptail` interface or fully scriptable with command-line flags
- **Template System**: Pre-configured NixOS configurations for common use cases
- **Flake Support**: Use Nix flakes for reproducible configurations
- **Secure Defaults**: Containers are unprivileged with nesting enabled by default
- **Smart Network Configuration**: DHCP enabled by default with automatic host DNS inheritance
- **Minimal Configuration**: Only essential parameters required, with sensible defaults for everything else
- **Recreate Commands**: Automatically generates re-creation commands for easy container duplication
- **NixOS-First**: Properly handles NixOS configuration and updates within the container

## 🚀 Quick Start

Run the script directly from GitHub (requires `sudo`):

```bash
curl -sL https://raw.githubusercontent.com/devnullvoid/proxmox-nixos-lxc/main/proxmox-nixos-lxc.sh | sudo bash -s create
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
- `templates`: List available templates
- `template-info <name>`: Show detailed template information
- `help`: Show help message and usage examples

### ⚙️ `create` Options

When running non-interactively, you can specify these options:

#### Container Settings
- `--id <id>`: Container ID (auto-detected if not specified)
- `--name <name>`: Container hostname (required)
- `--cpus <count>`: Number of CPU cores (default: 1)
- `--memory <mb>`: RAM in MB (default: 1024)
- `--swap <mb>`: Swap space in MB (default: 512)
- `--disk <gb>`: Disk size in GB (default: 8)
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

#### Template & Flake Options
- `--template <name>`: Use template configuration
- `--flake-url <url>`: Use Nix flake URL
- `--flake-ref <ref>`: Flake reference (optional)
- `--flake-input <input>`: Flake input (optional)

## 🎯 Templates

The script includes several pre-configured templates for common use cases:

### Available Templates

- **minimal**: Basic NixOS container with essential tools
- **webserver**: Nginx web server with SSL support
- **database**: PostgreSQL database server with backup configuration

### Using Templates

```bash
# List available templates
sudo ./proxmox-nixos-lxc.sh templates

# Show template information
sudo ./proxmox-nixos-lxc.sh template-info webserver

# Create container with template
sudo ./proxmox-nixos-lxc.sh create \
    --name my-webserver \
    --template webserver \
    --memory 2048 \
    --disk 20
```

### Template Structure

Each template includes:
- `configuration.nix`: NixOS configuration
- `metadata.json`: Template metadata and requirements
- `README.md`: Detailed documentation

## 🔧 Flake Support

Use Nix flakes for reproducible configurations:

```bash
# Create container with flake
sudo ./proxmox-nixos-lxc.sh create \
    --name my-flake-app \
    --flake-url "github:owner/repo" \
    --flake-ref "main" \
    --flake-input "myApp" \
    --memory 2048
```

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

### Web Server with Template
```bash
sudo ./proxmox-nixos-lxc.sh create \
    --name my-website \
    --template webserver \
    --memory 2048 \
    --disk 20 \
    --password "secure-password"
```

### Database Server with Template
```bash
sudo ./proxmox-nixos-lxc.sh create \
    --name my-database \
    --template database \
    --memory 4096 \
    --disk 50 \
    --cpus 4 \
    --password "secure-password"
```

## 🔄 Updating Containers

To update NixOS packages in a container:
```bash
sudo ./proxmox-nixos-lxc.sh update 101
```

## 🔒 Security Notes

- Containers are created as unprivileged by default for better security
- Always use strong passwords or SSH keys for authentication
- Templates include appropriate firewall rules and security configurations
- The script will show a re-creation command after successful container creation for easy duplication

## 📁 Template Development

### Creating Custom Templates

1. Create a new directory in `templates/`:
   ```bash
   mkdir -p templates/my-template
   ```

2. Add required files:
   - `configuration.nix`: NixOS configuration
   - `metadata.json`: Template metadata
   - `README.md`: Documentation

3. Template variables can be used in configuration.nix:
   - `{{HOSTNAME}}`: Container hostname
   - `{{PASSWORD}}`: Root password
   - `{{SSH_KEYS}}`: SSH public keys
   - Custom variables defined in metadata.json

### Template Metadata Format

```json
{
  "name": "Template Name",
  "description": "Template description",
  "version": "1.0.0",
  "category": "category",
  "tags": ["tag1", "tag2"],
  "ports": [80, 443],
  "resources": {
    "min_cpus": 1,
    "min_memory": 1024,
    "min_disk": 8
  },
  "variables": {
    "custom_var": "default_value"
  },
  "post_install": [
    "Step 1",
    "Step 2"
  ]
}
```
