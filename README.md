# Proxmox NixOS LXC Manager

This script simplifies the creation and management of NixOS containers in Proxmox VE.

## Features

- **Interactive & Non-Interactive Modes**: Run with a user-friendly `whiptail` interface or automate with command-line flags.
- **Simplified Configuration**: Uses `pct push` to configure containers, avoiding the need to mount ZFS/LVM filesystems.
- **Proper NixOS Management**: Manages NixOS configurations correctly within the container.
- **Automated Setup**: Handles downloading the NixOS image and setting up the container environment.

## Quick Start

You can run the script directly from GitHub without needing to download it first:

```bash
curl -sL https://raw.githubusercontent.com/devnullvoid/proxmox-nixos-lxc/main/proxmox-nixos-lxc.sh | sudo bash -s create
```

## Usage

```
proxmox-nixos-lxc.sh <action> [options]
```

### Actions

- `create`: Creates a new NixOS container. Can be run interactively or with command-line flags.
- `shell <ctid>`: Enters the shell of a specified container.
- `update <ctid>`: Updates the NixOS configuration for a specified container.
- `configure <ctid>`: Configures user password and SSH keys for a container.
- `download`: Downloads the NixOS image to the Proxmox template cache.
- `help`: Displays the help message.

### `create` Options

When using the `create` action non-interactively, you can use the following flags:

- `--id <id>`: Container ID.
- `--name <name>`: Container hostname.
- `--cpus <count>`: Number of CPU cores.
- `--memory <mb>`: RAM in megabytes.
- `--swap <mb>`: Swap in megabytes.
- `--disk <gb>`: Disk size in gigabytes.
- `--storage <pool>`: Proxmox storage pool.
- `--bridge <bridge>`: Network bridge.
- `--ip <ip/cidr|dhcp>`: IP address with CIDR or `dhcp`.
- `--gw <gateway>`: Network gateway.
- `--dns <server>`: DNS server.
- `--tags <tags>`: Comma-separated tags.
- `--unprivileged <0|1>`: Unprivileged container.
- `--nesting <0|1>`: Enable nesting.
- `--password <password>`: Root password.
- `--ssh-keys <path>`: Path to public SSH keys file.
- `--start-on-boot <0|1>`: Start container on boot.

### Example: Create a Container Non-Interactively

```bash
sudo ./proxmox-nixos-lxc.sh create \
    --id 123 \
    --name my-nixos-vm \
    --cpus 2 \
    --memory 2048 \
    --disk 10 \
    --storage local-lvm \
    --bridge vmbr0 \
    --ip dhcp \
    --password "a-very-secure-password" \
    --ssh-keys "~/.ssh/id_rsa.pub"
```
