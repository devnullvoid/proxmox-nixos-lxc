#!/usr/bin/env bash
set -euo pipefail

# Proxmox NixOS LXC Container Manager
#
# Features:
# - Interactive setup with whiptail or non-interactive via command line
# - Uses pct push for configuration (no LVM/ZFS mounting required)
# - Proper NixOS configuration management
# - Automatic environment setup for containers
#
# Usage:
#   Create a new container: $0 create [options]
#   Enter container shell:  $0 shell <container-id>
#   Update container:       $0 update <container-id>
#   Show help:              $0 help

# --- Default Configuration ---
NIXOS_VERSION="25.05"
CT_ID=""
CT_NAME=""
CT_CPUS="2"
CT_MEMORY="2048"
CT_SWAP="512"
CT_DISK="8"
CT_STORAGE="local-lvm"
CT_BRIDGE="vmbr0"
CT_IP=""
CT_CIDR="24"
CT_GW=""
CT_DNS="1.1.1.1"
CT_TAGS="nixos"
CT_UNPRIVILEGED="0"
CT_NESTING="1"
CT_PASSWORD=""
CT_SSH_KEYS=""
CT_START_ON_BOOT="1"

# --- Utility Functions ---

# Check if running in an interactive terminal
INTERACTIVE=false
if [ -t 0 ] && [ -t 1 ]; then
    INTERACTIVE=true
fi

msg_info() { echo -e "\e[32m[INFO]  $*\e[0m"; }
msg_warning() { echo -e "\e[33m[WARN]  $*\e[0m"; }
msg_error() {
    echo -e "\e[31m[ERROR] $*
\e[0m" >&2
    exit 1
}

get_next_ctid() {
    pvesh get /cluster/nextid
}

# --- Core Functions ---

prepare_nixos_image() {
    local version="$1"
    local image_name="nixos-${version}-x86_64-linux.tar.xz"
    local url="https://hydra.nixos.org/job/nixos/release-${version}/nixos.proxmoxLXC.x86_64-linux/latest/download-by-type/file/system-tarball"
    local cache_path="/var/lib/vz/template/cache/$image_name"

    if [ -f "$cache_path" ]; then
        msg_info "NixOS image already exists: $cache_path" >&2
    else
        msg_info "Downloading NixOS image from $url" >&2
        if ! wget -O "$cache_path" "$url"; then
            msg_error "Failed to download NixOS image. Please check version and network."
        fi
    fi

    # Ensure the template is in the correct location for Proxmox
    local template_dir="/var/lib/vz/template/cache"
    if [ ! -f "$template_dir/$image_name" ]; then
        cp "$cache_path" "$template_dir/"
    fi

    # Return the correct path format for pct create
    echo "local:vztmpl/$image_name"
}

configure_nixos_ct() {
    local ctid="$1"
    local hostname="$2"
    local password="$3"
    local ssh_keys_content="$4"

    msg_info "Configuring NixOS for container $ctid..."

    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf -- "$temp_dir"' EXIT

    # Determine if the container is privileged
    local is_privileged_bool="false"
    if [ "${CT_UNPRIVILEGED:-1}" -eq 0 ]; then
        is_privileged_bool="true"
    fi

    # --- Create configuration.nix ---
    cat >"${temp_dir}/configuration.nix" <<EOCONFIG
{ config, pkgs, lib, modulesPath, ... }: {
  imports = [
    ./hardware-configuration.nix
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  # Basic system settings
  boot.loader.grub.enable = false;
  networking.hostName = "$hostname";
  time.timeZone = "Etc/UTC";
  system.stateVersion = "${NIXOS_VERSION}";

  # Proxmox LXC settings
  nix.settings.sandbox = false;
  proxmoxLXC.privileged = ${is_privileged_bool};
  proxmoxLXC.manageNetwork = false;

  # SSH settings
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "yes";
    };
  };
  security.pam.services.sshd.allowNullPassword = true; # For root login with empty password

  users.users.root.openssh.authorizedKeys.keys = [
    $ssh_keys_content
  ];
}
EOCONFIG

    # --- Create setup-nixos.sh ---
    cat >"${temp_dir}/setup-nixos.sh" <<'EOSETUP'
#!/usr/bin/env sh
set -e

echo "[SETUP] Running NixOS setup script inside the container..."

# Set up the Nix environment for commands like nixos-rebuild
if [ -f /etc/set-environment ]; then
    . /etc/set-environment
fi

# Source environment variables passed from the host
if [ -f /etc/profile.d/nixos-lxc.sh ]; then
    . /etc/profile.d/nixos-lxc.sh
fi

echo "[SETUP] Generating hardware configuration..."
nixos-generate-config

if [ -n "$CT_PASSWORD" ]; then
    echo "[SETUP] Setting root password..."
    echo "root:$CT_PASSWORD" | chpasswd
fi

echo "[SETUP] Rebuilding NixOS system..."
nix-channel --update
nixos-rebuild switch --upgrade

echo "[SETUP] NixOS setup complete."
EOSETUP

    # --- Create environment file to pass password ---
    cat >"${temp_dir}/nixos-lxc.sh" <<EOENV
export CT_PASSWORD='${password}'
EOENV

    # --- Start container, push files, and run setup ---
    msg_info "Starting container $ctid..."
    pct start "$ctid" || true
    # Wait a moment for the container to initialize
    sleep 5

    msg_info "Pushing configuration files to container..."
    pct exec "$ctid" -- sh -c '[ -f /etc/set-environment ] && . /etc/set-environment; mkdir -p /etc/nixos /etc/profile.d'
    pct push "$ctid" "${temp_dir}/nixos-lxc.sh" /etc/profile.d/nixos-lxc.sh
    pct push "$ctid" "${temp_dir}/configuration.nix" /etc/nixos/configuration.nix
    pct push "$ctid" "${temp_dir}/setup-nixos.sh" /root/setup-nixos.sh --perms 0755

    msg_info "Running setup script inside container..."
    pct exec "$ctid" -- sh /root/setup-nixos.sh

    msg_info "NixOS container $ctid configured successfully."

    # Clean up the temporary directory and remove the trap
    rm -rf -- "$temp_dir"
    trap - EXIT
}

