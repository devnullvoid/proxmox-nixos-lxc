#!/usr/bin/env bash
set -euo pipefail

# Proxmox NixOS LXC Container Manager
#
# Features:
# - Interactive setup with whiptail or non-interactive via command line
# - Uses pct push for configuration (no LVM/ZFS mounting required)
# - Proper NixOS configuration management
# - Automatic environment setup for containers
# - Template support for pre-configured services
# - Flake support for reproducible configurations
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
CT_TEMPLATE=""
CT_USE_FLAKE="false"
CT_FLAKE_URL=""
CT_FLAKE_REF=""
CT_FLAKE_INPUT=""

# --- Template Configuration ---
TEMPLATES_DIR="$(dirname "$0")/templates"
DEFAULT_TEMPLATE="minimal"

# --- Utility Functions ---

check_dependencies() {
    if ! command -v whiptail &> /dev/null && [ "$INTERACTIVE" = true ]; then
        msg_error "whiptail is not installed. Please install it to use the interactive mode."
    fi
}

# Template management functions
list_available_templates() {
    if [ ! -d "$TEMPLATES_DIR" ]; then
        echo "No templates directory found at $TEMPLATES_DIR"
        return 1
    fi
    
    local templates=()
    for template_dir in "$TEMPLATES_DIR"/*/; do
        if [ -d "$template_dir" ]; then
            local template_name
            template_name=$(basename "$template_dir")
            if [ -f "$template_dir/metadata.json" ]; then
                templates+=("$template_name")
            fi
        fi
    done
    
    if [ ${#templates[@]} -eq 0 ]; then
        echo "No valid templates found in $TEMPLATES_DIR"
        return 1
    fi
    
    printf '%s\n' "${templates[@]}"
}

get_template_metadata() {
    local template="$1"
    local metadata_file="$TEMPLATES_DIR/$template/metadata.json"
    
    if [ ! -f "$metadata_file" ]; then
        msg_error "Template '$template' not found or missing metadata.json"
    fi
    
    cat "$metadata_file"
}

get_template_config() {
    local template="$1"
    local config_file="$TEMPLATES_DIR/$template/configuration.nix"
    
    if [ ! -f "$config_file" ]; then
        msg_error "Template '$template' configuration.nix not found"
    fi
    
    cat "$config_file"
}

get_template_readme() {
    local template="$1"
    local readme_file="$TEMPLATES_DIR/$template/README.md"
    
    if [ ! -f "$readme_file" ]; then
        echo "No README available for template '$template'"
        return 1
    fi
    
    cat "$readme_file"
}

validate_template() {
    local template="$1"
    local template_dir="$TEMPLATES_DIR/$template"
    
    if [ ! -d "$template_dir" ]; then
        msg_error "Template '$template' not found"
    fi
    
    if [ ! -f "$template_dir/configuration.nix" ]; then
        msg_error "Template '$template' missing configuration.nix"
    fi
    
    if [ ! -f "$template_dir/metadata.json" ]; then
        msg_error "Template '$template' missing metadata.json"
    fi
    
    msg_info "Template '$template' is valid"
}

# Flake management functions
validate_flake_url() {
    local flake_url="$1"
    
    # Basic URL validation
    if [[ ! "$flake_url" =~ ^(https?://|git\+https?://|github:|gitlab:|sourcehut:) ]]; then
        msg_error "Invalid flake URL format: $flake_url"
    fi
}

generate_flake_config() {
    local flake_url="$1"
    local flake_ref="${2:-}"
    local flake_input="${3:-}"
    
    cat << EOF
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
  proxmoxLXC.privileged = $([ "${CT_UNPRIVILEGED:-1}" -eq 0 ] && echo "true" || echo "false");
  proxmoxLXC.manageNetwork = false;

  # Flake configuration
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  
  # Import flake
  imports = [
    (import (fetchTarball {
      url = "$flake_url";
      ${flake_ref:+sha256 = "$flake_ref";}
    }) {
      ${flake_input:+config = { $flake_input = true; };}
    })
  ];

  # User configuration
  nix.settings.trusted-users = [ "nixos" ];
  users.users.nixos = {
    isNormalUser = true;
    initialPassword = "$CT_PASSWORD";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "$([ -n "$CT_SSH_KEYS" ] && [ -f "$CT_SSH_KEYS" ] && sed 's/.*/"&"/' "$CT_SSH_KEYS" | tr '\n' ' ' || echo "")"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  # SSH settings
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "yes";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "$([ -n "$CT_SSH_KEYS" ] && [ -f "$CT_SSH_KEYS" ] && sed 's/.*/"&"/' "$CT_SSH_KEYS" | tr '\n' ' ' || echo "")"
  ];
}
EOF
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
    
    # Create cleanup function first to ensure it's available for trap
    cleanup_temp_dir() {
        if [ -n "${temp_dir:-}" ] && [ -d "$temp_dir" ]; then
            rm -rf -- "$temp_dir"
        fi
    }
    
    # Set trap before creating the directory
    trap cleanup_temp_dir EXIT INT TERM
    
    # Create the temporary directory
    temp_dir=$(mktemp -d) || { msg_error "Failed to create temporary directory"; exit 1; }
    
    # Get the next available container ID if not specified
    if [ -z "${CT_ID:-}" ]; then
        local next_id
        next_id=$(pvesh get /cluster/nextid) || { msg_error "Failed to get next available container ID"; exit 1; }
        CT_ID="$next_id"
    fi
    
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

    # Create the NixOS configuration based on template or flake
    if [ "$CT_USE_FLAKE" = "true" ] && [ -n "$CT_FLAKE_URL" ]; then
        msg_info "Using flake configuration from: $CT_FLAKE_URL"
        generate_flake_config "$CT_FLAKE_URL" "$CT_FLAKE_REF" "$CT_FLAKE_INPUT" > "${temp_dir}/configuration.nix"
    elif [ -n "$CT_TEMPLATE" ]; then
        msg_info "Using template: $CT_TEMPLATE"
        validate_template "$CT_TEMPLATE"
        get_template_config "$CT_TEMPLATE" > "${temp_dir}/configuration.nix"
        
        # Apply template-specific variables
        local template_metadata
        template_metadata=$(get_template_metadata "$CT_TEMPLATE")
        
        # Extract and apply template variables if needed
        # This is a basic implementation - could be enhanced with jq for more complex metadata
        if echo "$template_metadata" | grep -q '"variables"'; then
            msg_info "Applying template variables..."
            # TODO: Implement variable substitution from template metadata
        fi
    else
        # Default minimal configuration
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

  nix.settings.trusted-users = [ "nixos" ];
  users.users.nixos =
    {
      isNormalUser = true;
      initialPassword = "$CT_PASSWORD";
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = [
        "$ssh_keys_content"
      ];
    };
  security.sudo.wheelNeedsPassword = false;

  # SSH settings
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "yes";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "$ssh_keys_content"
  ];
}
EOCONFIG
    fi

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

