{ config, pkgs, lib, modulesPath, ... }: {
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  # Basic system settings
  boot.loader.grub.enable = false;
  networking.hostName = "{{HOSTNAME}}";
  time.timeZone = "Etc/UTC";
  system.stateVersion = "{{NIXOS_VERSION}}";

  # Proxmox LXC settings
  nix.settings.sandbox = false;
  proxmoxLXC.privileged = {{PRIVILEGED}};
  proxmoxLXC.manageNetwork = false;

  # User configuration
  nix.settings.trusted-users = [ "nixos" ];
  users.users.nixos = {
    isNormalUser = true;
    initialPassword = "{{PASSWORD}}";
    extraGroups = [ "wheel" "postgres" ];
    openssh.authorizedKeys.keys = [
      {{SSH_KEYS}}
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
    {{SSH_KEYS}}
  ];

  # PostgreSQL configuration
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_15;
    enableTCPIP = true;
    settings = {
      listen_addresses = "*";
      max_connections = 100;
      shared_buffers = "256MB";
      effective_cache_size = "1GB";
      maintenance_work_mem = "64MB";
      checkpoint_completion_target = 0.9;
      wal_buffers = "16MB";
      default_statistics_target = 100;
      random_page_cost = 1.1;
      effective_io_concurrency = 200;
      work_mem = "4MB";
      min_wal_size = "1GB";
      max_wal_size = "4GB";
    };
  };

  # Firewall configuration
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 5432 ];
  };

  # System packages
  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    htop
    postgresql_15
    pgadmin4
  ];

  # Database initialization
  system.activationScripts.postgresInit = ''
    # Create postgres user with password
    if ! sudo -u postgres psql -c "SELECT 1" > /dev/null 2>&1; then
      echo "Initializing PostgreSQL..."
      sudo -u postgres psql -c "ALTER USER postgres PASSWORD '{{DB_PASSWORD}}';"
    fi
  '';

  # Backup configuration
  services.postgresqlBackup = {
    enable = true;
    databases = [ "{{DB_NAME}}" ];
    location = "/var/backup/postgresql";
    startAt = "02:00";
  };

  # Create backup directory
  system.activationScripts.backupDir = ''
    mkdir -p /var/backup/postgresql
    chown postgres:postgres /var/backup/postgresql
    chmod 700 /var/backup/postgresql
  '';
} 