create_nixos_ct() {
    # Set defaults for DHCP and container name
    if [ -z "$CT_IP" ]; then CT_IP="dhcp"; fi
    if [ -z "$CT_ID" ]; then CT_ID=$(get_next_ctid); fi
    if [ -z "$CT_NAME" ]; then CT_NAME="nixos-ct-$CT_ID"; fi

    # Validate required parameters for static IP
    if [ "$CT_IP" != "dhcp" ] && [ -z "$CT_GW" ]; then
        msg_error "Gateway (--gw) is required when using a static IP."
    fi

    local template_path
    template_path=$(prepare_nixos_image "$NIXOS_VERSION")

    local ip_config="ip=${CT_IP}"
    if [ "$CT_IP" != "dhcp" ]; then
        ip_config+="/${CT_CIDR},gw=${CT_GW}"
    fi

    msg_info "Creating NixOS container (ID: $CT_ID, Name: $CT_NAME)..."
    pct create "$CT_ID" "$template_path" \
        --hostname "$CT_NAME" --storage "$CT_STORAGE" --cores "$CT_CPUS" \
        --memory "$CT_MEMORY" --swap "$CT_SWAP" --rootfs "${CT_STORAGE}:${CT_DISK}" \
        --onboot "$CT_START_ON_BOOT" --unprivileged "$CT_UNPRIVILEGED" \
        --tags "$CT_TAGS" --nameserver "$CT_DNS" \
        --net0 "name=eth0,bridge=${CT_BRIDGE},${ip_config}"

    pct set "$CT_ID" --arch amd64 --features "nesting=$CT_NESTING"

    local ssh_keys_content=""
    if [ -n "$CT_SSH_KEYS" ] && [ -f "$CT_SSH_KEYS" ]; then
        ssh_keys_content=$(sed 's/.*/"&"/' "$CT_SSH_KEYS" | tr '\n' ' ')
    fi

    configure_nixos_ct "$CT_ID" "$CT_NAME" "$CT_PASSWORD" "$ssh_keys_content"
}

