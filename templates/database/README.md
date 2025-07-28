# Database Server Template

A NixOS container pre-configured as a PostgreSQL database server with optimized settings and backup configuration.

## Features

- PostgreSQL 15 with optimized configuration
- Automatic backup scheduling
- Firewall configuration for database access
- Database administration tools (pgAdmin4)
- User account with postgres group access
- Secure default settings

## Requirements

- Minimum 2 CPU cores
- Minimum 2048MB RAM
- Minimum 20GB disk space
- Network access for database connections

## Configuration

### Template Variables

- `db_name`: Database name (default: mydb)
- `db_user`: Database user (default: postgres)
- `db_password`: Database password (default: changeme)

### Ports

- Port 5432: PostgreSQL database
- Port 22: SSH access

## Post-Installation Steps

1. **Set secure passwords**:
   ```bash
   sudo -u postgres psql
   ALTER USER postgres PASSWORD 'your-secure-password';
   \q
   ```

2. **Create databases and users**:
   ```bash
   sudo -u postgres createdb myapp
   sudo -u postgres createuser myapp_user
   sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE myapp TO myapp_user;"
   ```

3. **Configure backup strategy**:
   - Backups run daily at 2:00 AM
   - Location: `/var/backup/postgresql`
   - Review backup retention policy

4. **Security considerations**:
   - Change default passwords immediately
   - Restrict network access to database port
   - Use SSL connections for remote access
   - Consider using connection pooling

## Usage Examples

### Create database server
```bash
sudo ./proxmox-nixos-lxc.sh create \
    --name my-database \
    --template database \
    --memory 4096 \
    --disk 50 \
    --cpus 4
```

### Connect to database
```bash
# SSH into the container
sudo ./proxmox-nixos-lxc.sh shell <container-id>

# Connect to PostgreSQL
sudo -u postgres psql

# Or connect as a specific user
psql -h localhost -U myapp_user -d myapp
```

### Check database status
```bash
# Check PostgreSQL status
systemctl status postgresql

# View logs
journalctl -u postgresql

# Check backup status
systemctl status postgresqlBackup
```

## Database Management

### Backup and Restore
```bash
# Manual backup
sudo -u postgres pg_dump myapp > /var/backup/postgresql/myapp_$(date +%Y%m%d).sql

# Restore from backup
sudo -u postgres psql myapp < /var/backup/postgresql/myapp_20231201.sql
```

### Performance Tuning
The template includes optimized PostgreSQL settings for general use. For production:

1. Monitor performance with `pg_stat_statements`
2. Adjust `shared_buffers` based on available RAM
3. Configure connection pooling (e.g., PgBouncer)
4. Set up replication for high availability

## Troubleshooting

- **Connection refused**: Check if PostgreSQL is running and firewall rules
- **Permission denied**: Verify user permissions and pg_hba.conf
- **Out of memory**: Increase `shared_buffers` and `work_mem`
- **Backup failures**: Check disk space and backup directory permissions 