# Enable flakes if using flake configuration
if [ -f /etc/nixos/configuration.nix ] && grep -q "experimental-features" /etc/nixos/configuration.nix; then
    echo "[SETUP] Enabling Nix flakes..."
    mkdir -p /etc/nix
    echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf
fi

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

    # Build the pct create command
    local pct_cmd=(
        pct create "$CT_ID" "$template_path"
        --hostname "$CT_NAME"
        --cores "$CT_CPUS"
        --memory "$CT_MEMORY"
        --swap "$CT_SWAP"
        --rootfs "$CT_STORAGE:$CT_DISK"
        --storage "$CT_STORAGE"
        --net0 "$ip_config"
        --onboot "$CT_START_ON_BOOT"
        --unprivileged "$CT_UNPRIVILEGED"
        --features "nesting=$CT_NESTING"
        --tags "$CT_TAGS"
    )

    # Only add --nameserver if explicitly set by user (not inherited from host)
    if [ "${CT_DNS_SET_BY_USER:-0}" -eq 1 ] && [ -n "$CT_DNS" ]; then
        pct_cmd+=(--nameserver "$CT_DNS")
    fi

    # Create the container
    msg_info "Creating container $CT_ID ($CT_NAME)"
    "${pct_cmd[@]}"

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

    # Show success message and re-creation command
    local recreate_cmd="./$(basename "$0") create "
    recreate_cmd+="--id $CT_ID "
    recreate_cmd+="--name \"$CT_NAME\" "
    recreate_cmd+="--cpus $CT_CPUS "
    recreate_cmd+="--memory $CT_MEMORY "
    recreate_cmd+="--swap $CT_SWAP "
    recreate_cmd+="--disk $CT_DISK "
    recreate_cmd+="--storage \"$CT_STORAGE\" "
    recreate_cmd+="--bridge \"$CT_BRIDGE\" "
    [ -n "$CT_IP" ] && [ "$CT_IP" != "dhcp" ] && recreate_cmd+="--ip $CT_IP --cidr $CT_CIDR --gw $CT_GW "
    [ "$CT_IP" = "dhcp" ] && recreate_cmd+="--ip dhcp "
    recreate_cmd+="--dns \"$CT_DNS\" "
    [ -n "$CT_PASSWORD" ] && recreate_cmd+="--password \"$CT_PASSWORD\" "
    [ -n "$CT_SSH_KEYS" ] && recreate_cmd+="--ssh-keys \"$CT_SSH_KEYS\" "
    [ "$CT_START_ON_BOOT" = "1" ] && recreate_cmd+="--start-on-boot "
    [ "$CT_UNPRIVILEGED" = "1" ] && recreate_cmd+="--unprivileged "
    [ "$CT_NESTING" = "1" ] && recreate_cmd+="--nesting "
    recreate_cmd+="--version $NIXOS_VERSION"

    msg_info "Container $CT_ID created successfully."
    
    # Show re-creation command in non-interactive mode
    if [ "$INTERACTIVE" = false ]; then
        echo -e "\nTo re-create this container, use:\n$recreate_cmd\n"
    fi
}