enter_container() {
    msg_info "Entering container $1..."
    pct exec "$1" -- /bin/sh -c 'if [ -f /etc/set-environment ]; then . /etc/set-environment; fi; exec bash'
}

update_nixos() {
    msg_info "Updating NixOS in container $1..."
    pct exec "$1" -- sh -c 'if [ -f /etc/set-environment ]; then . /etc/set-environment; fi; nix-channel --update && nixos-rebuild switch --upgrade'
}

# --- Interactive Mode (whiptail) ---

run_interactive_mode() {
    local choice
    choice=$(whiptail --title "NixOS LXC Manager" --menu "Choose an action:" 15 60 4 \
        "1" "Create new NixOS container" \
        "2" "Enter container shell" \
        "3" "Update container" \
        "4" "Exit" 3>&1 1>&2 2>&3) || exit 0

    case "$choice" in
    1)
        CT_NAME=$(whiptail --inputbox "Enter container name (leave empty for auto)" 8 60 "$CT_NAME" 3>&1 1>&2 2>&3) || exit 1
        CT_PASSWORD=$(whiptail --passwordbox "Enter root password (leave empty for none)" 8 60 3>&1 1>&2 2>&3) || exit 1
        CT_SSH_KEYS=$(whiptail --inputbox "Path to SSH public key file (optional)" 8 60 "$CT_SSH_KEYS" 3>&1 1>&2 2>&3) || exit 1
        create_nixos_ct
        ;;
    2)
        local ctid
        ctid=$(whiptail --inputbox "Enter container ID:" 8 60 3>&1 1>&2 2>&3) || exit 1
        enter_container "$ctid"
        ;;
    3)
        local ctid
        ctid=$(whiptail --inputbox "Enter container ID to update:" 8 60 3>&1 1>&2 2>&3) || exit 1
        update_nixos "$ctid"
        ;;
    4) exit 0 ;;
    esac
}

# --- Main Execution Logic ---

show_help() {
    cat <<EOF
Usage: $0 <action> [options]

Actions:
  create                      Create a new NixOS container.
  shell <ctid>                Enter the shell of a container.
  configure <ctid>            Re-run configuration on an existing container.
  update <ctid>               Update a NixOS container.
  download                    Download the NixOS image without creating a container.
  help                        Show this help message.

Options for 'create' action:
  --id <id>                   Container ID (optional, auto-generates if not set)
  --name <name>               Container name (default: nixos-ct-<id>)
  --cpus <cores>              Number of CPU cores (default: $CT_CPUS)
  --memory <mb>               Memory in MB (default: $CT_MEMORY)
  --swap <mb>                 Swap in MB (default: $CT_SWAP)
  --disk <gb>                 Disk size in GB (default: $CT_DISK)
  --storage <id>              Storage backend (default: $CT_STORAGE)
  --bridge <id>               Network bridge (default: $CT_BRIDGE)
  --ip <ip>                   IP address (e.g., 192.168.1.100 or 'dhcp')
  --cidr <cidr>               CIDR for static IP (default: $CT_CIDR)
  --gw <gateway>              Gateway for static IP
  --dns <server>              DNS server (default: $CT_DNS)
  --password <pass>           Root password
  --ssh-keys <path>           Path to SSH public key file for root user
  --nixos-version <version>   NixOS version (default: $NIXOS_VERSION)

Options for 'configure' action:
  --password <pass>           Root password
  --ssh-keys <path>           Path to SSH public key file for root user
EOF
}

