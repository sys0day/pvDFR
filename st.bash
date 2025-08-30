#!/bin/bash

# Storage Server Auto-Setup Script for Windows Compatibility

# Reset and automate all steps



set -e  # Exit on any error



echo "=== Storage Server Auto-Setup ==="

echo "Target: Windows-Compatible Storage Server"

echo "========================================="



# Colors for output

RED='\033[0;31m'

GREEN='\033[0;32m'

YELLOW='\033[1;33m'

NC='\033[0m' # No Color



# Configuration

STORAGE_DEVICE="/dev/sdb"

STORAGE_MOUNT="/storage"

SFTP_USER="sftpuser"

SFTP_PASSWORD="SecurePass123!"  # Change this in production



# Function to print status

print_status() {

    echo -e "${GREEN}[✓]${NC} $1"

}



print_warning() {

    echo -e "${YELLOW}[!]${NC} $1"

}



print_error() {

    echo -e "${RED}[✗]${NC} $1"

}



# Step 1: Reset and cleanup

echo "Step 1: Cleaning up previous setup..."

sudo umount -f $STORAGE_MOUNT 2>/dev/null || true

sudo vgremove -f storage-vg 2>/dev/null || true

sudo pvremove -f $STORAGE_DEVICE 2>/dev/null || true

sudo rm -rf $STORAGE_MOUNT

sudo sed -i '/\/storage/d' /etc/fstab

sudo sed -i '/sftpuser/d' /etc/passwd /etc/shadow /etc/group 2>/dev/null || true



# Step 2: Update system

print_status "Updating system packages..."

sudo apt update && sudo apt upgrade -y



# Step 3: Install required packages (با تصحیح نام fail2ban)

print_status "Installing required packages..."

sudo apt install -y lvm2 parted samba samba-common-bin nfs-kernel-server \

    fail2ban ufw curl wget vim htop



# Step 4: Setup storage device

print_status "Setting up storage device $STORAGE_DEVICE..."

sudo parted -s $STORAGE_DEVICE mklabel gpt

sudo parted -s $STORAGE_DEVICE mkpart primary 0% 100%

sudo pvcreate $STORAGE_DEVICE

sudo vgcreate storage-vg $STORAGE_DEVICE

sudo lvcreate -l 100%FREE -n storage-lv storage-vg

sudo mkfs.ext4 /dev/storage-vg/storage-lv



# Step 5: Create mount point and mount

print_status "Creating mount point..."

sudo mkdir -p $STORAGE_MOUNT

echo '/dev/storage-vg/storage-lv /storage ext4 defaults 0 2' | sudo tee -a /etc/fstab

sudo mount -a



# Step 6: Create directory structure

print_status "Creating directory structure..."

sudo mkdir -p $STORAGE_MOUNT/{shared,nfs,sftp,backups}



# Step 7: Setup Samba for Windows sharing

print_status "Configuring Samba for Windows compatibility..."

sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.backup



# Create optimized Samba config for Windows

sudo tee /etc/samba/smb.conf > /dev/null << EOF

[global]

   workgroup = WORKGROUP

   server string = Ubuntu Storage Server

   security = user

   map to guest = Bad User

   name resolve order = bcast host

   wins support = yes

   socket options = TCP_NODELAY SO_RCVBUF=65536 SO_SNDBUF=65536

   max log size = 1000

   dns proxy = no



[Shared-Storage]

   path = $STORAGE_MOUNT/shared

   browsable = yes

   writable = yes

   guest ok = yes

   read only = no

   create mask = 0777

   directory mask = 0777

   force user = nobody

   force group = nogroup

   inherit permissions = yes

   inherit owner = yes



[Backups]

   path = $STORAGE_MOUNT/backups

   browsable = yes

   writable = yes

   valid users = @samba

   read only = no

   create mask = 0770

   directory mask = 0770

EOF



# Step 8: Create Samba user

print_status "Creating Samba user..."

sudo groupadd samba 2>/dev/null || true

sudo useradd -M -G samba -s /usr/sbin/nologin smbuser 2>/dev/null || true

echo -e "smbpass\nsmbpass" | sudo smbpasswd -a smbuser



# Step 9: Setup NFS

print_status "Configuring NFS..."

sudo tee /etc/exports > /dev/null << EOF

$STORAGE_MOUNT/nfs *(rw,sync,no_subtree_check,no_root_squash)

$STORAGE_MOUNT/shared *(rw,sync,no_subtree_check)

EOF



# Step 10: Setup SFTP user

print_status "Setting up SFTP user..."