show_settings_confirmation() {
    local message="Container Settings Review\n\n"
    message+="ID: $CT_ID\n"
    message+="Name: $CT_NAME\n"
    message+="vCPUs: $CT_CPUS\n"
    message+="Memory: $CT_MEMORY MB\n"
    message+="Swap: $CT_SWAP MB\n"
    message+="Disk: $CT_DISK GB\n"
    message+="Storage: $CT_STORAGE\n"
    message+="Network: $CT_BRIDGE\n"
    message+="IP: ${CT_IP:-DHCP}\n"
    if [ -n "$CT_IP" ] && [ "$CT_IP" != "dhcp" ]; then
        message+="Gateway: $CT_GW\n"
        message+="DNS: $CT_DNS\n"
    fi
    message+="Start on boot: $([ "$CT_START_ON_BOOT" = "1" ] && echo "Yes" || echo "No")\n"
    # These are now always set to these values, but we'll show them for clarity
    message+="Unprivileged: Yes\n"
    message+="Nesting: Yes\n"

    if command -v whiptail >/dev/null 2>&1; then
        whiptail --title "Confirm Container Creation" --yesno "$message" 15 60 \
            --yes-button "Create" --no-button "Cancel"
        return $?
    else
        echo -e "\n$message\n"
        read -p "Proceed with container creation? [y/N] " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]]
        return $?
    fi
}

run_interactive_mode() {
    while true; do
        local choice
        choice=$(whiptail --title "NixOS LXC Manager" --menu "Choose an action:" 15 60 4 \
            "1" "Create new NixOS container" \
            "2" "Enter container shell" \
            "3" "Update container" \
            "4" "Exit" 3>&1 1>&2 2>&3) || exit 0

        case "$choice" in
        1)
            # Use the full interactive creation flow
            # This will handle its own exit after successful creation
            interactive_create
            # If we get here, creation was cancelled
            ;;
        2)
            local ctid
            ctid=$(whiptail --inputbox "Enter container ID:" 8 60 3>&1 1>&2 2>&3) || continue
            enter_container "$ctid"
            ;;
        3)
            local ctid
            ctid=$(whiptail --inputbox "Enter container ID to update:" 8 60 3>&1 1>&2 2>&3) || continue
            update_nixos "$ctid"
            ;;
        4)
            exit 0
            ;;
        esac
    done
}

