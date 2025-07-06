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

check_dependencies() {
    if ! command -v whiptail &> /dev/null && [ "$INTERACTIVE" = true ]; then
        msg_error "whiptail is not installed. Please install it to use the interactive mode."
    fi
}

# Check if running in an interactive terminal
INTERACTIVE=false
if [ -t 0 ] && [ -t 1 ]; then
    INTERACTIVE=true
fi

msg_info() { echo -e "\e[32m[INFO]  $*\e[0m"; }
msg_warning() { echo -e "\e[33m[WARN]  $*\e[0m"; }
msg_error() {
    echo -e "\e[31m[ERROR] $*\n\e[0m" >&2
    exit 1
}

get_next_ctid() {
    pvesh get /cluster/nextid
}

# --- Core Functions ---

get_storage_pool() {
    local storage_info
    if ! storage_info=$(pvesm status -content rootdir -content images); then
        msg_error "The 'pvesm status' command failed. Please run it manually to diagnose the issue."
    fi

    # Use awk to parse the output, skipping the header line (NR>1)
    local storage_list
    storage_list=$(echo "$storage_info" | awk 'NR>1 {print $1, $2, $6}')

    if [ -z "$storage_list" ]; then
        msg_error "No suitable storage pools found. Looking for pools with 'rootdir' or 'images' content types."
    fi

    local menu_options=()
    local count=0

    while read -r name type avail; do
        local free_fmt
        if command -v numfmt &> /dev/null; then
            # pvesm reports available space in KiB.
            free_fmt=$(echo "$avail" | numfmt --to=iec --from-unit=1024 --format=%.2f)B
        else
            # Fallback to showing KiB
            free_fmt="${avail}K"
        fi
        
        local item_desc="Type: $(printf '%-10s' "$type") Free: $free_fmt"
        
        local on_off="OFF"
        if [ $count -eq 0 ]; then
            on_off="ON"
        fi
        
        menu_options+=("$name" "$item_desc" "$on_off")
        count=$((count + 1))
    done <<< "$storage_list"

    # Auto-select if only one option
    if [ $count -eq 1 ]; then
        CT_STORAGE="${menu_options[0]}"
        msg_info "Using storage pool: $CT_STORAGE"
        return
    fi

    local chosen_storage
    chosen_storage=$(whiptail --title "Select Storage Pool" --radiolist "Choose a storage pool for the container's disk:" 20 78 "$count" "${menu_options[@]}" 3>&1 1>&2 2>&3)
    
    if [ -z "$chosen_storage" ]; then
        msg_error "No storage pool selected. Aborting."
    fi
    CT_STORAGE="$chosen_storage"
}

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
    echo "$image_name"
}

configure_nixos_ct() {
    local ctid="$1"
    local hostname="$2"
    local password="$3"
    local ssh_keys="$4"

    local temp_config
    # Configuration is now handled by the setup-nixos.sh script that gets pushed to the container
}

