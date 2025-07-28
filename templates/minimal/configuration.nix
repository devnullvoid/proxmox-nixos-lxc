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
    extraGroups = [ "wheel" ];
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

  # Minimal system packages
  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    htop
  ];
} 