interactive_create() {
    # Set default values
    local next_id
    next_id=$(get_next_ctid)
    
    # Basic container settings
    CT_ID=$(whiptail --inputbox "Enter Container ID:" 8 78 "$next_id" --title "Container ID" 3>&1 1>&2 2>&3) || { msg_error "Container creation cancelled."; exit 1; }
    [ -z "$CT_ID" ] && { msg_error "Container ID cannot be empty."; exit 1; }

    CT_NAME=$(whiptail --inputbox "Enter Container Name (hostname):" 8 78 "nixos-ct" --title "Container Name" 3>&1 1>&2 2>&3) || { msg_error "Container creation cancelled."; exit 1; }
    [ -z "$CT_NAME" ] && { msg_error "Container Name cannot be empty."; exit 1; }

    # Get storage pool
    get_storage_pool

    # Resource allocation
    CT_CPUS=$(whiptail --inputbox "Enter number of CPU cores (e.g., 2):" 8 78 "${CT_CPUS:-2}" --title "CPU Cores" 3>&1 1>&2 2>&3) || { msg_error "Container creation cancelled."; exit 1; }
    CT_MEMORY=$(whiptail --inputbox "Enter RAM in MB (e.g., 2048):" 8 78 "${CT_MEMORY:-2048}" --title "Memory (RAM)" 3>&1 1>&2 2>&3) || { msg_error "Container creation cancelled."; exit 1; }
    CT_SWAP=$(whiptail --inputbox "Enter Swap in MB (e.g., 512):" 8 78 "${CT_SWAP:-512}" --title "Swap" 3>&1 1>&2 2>&3) || { msg_error "Container creation cancelled."; exit 1; }
    CT_DISK=$(whiptail --inputbox "Enter Disk Size in GB (e.g., 10):" 8 78 "${CT_DISK:-10}" --title "Disk Size" 3>&1 1>&2 2>&3) || { msg_error "Container creation cancelled."; exit 1; }

    # Network configuration - default to DHCP
    if whiptail --yesno "Use DHCP for network configuration?" 8 78 --yes-button "Yes" --no-button "No"; then
        CT_IP="dhcp"
        CT_CIDR=""
        CT_GW=""
        # Inherit DNS from host when using DHCP
        if [ -f /etc/resolv.conf ]; then
            CT_DNS=$(grep '^nameserver' /etc/resolv.conf | head -n 1 | awk '{print $2}')
            [ -z "$CT_DNS" ] && CT_DNS="1.1.1.1"
        else
            CT_DNS="1.1.1.1"
        fi
        # DNS is not explicitly set by user when using DHCP
        CT_DNS_SET_BY_USER=0
    else
        CT_IP=$(whiptail --inputbox "Enter IP Address (e.g., 192.168.1.100):" 8 78 --title "IP Address" 3>&1 1>&2 2>&3) || { msg_error "Container creation cancelled."; exit 1; }
        CT_CIDR=$(whiptail --inputbox "Enter CIDR (e.g., 24):" 8 78 "24" --title "CIDR" 3>&1 1>&2 2>&3) || { msg_error "Container creation cancelled."; exit 1; }
        CT_GW=$(whiptail --inputbox "Enter Gateway (e.g., 192.168.1.1):" 8 78 --title "Gateway" 3>&1 1>&2 2>&3) || { msg_error "Container creation cancelled."; exit 1; }
        CT_DNS=$(whiptail --inputbox "Enter DNS Server (e.g., 1.1.1.1):" 8 78 "1.1.1.1" --title "DNS Server" 3>&1 1>&2 2>&3) || { msg_error "Container creation cancelled."; exit 1; }
        # DNS is explicitly set by user
        CT_DNS_SET_BY_USER=1
    fi
    
    CT_BRIDGE=$(whiptail --inputbox "Enter Bridge Interface (e.g., vmbr0):" 8 78 "vmbr0" --title "Network Bridge" 3>&1 1>&2 2>&3) || { msg_error "Container creation cancelled."; exit 1; }

    # Security settings
    if whiptail --yesno "Set a root password?" 8 78 --defaultno; then
        CT_PASSWORD=$(whiptail --passwordbox "Enter root password:" 8 78 --title "Root Password" 3>&1 1>&2 2>&3) || { msg_error "Container creation cancelled."; exit 1; }
    else
        CT_PASSWORD=""
    fi
    
    if whiptail --yesno "Add SSH public keys?" 8 78 --defaultno; then
        local default_key_path="$HOME/.ssh/id_rsa.pub"
        local ssh_keys_input
        ssh_keys_input=$(whiptail --inputbox "Enter path to SSH public keys file:" 8 78 "$default_key_path" --title "SSH Keys" 3>&1 1>&2 2>&3) || { msg_error "Container creation cancelled."; exit 1; }
        CT_SSH_KEYS="$ssh_keys_input"
    else
        CT_SSH_KEYS=""
    fi

    # Container options - defaults
    if whiptail --yesno "Start container on boot?" 8 78; then
        CT_START_ON_BOOT=1
    else
        CT_START_ON_BOOT=0
    fi

    # Default to unprivileged with nesting enabled
    CT_UNPRIVILEGED=1
    CT_NESTING=1

    # Template selection
    local available_templates
    available_templates=$(list_available_templates 2>/dev/null || echo "")
    
    if [ -n "$available_templates" ]; then
        local template_choice
        template_choice=$(whiptail --title "Select Template" --menu "Choose a template (or skip for minimal):" 15 60 6 \
            "minimal" "Basic NixOS container" \
            "custom" "Use custom template" \
            "flake" "Use Nix flake" \
            3>&1 1>&2 2>&3) || template_choice="minimal"
        
        case "$template_choice" in
            "custom")
                local template_list
                template_list=$(echo "$available_templates" | tr '\n' ' ')
                CT_TEMPLATE=$(whiptail --title "Select Template" --menu "Choose a template:" 15 60 6 $template_list 3>&1 1>&2 2>&3) || CT_TEMPLATE=""
                ;;
            "flake")
                CT_USE_FLAKE="true"
                CT_FLAKE_URL=$(whiptail --inputbox "Enter flake URL:" 8 78 "github:owner/repo" --title "Flake URL" 3>&1 1>&2 2>&3) || CT_FLAKE_URL=""
                if [ -n "$CT_FLAKE_URL" ]; then
                    CT_FLAKE_REF=$(whiptail --inputbox "Enter flake reference (optional):" 8 78 "" --title "Flake Reference" 3>&1 1>&2 2>&3) || CT_FLAKE_REF=""
                    CT_FLAKE_INPUT=$(whiptail --inputbox "Enter flake input (optional):" 8 78 "" --title "Flake Input" 3>&1 1>&2 2>&3) || CT_FLAKE_INPUT=""
                fi
                ;;
            *)
                CT_TEMPLATE=""
                CT_USE_FLAKE="false"
                ;;
        esac
    fi

    # NixOS version
    NIXOS_VERSION=$(whiptail --inputbox "Enter NixOS version (e.g., 25.05):" 8 78 "25.05" --title "NixOS Version" 3>&1 1>&2 2>&3) || { msg_error "Container creation cancelled."; exit 1; }

    # Show confirmation with all settings
    if show_settings_confirmation; then
        # Create the container
        create_nixos_ct
        
        # After successful creation, show the re-creation command and exit
        local recreate_cmd="./$(basename "$0") create "
        recreate_cmd+="--id $CT_ID "
        recreate_cmd+="--name \"$CT_NAME\" "
        recreate_cmd+="--cpus $CT_CPUS "
        recreate_cmd+="--memory $CT_MEMORY "
        recreate_cmd+="--swap $CT_SWAP "
        recreate_cmd+="--disk $CT_DISK "
        recreate_cmd+="--storage \"$CT_STORAGE\" "
        recreate_cmd+="--bridge \"$CT_BRIDGE\" "
        
        # Only include IP settings if not using DHCP
        if [ "$CT_IP" = "dhcp" ]; then
            recreate_cmd+="--ip dhcp "
        else
            recreate_cmd+="--ip $CT_IP --cidr $CT_CIDR --gw $CT_GW "
            # Only include DNS if explicitly set (not inherited from host)
            if [ -n "${CT_DNS_SET_BY_USER:-}" ]; then
                recreate_cmd+="--dns \"$CT_DNS\" "
            fi
        fi
        
        # Only include password if set
        [ -n "$CT_PASSWORD" ] && recreate_cmd+="--password \"$CT_PASSWORD\" "
        
        # Only include SSH keys if set
        [ -n "$CT_SSH_KEYS" ] && recreate_cmd+="--ssh-keys \"$CT_SSH_KEYS\" "
        
        # Only include start-on-boot if different from default (default: ON)
        [ "$CT_START_ON_BOOT" != "1" ] && recreate_cmd+="--no-start-on-boot "
        
        # Only include unprivileged if different from default (default: ON)
        [ "$CT_UNPRIVILEGED" != "1" ] && recreate_cmd+="--no-unprivileged "
        
        # Only include nesting if different from default (default: ON)
        [ "$CT_NESTING" != "1" ] && recreate_cmd+="--no-nesting "
        
        # Always include version
        recreate_cmd+="--version $NIXOS_VERSION"
        
        echo -e "\nContainer $CT_ID created successfully."
        echo -e "\nTo re-create this container, use this command:"
        echo -e "$recreate_cmd\n"
        exit 0
    else
        msg_info "Container creation cancelled by user."
        exit 0
    fi
}

