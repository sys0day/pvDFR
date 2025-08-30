#!/bin/bash

# pvDFR - Physical Volume Data and File Recovery
# Author: sys0day
# Description: Storage setup and management script

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should not be run as root"
        exit 1
    fi
}

# Check for sudo privileges
check_sudo() {
    if ! sudo -v; then
        log_error "User does not have sudo privileges"
        exit 1
    fi
}

# Update system packages
update_system() {
    log_info "(1) Updating system packages..."
    sudo apt update
    sudo apt upgrade -y
    log_success "System updated successfully"
}

# Install required packages
install_packages() {
    log_info "(2) Installing required packages..."
    
    # Define packages array
    packages=(
        lvm2
        parted
        samba
        samba-common-bin
        nfs-kernel-server
        fail2ban
        ufw
        curl
        wget
        vim
        htop
    )
    
    # Install packages
    if sudo apt install -y "${packages[@]}"; then
        log_success "Packages installed successfully"
    else
        log_error "Failed to install packages"
        exit 1
    fi
    
    # Verify critical packages are installed
    log_info "Verifying package installation..."
    for pkg in lvm2 parted samba nfs-kernel-server; do
        if dpkg -l | grep -q "^ii  $pkg "; then
            log_success "$pkg is installed correctly"
        else
            log_error "$pkg is not installed properly"
            exit 1
        fi
    done
}

# Setup storage device
setup_storage() {
    local device="${1:-/dev/sdb}"
    
    log_info "(3) Setting up storage device $device"
    
    # Check if device exists
    if [[ ! -b "$device" ]]; then
        log_error "Device $device not found or not a block device"
        exit 1
    fi
    
    # Check if device is mounted
    if mount | grep -q "$device"; then
        log_warning "Device $device is mounted. Unmounting..."
        sudo umount "$device"* 2>/dev/null || true
    fi
    
    # Clear previous setup
    log_info "Clearing up previous setup..."
    sudo wipefs -a "$device"
    sudo dd if=/dev/zero of="$device" bs=1M count=100 status=progress
    log_success "Previous setup cleared"
    
    # Create partition
    log_info "Creating partition on $device..."
    sudo parted "$device" mklabel gpt
    sudo parted "$device" mkpart primary 0% 100%
    sudo parted "$device" set 1 lvm on
    
    # Refresh partition table
    sudo partprobe "$device"
    
    # Create physical volume
    local partition="${device}1"
    log_info "Creating physical volume on $partition..."
    sudo pvcreate "$partition"
    
    # Create volume group
    log_info "Creating volume group..."
    sudo vgcreate storage_vg "$partition"
    
    # Create logical volume
    log_info "Creating logical volume..."
    sudo lvcreate -l 100%FREE -n storage_lv storage_vg
    
    # Format the volume
    log_info "Formatting logical volume..."
    sudo mkfs.ext4 /dev/storage_vg/storage_lv
    
    # Create mount point
    log_info "Creating mount point..."
    sudo mkdir -p /mnt/storage
    if [ ! -d "/mnt/storage" ]; then
        sudo mkdir -p "/mnt/storage" || {
            log_error "Failed to create directory /mnt/storage"
            exit 1
        }
    fi
    
    # Mount the volume
    log_info "Mounting storage..."
    sudo mount /dev/storage_vg/storage_lv /mnt/storage
    
    # Add to fstab for automatic mounting
    log_info "Adding to fstab..."
    echo "/dev/storage_vg/storage_lv /mnt/storage ext4 defaults 0 2" | sudo tee -a /etc/fstab
    
    log_success "Storage setup completed successfully"
}

# Setup Samba share
setup_samba() {
    log_info "(4) Setting up Samba share..."
    
    # Backup original smb.conf
    sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.backup
    
    # Add share configuration
    cat << EOF | sudo tee -a /etc/samba/smb.conf
[storage]
   path = /mnt/storage
   browseable = yes
   read only = no
   guest ok = no
   valid users = $USER
   create mask = 0775
   directory mask = 0775
EOF
    
    # Set Samba password
    log_info "Setting Samba password for user $USER"
    sudo smbpasswd -a "$USER"
    
    # Restart Samba service
    sudo systemctl restart smbd
    sudo systemctl enable smbd
    
    log_success "Samba share setup completed"
}

# Setup NFS share
setup_nfs() {
    log_info "(5) Setting up NFS share..."
    
    # Add to exports
    echo "/mnt/storage *(rw,sync,no_subtree_check)" | sudo tee -a /etc/exports
    
    # Export and restart NFS
    sudo exportfs -a
    sudo systemctl restart nfs-kernel-server
    sudo systemctl enable nfs-kernel-server
    
    log_success "NFS share setup completed"
}

# Setup firewall
setup_firewall() {
    log_info "(6) Setting up firewall..."
    
    # Enable UFW
    sudo ufw enable
    
    # Allow SSH
    sudo ufw allow ssh
    
    # Allow Samba ports
    sudo ufw allow 139/tcp
    sudo ufw allow 445/tcp
    
    # Allow NFS ports
    sudo ufw allow 111/tcp
    sudo ufw allow 2049/tcp
    sudo ufw allow from any to any port nfs
    
    log_success "Firewall setup completed"
}

# Main execution function
main() {
    echo "=========================================="
    echo "   pvDFR - Storage Server Setup Script    "
    echo "=========================================="
    
    check_root
    check_sudo
    
    # Default device
    local storage_device="/dev/sdb"
    
    # Ask for device if not provided
    if [[ $# -eq 0 ]]; then
        echo "Available storage devices:"
        lsblk -d -o NAME,SIZE,MODEL | grep -v "NAME"
        read -rp "Enter storage device to use (default: /dev/sdb): " user_device
        storage_device="${user_device:-/dev/sdb}"
    else
        storage_device="$1"
    fi
    
    log_info "Target: Windows Convertible Storage Server"
    log_info "Creating storage container on $storage_device"
    
    # Execute all setup steps
    update_system
    install_packages
    setup_storage "$storage_device"
    setup_samba
    setup_nfs
    setup_firewall
    
    # Final summary
    echo "=========================================="
    log_success "Storage Server Setup Completed!"
    echo ""
    log_info "Storage Location: /mnt/storage"
    log_info "Samba Share: //$(hostname -I | awk '{print $1}')/storage"
    log_info "NFS Share: $(hostname -I | awk '{print $1}'):/mnt/storage"
    echo ""
    log_info "Remember to:"
    log_info "1. Configure fail2ban for additional security"
    log_info "2. Set up regular backups"
    log_info "3. Monitor storage usage"
    echo "=========================================="
}

# Handle script execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
