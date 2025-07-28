# Minimal NixOS Container Template

A minimal NixOS container configuration with basic system tools and SSH access.

## Features

- Basic system configuration for Proxmox LXC
- SSH server enabled with password and key authentication
- Essential system packages (vim, wget, curl, htop)
- Unprivileged container support
- User account with sudo access

## Requirements

- Minimum 1 CPU core
- Minimum 512MB RAM
- Minimum 4GB disk space

## Post-Installation

No additional configuration required. The container is ready to use immediately after creation.

## Security Notes

- Root login is enabled for initial setup
- Consider disabling root login after initial configuration
- SSH keys are recommended for production use
- Container runs unprivileged by default

## Customization

This template serves as a base for more complex configurations. You can extend it by:

1. Adding additional packages to `environment.systemPackages`
2. Enabling additional services
3. Configuring firewall rules
4. Setting up additional users 