enter_container() {
    msg_info "Entering container $1..."
    pct exec "$1" -- /bin/sh -c 'if [ -f /etc/set-environment ]; then . /etc/set-environment; fi; exec bash'
}

update_nixos() {
    msg_info "Updating NixOS in container $1..."
    pct exec "$1" -- /bin/sh -c 'if [ -f /etc/set-environment ]; then . /etc/set-environment; fi; nix-channel --update && nixos-rebuild switch --upgrade' || {
        msg_error "Failed to update container $1. Please check the container logs for more details."
        exit 1
    }
    msg_info "Successfully updated container $1"
}

show_help() {
    echo "Usage: $0 <action> [options]"
    echo "Actions:"
    echo "  create                Create a new NixOS container (interactive or with flags)"
    echo "  shell <ctid>          Enter the shell of a container"
    echo "  update <ctid>         Update NixOS in a container"
    echo "  configure <ctid>      Configure user password and SSH keys"
    echo "  download              Download the NixOS image"
    echo "  templates             List available templates"
    echo "  template-info <name>  Show template information"
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
    echo "  --template <name>     Use template configuration"
    echo "  --flake-url <url>     Use Nix flake URL"
    echo "  --flake-ref <ref>     Flake reference (optional)"
    echo "  --flake-input <input> Flake input (optional)"
}