main() {
    # If no arguments, and in an interactive terminal, show the menu.
    if [ "$#" -eq 0 ]; then
        if [ "$INTERACTIVE" = true ]; then
            run_interactive_mode
            exit 0
        else
            show_help
            msg_error "No action specified. Run with 'help' for usage."
        fi
    fi

    # The first argument is the action.
    ACTION="${1:-}"
    shift || true # Shift even if there are no more arguments

    case "$ACTION" in
    create)
        # Parse options for the 'create' action
        while [ "$#" -gt 0 ]; do
            case "$1" in
            --id)
                CT_ID="$2"
                shift
                ;;
            --name)
                CT_NAME="$2"
                shift
                ;;
            --cpus)
                CT_CPUS="$2"
                shift
                ;;
            --memory)
                CT_MEMORY="$2"
                shift
                ;;
            --swap)
                CT_SWAP="$2"
                shift
                ;;
            --disk)
                CT_DISK="$2"
                shift
                ;;
            --storage)
                CT_STORAGE="$2"
                shift
                ;;
            --bridge)
                CT_BRIDGE="$2"
                shift
                ;;
            --ip)
                CT_IP="$2"
                shift
                ;;
            --cidr)
                CT_CIDR="$2"
                shift
                ;;
            --gw)
                CT_GW="$2"
                shift
                ;;
            --dns)
                CT_DNS="$2"
                shift
                ;;
            --password)
                CT_PASSWORD="$2"
                shift
                ;;
            --ssh-keys)
                CT_SSH_KEYS="$2"
                shift
                ;;
            --nixos-version)
                NIXOS_VERSION="$2"
                shift
                ;;
            -*)
                msg_error "Unknown option for 'create': $1"
                ;;
            *)
                # Stop parsing options if a non-option argument is found
                break
                ;;
            esac
            shift
        done
        # If IP is not set, default to DHCP
        if [ -z "$CT_IP" ]; then
            CT_IP="dhcp"
        fi
        create_nixos_ct
        ;;
    configure)
        [ -z "${1:-}" ] && msg_error "Action 'configure' requires a container ID."
        CT_ID="$1"
        shift

        while [ "$#" -gt 0 ]; do
            case "$1" in
            --password)
                CT_PASSWORD="$2"
                shift
                ;;
            --ssh-keys)
                CT_SSH_KEYS="$2"
                shift
                ;;
            *)
                msg_error "Unknown option for 'configure': $1"
                ;;
            esac
            shift
        done

        # Fetch required info from the existing container
        local unprivileged_config
        unprivileged_config=$(pct config "$CT_ID" | grep 'unprivileged:' || true)
        if [ -n "$unprivileged_config" ]; then
            CT_UNPRIVILEGED=$(echo "$unprivileged_config" | awk '{print $2}')
        else
            # If the 'unprivileged' line is missing, the container is privileged.
            CT_UNPRIVILEGED=0
        fi

        local hostname
        hostname=$(pct config "$CT_ID" | grep 'hostname:' | awk '{print $2}')
        local ssh_keys_content=""
        if [ -n "$CT_SSH_KEYS" ] && [ -f "$CT_SSH_KEYS" ]; then
            ssh_keys_content=$(sed 's/.*/"&"/' "$CT_SSH_KEYS" | tr '\n' ' ')
        fi
        configure_nixos_ct "$CT_ID" "$hostname" "$CT_PASSWORD" "$ssh_keys_content"
        ;;
    shell)
        [ -z "${1:-}" ] && msg_error "Action 'shell' requires a container ID."
        enter_container "$1"
        ;;
    update)
        [ -z "${1:-}" ] && msg_error "Action 'update' requires a container ID."
        update_nixos "$1"
        ;;
    download)
        prepare_nixos_image "$NIXOS_VERSION"
        ;;
    help | --help | -h)
        show_help
        ;;
    *)
        show_help
        msg_error "Unknown action: $ACTION"
        ;;
    esac
}

# Run the script
main "$@"
