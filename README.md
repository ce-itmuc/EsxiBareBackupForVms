# ESXi Backup/Restore SH Scripts for VMs

This repo contains an backup and restore shell script for ESXi 9.1 without additional tools like OVF tool or vSphere. It relies only on shell (sh) and vmkfstools, which are available on a bare ESXi host installation.

The scripts are designed parameterless, but can be easily adapted to operate with parameters. All parameters are defined in the beginning of the script, so please change SOURCE_VM_NAME (by default "VMxxx") and your backup root directory, which should correspond to the ESXi data vault directory. 