# --- Main Logic ---

main() {
    check_dependencies

    # If no arguments and in an interactive terminal, run the interactive mode
    if [ $# -eq 0 ]; then
        if [ "$INTERACTIVE" = true ]; then
            run_interactive_mode
            exit 0
        else
            show_help
            exit 1
        fi
    fi

    ACTION="${1:-}"
    shift || true

    case "$ACTION" in
    create)
        # Non-interactive mode if flags are present, otherwise interactive
        if [ "$#" -gt 0 ]; then
            INTERACTIVE=false
        elif [ "$INTERACTIVE" = true ]; then
            # If no flags but in an interactive terminal, run interactive creation
            interactive_create
            exit 0
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
            --template) CT_TEMPLATE="$2"; shift;; 
            --flake-url) CT_FLAKE_URL="$2"; CT_USE_FLAKE="true"; shift;; 
            --flake-ref) CT_FLAKE_REF="$2"; shift;; 
            --flake-input) CT_FLAKE_INPUT="$2"; shift;; 
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
    templates)
        list_available_templates
        ;;
    template-info)
        [ -z "${1:-}" ] && msg_error "Action 'template-info' requires a template name."
        echo "=== Template: $1 ==="
        echo ""
        echo "Metadata:"
        get_template_metadata "$1" 2>/dev/null || echo "No metadata available"
        echo ""
        echo "README:"
        get_template_readme "$1" 2>/dev/null || echo "No README available"
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