sudo useradd -m -d $STORAGE_MOUNT/sftp -s /usr/sbin/nologin $SFTP_USER

echo -e "$SFTP_PASSWORD\n$SFTP_PASSWORD" | sudo passwd $SFTP_USER

sudo chown $SFTP_USER:$SFTP_USER $STORAGE_MOUNT/sftp

sudo chmod 755 $STORAGE_MOUNT/sftp

sudo mkdir -p $STORAGE_MOUNT/sftp/upload

sudo chown $SFTP_USER:$SFTP_USER $STORAGE_MOUNT/sftp/upload



# Configure SSH for SFTP

sudo tee -a /etc/ssh/sshd_config > /dev/null << EOF



# SFTP Configuration

Subsystem sftp internal-sftp



Match User $SFTP_USER

    ChrootDirectory $STORAGE_MOUNT/sftp

    ForceCommand internal-sftp

    PasswordAuthentication yes

    PermitTunnel no

    AllowAgentForwarding no

    AllowTcpForwarding no

    X11Forwarding no

EOF



# Step 11: Set permissions

print_status "Setting permissions..."

sudo chown -R nobody:nogroup $STORAGE_MOUNT/shared

sudo chown -R nobody:nogroup $STORAGE_MOUNT/nfs

sudo chmod -R 2775 $STORAGE_MOUNT/shared

sudo chmod -R 2775 $STORAGE_MOUNT/nfs



# Step 12: Configure firewall

print_status "Configuring firewall..."

sudo ufw --force enable

sudo ufw allow ssh

sudo ufw allow 139,445/tcp  # Samba

sudo ufw allow 2049/tcp     # NFS

sudo ufw allow 443/tcp      # HTTPS



# Step 13: Enable and start services

print_status "Starting services..."

sudo systemctl daemon-reload

sudo systemctl enable smbd nmbd nfs-kernel-server ssh

sudo systemctl restart smbd nmbd nfs-kernel-server ssh



# Step 14: Restart SSH for SFTP config

sudo systemctl restart ssh



# Step 15: Create management script

print_status "Creating management script..."

sudo tee /usr/local/bin/storage-manager > /dev/null << 'EOF'

#!/bin/bash

echo "=== Storage Server Manager ==="

echo "1. Show disk usage"

echo "2. Show service status"

echo "3. Restart all services"

echo "4. Check network shares"

echo "5. Show connection info"



read -p "Select option: " choice



case $choice in

    1) df -h /storage; du -sh /storage/* ;;

    2) systemctl status smbd nmbd nfs-kernel-server ssh ;;

    3) systemctl restart smbd nmbd nfs-kernel-server ssh ;;

    4) echo "Samba shares:"; smbclient -L localhost; echo "NFS exports:"; showmount -e localhost ;;

    5) 

        echo "=== Connection Information ==="

        echo "Samba: \\\\$(hostname -I | awk '{print $1}')\Shared-Storage"

        echo "Samba: \\\\$(hostname -I | awk '{print $1}')\Backups"

        echo "NFS: $(hostname -I | awk '{print $1}'):/storage/nfs"

        echo "SFTP: sftp://sftpuser@$(hostname -I | awk '{print $1}')"

        echo "SSH: ssh://$(whoami)@$(hostname -I | awk '{print $1}')"

        ;;

    *) echo "Invalid option" ;;

esac

EOF



sudo chmod +x /usr/local/bin/storage-manager



# Step 16: Final checks

print_status "Running final checks..."

sudo mount -a

df -h $STORAGE_MOUNT



# Step 17: Display connection information

echo "========================================="

echo -e "${GREEN}Setup Completed Successfully!${NC}"

echo "========================================="

echo "Storage Size: $(df -h $STORAGE_MOUNT | awk 'NR==2{print $2}')"

echo "Mount Point: $STORAGE_MOUNT"

echo ""

echo "=== Windows Connection Information ==="

echo "Samba Shares:"

echo "  Primary: \\\\$(hostname -I | awk '{print $1}')\\Shared-Storage"

echo "  Backups: \\\\$(hostname -I | awk '{print $1}')\\Backups"

echo ""

echo "=== Linux/Mac Connection Information ==="

echo "NFS: $(hostname -I | awk '{print $1}'):/storage/nfs"

echo "SFTP: sftp://$SFTP_USER@$(hostname -I | awk '{print $1}')"

echo ""

echo "=== Management ==="

echo "Run: storage-manager"

echo "Samba User: smbuser / smbpass"

echo "SFTP User: $SFTP_USER / $SFTP_PASSWORD"

echo "========================================="



print_warning "Please change default passwords in production environment!"
