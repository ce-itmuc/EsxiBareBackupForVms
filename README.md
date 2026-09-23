# ESXi Backup/Restore SH Scripts for VMs

This repo contains an backup and restore shell script for VMware ESXi. It relies only on shell (sh) and vim-cmd and vmkfstools, which are available on a bare ESXi host installation. The scripts were tested with VMware ESXi 8.0 Update 3.

## Scripts

The repository contains two scripts:

- backup-VMxxx.sh: creates a cold backup of a VM
- restore-VMxxx.sh: restores a backup as a separate VM

The scripts are designed parameterless, but can be easily adapted to operate with parameters. All parameters are defined in the beginning of the script, so please change SOURCE_VM_NAME (by default "VMxxx") and your backup root directory, which should correspond to the ESXi data vault directory. 

## Backup

The backup script gracefully shuts down the VM and creates standalone copies of its virtual disks using vmkfstools. After a successful backup, a VM that was running before the backup is powered on again.

Two generations are maintained: VMxxx.current-backup and VMxxx.previous-backup. A new backup is first written to a temporary staging directory. Only after it has completed successfully is it promoted to current-backup. The previous current backup becomes previous-backup.

### Snapshots

Existing VMware snapshots are not modified, deleted, reverted, or consolidated on the source VM. If the VM currently runs from a snapshot delta disk vmkfstools follows the VMDK chain and creates a standalone consolidated disk in the backup. The resulting backup represents the current VM state. Historical snapshot restore points are not preserved.

### Graceful shutdown

The script intentionally does not use a forced power-off. If the guest does not shut down within the configured timeout, the backup is aborted. VMware Tools or open-vm-tools should therefore be installed and running in the guest.

### Configuration

Typical settings in backup-VMxxx.sh:

```sh
VM_NAME="VMxxx"
BACKUP_ROOT="/vmfs/volumes/data/backup"
DISK_FORMAT="thin"
SHUTDOWN_TIMEOUT=600
POWERON_TIMEOUT=120
POLL_INTERVAL=10
```

## Restore

The restore script creates a new VM from either backup generation. The original VM and the backup are not modified. Select the backup generation using: BACKUP_GENERATION="current" or "previous".

Typical restore configuration:

```sh
SOURCE_VM_NAME="VMxxx"
BACKUP_GENERATION="current"
BACKUP_ROOT="/vmfs/volumes/data/backup"
RESTORE_VM_NAME="VMxxxRestore"
RESTORE_ROOT="/vmfs/volumes/data/restore"
DISK_FORMAT="thin"
POWER_ON_AFTER_RESTORE="NO"
```

The restore process:
1. verifies the selected backup
2. checks the VMDK chain
3. clones the backup disks into a new directory
4. creates a separate VM configuration
5. assigns the new VM display name
6. removes copied VMware UUID information
7. disconnects the restored VM's network adapters
8. registers the new VM on the ESXi host

By default the restored VM remains powered off.

## Network isolation

Virtual network adapters of a restored VM are initially disconnected. This prevents accidental network conflicts when the original VM still exists and the restored guest still contains the same:
- hostname
- static IP address
- application identities
- certificates
- cluster configuration

## Disclaimer

Use these scripts at your own risk. Always test backup and restore procedures with non-critical workloads before relying on them for production recovery.

