# Web Server Template

A NixOS container pre-configured as a web server with nginx, SSL support, and firewall rules.

## Features

- Nginx web server with optimized settings
- Automatic SSL certificate management with ACME
- Firewall configuration for web traffic
- Default welcome page
- User account with nginx group access
- Essential web server tools

## Requirements

- Minimum 1 CPU core
- Minimum 1024MB RAM
- Minimum 8GB disk space
- Domain name for SSL certificates

## Configuration

### Template Variables

- `domain`: Your domain name (default: example.com)
- `ssl_enabled`: Enable SSL certificates (default: true)

### Ports

- Port 80: HTTP traffic
- Port 443: HTTPS traffic
- Port 22: SSH access

## Post-Installation Steps

1. **Configure your domain**:
   - Edit `/etc/nixos/configuration.nix`
   - Replace `{{DOMAIN}}` with your actual domain
   - Rebuild: `nixos-rebuild switch`

2. **Set up SSL certificates**:
   - Certificates are automatically managed by ACME
   - Ensure your domain points to this server
   - Check certificate status: `systemctl status acme-{{DOMAIN}}`

3. **Customize web content**:
   - Replace `/var/www/html/index.html` with your content
   - Add additional virtual hosts as needed

4. **Security considerations**:
   - Review firewall rules in `/etc/nixos/configuration.nix`
   - Consider disabling root SSH access after setup
   - Use SSH keys instead of passwords

## Usage Examples

### Create with custom domain
```bash
sudo ./proxmox-nixos-lxc.sh create \
    --name my-webserver \
    --template webserver \
    --memory 2048 \
    --disk 20
```

### Access the web server
```bash
# SSH into the container
sudo ./proxmox-nixos-lxc.sh shell <container-id>

# Check nginx status
systemctl status nginx

# View logs
journalctl -u nginx
```

## Troubleshooting

- **SSL certificate issues**: Check ACME logs with `journalctl -u acme-{{DOMAIN}}`
- **Nginx not starting**: Check configuration with `nginx -t`
- **Firewall blocking traffic**: Verify ports 80/443 are open 