create_nixos_ct() {
    # Get the image name and ensure it's in the correct location
    local image_name
    image_name=$(prepare_nixos_image "$NIXOS_VERSION")
    
    # Ensure the template is in the correct location for Proxmox
    local template_dir="/var/lib/vz/template/cache"
    local template_name="nixos-${NIXOS_VERSION}-x86_64-linux.tar.xz"
    local template_src="${template_dir}/${template_name}"
    
    # Copy the template to the Proxmox template directory if needed
    if [ ! -f "$template_src" ]; then
        mkdir -p "$template_dir"
        cp "$image_name" "$template_src"
    fi
    
    # Use the correct format for pct create: storage:vztmpl/template_name
    local template_path="local:vztmpl/$template_name"

    local ip_config
    if [ "$CT_IP" = "dhcp" ]; then
        ip_config="name=eth0,bridge=$CT_BRIDGE,ip=dhcp"
    else
        ip_config="name=eth0,bridge=$CT_BRIDGE,ip=$CT_IP/$CT_CIDR,gw=$CT_GW"
    fi

    # Create a temporary directory for our scripts
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf -- "$temp_dir"' EXIT

    # Initialize ssh_keys_content
    local ssh_keys_content=""
    if [ -n "$CT_SSH_KEYS" ] && [ -f "$CT_SSH_KEYS" ]; then
        ssh_keys_content=$(sed 's/.*/"&"/' "$CT_SSH_KEYS" | tr '\n' ' ')
    fi
    
    # Determine if the container is privileged
    local is_privileged_bool="false"
    if [ "${CT_UNPRIVILEGED:-1}" -eq 0 ]; then
        is_privileged_bool="true"
    fi

    # Create the NixOS configuration
    cat > "${temp_dir}/configuration.nix" << EOCONFIG
{ config, pkgs, lib, modulesPath, ... }: {
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  # Basic system settings
  boot.loader.grub.enable = false;
  networking.hostName = "$CT_NAME";
  time.timeZone = "Etc/UTC";
  system.stateVersion = "$NIXOS_VERSION";

  # Proxmox LXC settings
  nix.settings.sandbox = false;
  proxmoxLXC.privileged = $is_privileged_bool;
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

    # Create setup script
    cat > "${temp_dir}/setup-nixos.sh" << 'EOF'
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

# echo "[SETUP] Generating hardware configuration..."
# nixos-generate-config

if [ -n "$CT_PASSWORD" ]; then
    echo "[SETUP] Setting root password..."
    echo "root:$CT_PASSWORD" | chpasswd
fi

echo "[SETUP] Rebuilding NixOS system..."
nix-channel --update
nixos-rebuild switch --upgrade

echo "[SETUP] NixOS setup complete."
EOF
    chmod +x "${temp_dir}/setup-nixos.sh"

    # Create the container
    msg_info "Creating container $CT_ID ($CT_NAME)"
    pct create "$CT_ID" "$template_path" \
        --hostname "$CT_NAME" \
        --cores "$CT_CPUS" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "$CT_STORAGE:$CT_DISK" \
        --storage "$CT_STORAGE" \
        --net0 "$ip_config" \
        --onboot "$CT_START_ON_BOOT" \
        --unprivileged "$CT_UNPRIVILEGED" \
        --features "nesting=$CT_NESTING" \
        --tags "$CT_TAGS"

    # Start the container
    msg_info "Starting container $CT_ID"
    pct start "$CT_ID"

    # Wait for the container to start
    sleep 5

    # Push configuration files
    msg_info "Pushing configuration to container $CT_ID"
    pct push "$CT_ID" "${temp_dir}/configuration.nix" /etc/nixos/configuration.nix
    pct push "$CT_ID" "${temp_dir}/setup-nixos.sh" /root/setup-nixos.sh --perms 0755

    # Run the setup script
    msg_info "Running setup script in container $CT_ID"
    pct exec "$CT_ID" -- sh -c 'if [ -f /etc/set-environment ]; then . /etc/set-environment; fi; /root/setup-nixos.sh'

    msg_info "Container $CT_ID created successfully."
}

interactive_create() {
    local next_id
    next_id=$(get_next_ctid)
    CT_ID=$(whiptail --inputbox "Enter Container ID:" 8 78 "$next_id" --title "Container ID" 3>&1 1>&2 2>&3)
    [ -z "$CT_ID" ] && msg_error "Container ID cannot be empty."

    CT_NAME=$(whiptail --inputbox "Enter Container Name (hostname):" 8 78 "nixos-ct" --title "Container Name" 3>&1 1>&2 2>&3)
    [ -z "$CT_NAME" ] && msg_error "Container Name cannot be empty."

    get_storage_pool

    CT_CPUS=$(whiptail --inputbox "Enter number of CPU cores:" 8 78 "$CT_CPUS" --title "CPU Cores" 3>&1 1>&2 2>&3)
    CT_MEMORY=$(whiptail --inputbox "Enter RAM in MB:" 8 78 "$CT_MEMORY" --title "Memory (RAM)" 3>&1 1>&2 2>&3)
    CT_SWAP=$(whiptail --inputbox "Enter Swap in MB:" 8 78 "$CT_SWAP" --title "Swap" 3>&1 1>&2 2>&3)
    CT_DISK=$(whiptail --inputbox "Enter Disk Size in GB:" 8 78 "$CT_DISK" --title "Disk Size" 3>&1 1>&2 2>&3)

    # Network configuration
    if whiptail --yesno "Use DHCP for network configuration?" 8 78; then
        CT_IP="dhcp"
    else
        CT_IP=$(whiptail --inputbox "Enter IP Address (e.g., 192.168.1.100):" 8 78 --title "IP Address" 3>&1 1>&2 2>&3)
        CT_CIDR=$(whiptail --inputbox "Enter CIDR (e.g., 24):" 8 78 "$CT_CIDR" --title "CIDR" 3>&1 1>&2 2>&3)
        CT_GW=$(whiptail --inputbox "Enter Gateway (e.g., 192.168.1.1):" 8 78 --title "Gateway" 3>&1 1>&2 2>&3)
    fi
    CT_DNS=$(whiptail --inputbox "Enter DNS Server:" 8 78 "$CT_DNS" --title "DNS Server" 3>&1 1>&2 2>&3)

    # SSH and Password
    if whiptail --yesno "Set a root password?" 8 78; then
        CT_PASSWORD=$(whiptail --passwordbox "Enter root password:" 8 78 --title "Root Password" 3>&1 1>&2 2>&3)
    fi
    if whiptail --yesno "Add SSH public keys?" 8 78; then
        local default_key_path="$HOME/.ssh/id_rsa.pub"
        CT_SSH_KEYS=$(whiptail --inputbox "Enter path to SSH public keys file:" 8 78 "$default_key_path" --title "SSH Keys" 3>&1 1>&2 2>&3)
    fi

    # Other options
    if whiptail --yesno "Start container on boot?" 8 78; then
        CT_START_ON_BOOT="1"
    else
        CT_START_ON_BOOT="0"
    fi
}

enter_container() {
    pct enter "$1"
}

update_nixos() {
    msg_info "Updating NixOS in container $1"
    pct exec "$1" -- bash -c "nixos-rebuild switch --upgrade"
}

show_help() {
    echo "Usage: $0 <action> [options]"
    echo "Actions:"
    echo "  create                Create a new NixOS container (interactive or with flags)"
    echo "  shell <ctid>          Enter the shell of a container"
    echo "  update <ctid>         Update NixOS in a container"
    echo "  configure <ctid>      Configure user password and SSH keys"
    echo "  download              Download the NixOS image"
    echo "  help                  Show this help message"
    echo ""
    echo "'create' options:"
    echo "  --id <id>             Container ID"
    echo "  --name <name>         Container hostname"
    echo "  --cpus <count>        Number of CPU cores"
    echo "  --memory <mb>         RAM in MB"
    echo "  --swap <mb>           Swap in MB"
    echo "  --disk <gb>           Disk size in GB"
    echo "  --storage <pool>      Proxmox storage pool"
    echo "  --bridge <bridge>     Network bridge"
    echo "  --ip <ip/cidr|dhcp>   IP address with CIDR or 'dhcp'"
    echo "  --gw <gateway>        Network gateway"
    echo "  --dns <server>        DNS server"
    echo "  --tags <tags>         Comma-separated tags"
    echo "  --unprivileged <0|1>  Unprivileged container"
    echo "  --nesting <0|1>       Enable nesting"
    echo "  --password <pass>     Root password"
    echo "  --ssh-keys <path>     Path to public SSH keys file"
    echo "  --start-on-boot <0|1> Start container on boot"
}

# --- Main Logic ---

main() {
    check_dependencies

    if [ $# -eq 0 ]; then
        show_help
        exit 1
    fi

    ACTION="${1:-}"
    shift || true

    case "$ACTION" in
    create)
        # Non-interactive mode if flags are present
        if [ "$#" -gt 0 ]; then
            INTERACTIVE=false
        fi

        while [ "$#" -gt 0 ]; do
            case "$1" in
            --id) CT_ID="$2"; shift;; 
            --name) CT_NAME="$2"; shift;; 
            --cpus) CT_CPUS="$2"; shift;; 
            --memory) CT_MEMORY="$2"; shift;; 
            --swap) CT_SWAP="$2"; shift;; 
            --disk) CT_DISK="$2"; shift;; 
            --storage) CT_STORAGE="$2"; shift;; 
            --bridge) CT_BRIDGE="$2"; shift;; 
            --ip) CT_IP="$2"; shift;; 
            --gw) CT_GW="$2"; shift;; 
            --dns) CT_DNS="$2"; shift;; 
            --tags) CT_TAGS="$2"; shift;; 
            --unprivileged) CT_UNPRIVILEGED="$2"; shift;; 
            --nesting) CT_NESTING="$2"; shift;; 
            --password) CT_PASSWORD="$2"; shift;; 
            --ssh-keys) CT_SSH_KEYS="$2"; shift;; 
            --start-on-boot) CT_START_ON_BOOT="$2"; shift;; 
            *)
                show_help
                msg_error "Unknown option for 'create': $1"
                ;;
            esac
            shift
        done

        if [ "$INTERACTIVE" = true ]; then
            interactive_create
        fi
        
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
