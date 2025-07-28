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
    extraGroups = [ "wheel" "nginx" ];
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

  # Web server configuration
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    
    virtualHosts."{{DOMAIN}}" = {
      enableACME = {{SSL_ENABLED}};
      forceSSL = {{SSL_ENABLED}};
      root = "/var/www/html";
      
      locations."/" = {
        tryFiles = "$uri $uri/ =404";
      };
    };
  };

  # ACME for SSL certificates
  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@{{DOMAIN}}";
  };

  # Firewall configuration
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 80 443 22 ];
  };

  # System packages
  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    htop
    certbot
    nginx
  ];

  # Create web root directory
  system.activationScripts.webroot = ''
    mkdir -p /var/www/html
    chown nginx:nginx /var/www/html
    chmod 755 /var/www/html
  '';

  # Default web page
  system.activationScripts.defaultPage = ''
    cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to NixOS</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .container { max-width: 800px; margin: 0 auto; }
        .header { background: #f0f0f0; padding: 20px; border-radius: 5px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Welcome to NixOS Web Server</h1>
            <p>Your web server is running successfully!</p>
        </div>
        <h2>Next Steps:</h2>
        <ul>
            <li>Replace this default page with your content</li>
            <li>Configure your domain in nginx settings</li>
            <li>Set up SSL certificates if needed</li>
        </ul>
    </div>
</body>
</html>
EOF
  '';
} 