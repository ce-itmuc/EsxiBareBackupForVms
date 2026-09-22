#!/bin/sh
#
# ESXi Cold Backup
#
# Creates a standalone, consolidated backup of the CURRENT VM state.
#
# Existing VMware snapshots:
#   - are detected and documented
#   - are NOT deleted
#   - are NOT consolidated on the source VM
#   - are NOT modified in any way
#
# If the active VM disk is a snapshot delta VMDK, vmkfstools -i
# follows the snapshot parent chain and creates a standalone
# consolidated VMDK in the backup.
#
# Backup layout:
#
#   /vmfs/volumes/data/backup/VMxxx.current-backup
#   /vmfs/volumes/data/backup/VMxxx.previous-backup
#
# No command-line parameters.
#

# ============================================================
# Configuration
# ============================================================

VM_NAME="VMxxx"

BACKUP_ROOT="/vmfs/volumes/data/backup"

CURRENT_BACKUP="${BACKUP_ROOT}/${VM_NAME}.current-backup"
PREVIOUS_BACKUP="${BACKUP_ROOT}/${VM_NAME}.previous-backup"

# Temporary backup directory for the currently running job
STAGING_BACKUP="${BACKUP_ROOT}/${VM_NAME}.new-backup.$$"

DISK_FORMAT="thin"

SHUTDOWN_TIMEOUT=600
POWERON_TIMEOUT=120
POLL_INTERVAL=10

LOCK_DIR="/tmp/${VM_NAME}-backup.lock"

DISK_LIST="/tmp/${VM_NAME}-backup-disks.$$"
DISK_MAP="/tmp/${VM_NAME}-backup-map.$$"


# ============================================================
# Safety check
# ============================================================

case "$BACKUP_ROOT" in
    /vmfs/volumes/data/backup)
        ;;
    *)
        echo "ERROR: Unexpected BACKUP_ROOT: $BACKUP_ROOT"
        exit 1
        ;;
esac


# ============================================================
# Runtime state
# ============================================================

VMID=""

VM_WAS_POWERED_ON=0
VM_WAS_SHUT_DOWN_BY_SCRIPT=0

STAGING_CREATED=0
STAGING_COMPLETE=0


# ============================================================
# Helper functions
# ============================================================

log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') UTC  $*"
}


get_power_state()
{
    vim-cmd vmsvc/power.getstate "$VMID" 2>/dev/null | tail -1
}


safe_remove_backup_dir()
{
    DIR="$1"

    if [ "$DIR" = "$CURRENT_BACKUP" ] ||
       [ "$DIR" = "$PREVIOUS_BACKUP" ] ||
       [ "$DIR" = "$STAGING_BACKUP" ]; then

        rm -rf "$DIR"
        return $?
    fi

    log "ERROR: Refusing unsafe rm -rf: $DIR"
    return 1
}


power_vm_back_on()
{
    if [ "$VM_WAS_POWERED_ON" -ne 1 ] ||
       [ "$VM_WAS_SHUT_DOWN_BY_SCRIPT" -ne 1 ]; then
        return 0
    fi


    STATE="$(get_power_state)"

    if [ "$STATE" = "Powered on" ]; then
        VM_WAS_SHUT_DOWN_BY_SCRIPT=0
        return 0
    fi


    if [ "$STATE" != "Powered off" ]; then
        log "WARNING: Unexpected VM state while trying to restart: $STATE"
    fi


    log "Powering VM '$VM_NAME' back on..."

    if ! vim-cmd vmsvc/power.on "$VMID"; then
        log "ERROR: VM power-on command failed."
        return 1
    fi


    ELAPSED=0

    while [ "$ELAPSED" -lt "$POWERON_TIMEOUT" ]
    do
        sleep 5

        ELAPSED=$((ELAPSED + 5))
        STATE="$(get_power_state)"

        log "Waiting for power-on: ${ELAPSED}s - $STATE"

        if [ "$STATE" = "Powered on" ]; then
            VM_WAS_SHUT_DOWN_BY_SCRIPT=0
            log "VM '$VM_NAME' is powered on."
            return 0
        fi
    done


    log "ERROR: VM did not reach Powered on state within ${POWERON_TIMEOUT}s."
    return 1
}


cleanup()
{
    RC=$?

    trap - 0 1 2 15


    #
    # Highest priority on failure:
    # make sure a VM which we shut down gets restarted.
    #

    if ! power_vm_back_on; then
        log "CRITICAL: Automatic VM restart was unsuccessful!"
        RC=2
    fi


    rm -f "$DISK_LIST"
    rm -f "$DISK_MAP"


    #
    # Remove an incomplete staging backup.
    #
    # A COMPLETED staging backup is deliberately preserved
    # if a later rotation step failed.
    #

    if [ "$STAGING_CREATED" -eq 1 ] &&
       [ "$STAGING_COMPLETE" -eq 0 ] &&
       [ -d "$STAGING_BACKUP" ]; then

        log "Removing incomplete staging backup."

        safe_remove_backup_dir "$STAGING_BACKUP"
    fi


    rmdir "$LOCK_DIR" 2>/dev/null

    exit "$RC"
}


fail()
{
    log "ERROR: $*"
    exit 1
}


resolve_vmdk_path()
{
    REF="$1"

    case "$REF" in

        /vmfs/volumes/*)
            echo "$REF"
            ;;

        \[*\]*)

            DATASTORE="$(echo "$REF" |
                sed -n 's/^\[\([^]]*\)\].*/\1/p')"

            RELATIVE="$(echo "$REF" |
                sed 's/^\[[^]]*\][[:space:]]*//' |
                sed 's/[[:space:]]*$//')"

            DATASTORE_PATH="$(
                cd "/vmfs/volumes/${DATASTORE}" 2>/dev/null &&
                pwd -P
            )"

            [ -n "$DATASTORE_PATH" ] || return 1

            echo "${DATASTORE_PATH}/${RELATIVE}"
            ;;

        *)
            echo "${VM_DIR}/${REF}"
            ;;
    esac
}


# ============================================================
# Start
# ============================================================

trap cleanup 0 1 2 15


log "============================================================"
log "Starting backup of VM '$VM_NAME'"
log "============================================================"


# ------------------------------------------------------------
# Prevent concurrent backup jobs
# ------------------------------------------------------------

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "Another backup appears to be running: $LOCK_DIR"
fi


# ------------------------------------------------------------
# Backup directory
# ------------------------------------------------------------

[ -d "$BACKUP_ROOT" ] ||
    mkdir -p "$BACKUP_ROOT" ||
    fail "Cannot create backup directory '$BACKUP_ROOT'."


# ------------------------------------------------------------
# Locate VM
# ------------------------------------------------------------

VMID_LIST="$(
    vim-cmd vmsvc/getallvms |
    awk -v vm="$VM_NAME" 'NR > 1 && $2 == vm { print $1 }'
)"

VM_COUNT="$(
    echo "$VMID_LIST" |
    grep -c '^[0-9][0-9]*$'
)"


[ "$VM_COUNT" -eq 1 ] ||
    fail "Expected exactly one VM named '$VM_NAME', found $VM_COUNT."


VMID="$VMID_LIST"

log "VMID: $VMID"


# ------------------------------------------------------------
# Locate VMX
# ------------------------------------------------------------

VMX_REFERENCE="$(
    vim-cmd vmsvc/get.config "$VMID" |
    sed -n 's/^[[:space:]]*vmPathName = "\(.*\)",/\1/p' |
    head -1 |
    sed 's/[[:space:]]*$//'
)"


[ -n "$VMX_REFERENCE" ] ||
    fail "Could not determine VMX path."


log "VMX reference reported by ESXi: $VMX_REFERENCE"


case "$VMX_REFERENCE" in

    \[*\]*)

        VM_DATASTORE="$(echo "$VMX_REFERENCE" |
            sed -n 's/^\[\([^]]*\)\].*/\1/p')"

        VMX_RELATIVE="$(echo "$VMX_REFERENCE" |
            sed 's/^\[[^]]*\][[:space:]]*//' |
            sed 's/[[:space:]]*$//')"

        VM_DATASTORE_PATH="$(
            cd "/vmfs/volumes/${VM_DATASTORE}" 2>/dev/null &&
            pwd -P
        )"


        [ -n "$VM_DATASTORE_PATH" ] ||
            fail "Could not resolve datastore '$VM_DATASTORE'."


        VMX_PATH="${VM_DATASTORE_PATH}/${VMX_RELATIVE}"
        ;;


    /vmfs/volumes/*)

        VMX_PATH="$VMX_REFERENCE"
        ;;


    *)

        fail "Unexpected VMX path format: $VMX_REFERENCE"
        ;;
esac


[ -f "$VMX_PATH" ] ||
    fail "VMX file does not exist: $VMX_PATH"


VM_DIR="$(dirname "$VMX_PATH")"
VMX_FILE="$(basename "$VMX_PATH")"


log "Resolved VMX: $VMX_PATH"


# ------------------------------------------------------------
# Detect snapshots - DO NOT modify them
# ------------------------------------------------------------

SNAPSHOT_INFO="$(vim-cmd vmsvc/snapshot.get "$VMID" 2>&1)"


if echo "$SNAPSHOT_INFO" | grep -q "Snapshot Name"; then

    log "Existing VMware snapshot(s) detected."
    log "Snapshots will NOT be modified."
    log "Active snapshot chain will be consolidated only in the backup."

    echo "$SNAPSHOT_INFO"

else

    log "No VMware snapshots reported by ESXi."
fi


# ------------------------------------------------------------
# Determine attached VMDKs
#
# DISK_LIST:
#
#   scsi0:0|VMxxx-000001.vmdk
#
# ------------------------------------------------------------

awk -F'"' '

/^(scsi|sata|ide|nvme)[0-9]+:[0-9]+\.fileName = ".*\.vmdk"/ {

    key=$1

    sub(/\.fileName[[:space:]]*=[[:space:]]*$/, "", key)
    sub(/[[:space:]]*$/, "", key)

    print key "|" $2
}

' "$VMX_PATH" > "$DISK_LIST"


[ -s "$DISK_LIST" ] ||
    fail "No attached VMDKs found in VM configuration."


log "Attached VMDKs:"


> "$DISK_MAP"


while IFS='|' read -r DISK_KEY DISK_REF
do

    SOURCE_DISK="$(resolve_vmdk_path "$DISK_REF")"

    [ -n "$SOURCE_DISK" ] ||
        fail "Could not resolve VMDK reference: $DISK_REF"


    [ -f "$SOURCE_DISK" ] ||
        fail "Source VMDK not found: $SOURCE_DISK"


    SOURCE_NAME="$(basename "$SOURCE_DISK")"


    #
    # A snapshot disk such as:
    #
    #   VMxxx-000001.vmdk
    #
    # becomes a standalone backup disk:
    #
    #   VMxxx.vmdk
    #

    DEST_NAME="$(
        echo "$SOURCE_NAME" |
        sed 's/-[0-9][0-9][0-9][0-9][0-9][0-9]\.vmdk$/.vmdk/'
    )"


    log "  $DISK_KEY"
    log "    VMX reference : $DISK_REF"
    log "    Source        : $SOURCE_DISK"
    log "    Backup name   : $DEST_NAME"


    echo "${DISK_KEY}|${DISK_REF}|${SOURCE_DISK}|${DEST_NAME}" \
        >> "$DISK_MAP"

done < "$DISK_LIST"


# ------------------------------------------------------------
# Ensure resulting disk names are unique
# ------------------------------------------------------------

DUPLICATE_DEST="$(
    cut -d'|' -f4 "$DISK_MAP" |
    sort |
    uniq -d |
    head -1
)"


[ -z "$DUPLICATE_DEST" ] ||
    fail "Multiple source disks would become '$DUPLICATE_DEST' in backup."


# ------------------------------------------------------------
# Check initial VM power state
# ------------------------------------------------------------

STATE="$(get_power_state)"

log "Current VM state: $STATE"


case "$STATE" in

    "Powered on")

        VM_WAS_POWERED_ON=1

        log "Requesting graceful guest shutdown..."

        vim-cmd vmsvc/power.shutdown "$VMID" ||
            fail "Guest shutdown request failed."


        ELAPSED=0


        while [ "$ELAPSED" -lt "$SHUTDOWN_TIMEOUT" ]
        do

            sleep "$POLL_INTERVAL"

            ELAPSED=$((ELAPSED + POLL_INTERVAL))
            STATE="$(get_power_state)"

            log "Waiting for shutdown: ${ELAPSED}s - $STATE"


            if [ "$STATE" = "Powered off" ]; then

                VM_WAS_SHUT_DOWN_BY_SCRIPT=1
                break
            fi
        done


        if [ "$STATE" != "Powered off" ]; then

            fail "Graceful shutdown did not finish within ${SHUTDOWN_TIMEOUT}s."
        fi

        ;;


    "Powered off")

        log "VM is already powered off."
        ;;


    *)

        fail "Unexpected VM power state: $STATE"
        ;;
esac


#
# Give VMFS a few seconds to release disk locks.
#

sleep 5


# ------------------------------------------------------------
# Verify VMDK chains before cloning
# ------------------------------------------------------------

log "Checking VMDK chain consistency..."


while IFS='|' read -r DISK_KEY DISK_REF SOURCE_DISK DEST_NAME
do

    log "Checking: $SOURCE_DISK"


    if ! vmkfstools -e "$SOURCE_DISK"; then

        fail "VMDK chain consistency check failed: $SOURCE_DISK"
    fi

done < "$DISK_MAP"


# ------------------------------------------------------------
# Create staging directory
# ------------------------------------------------------------

if [ -e "$STAGING_BACKUP" ]; then

    fail "Staging directory already exists: $STAGING_BACKUP"
fi


mkdir -p "$STAGING_BACKUP" ||
    fail "Could not create staging backup directory."


STAGING_CREATED=1


# ------------------------------------------------------------
# Backup information
# ------------------------------------------------------------

{
    echo "Backup type: ESXi cold VMDK clone"
    echo
    echo "VM display name: $VM_NAME"
    echo "VMID: $VMID"
    echo "ESXi host: $(hostname)"
    echo "Backup started: $(date) UTC"
    echo
    echo "Source VMX: $VMX_PATH"
    echo "Disk format: $DISK_FORMAT"
    echo
    echo "IMPORTANT:"
    echo "Existing source snapshots were NOT modified."
    echo "Backup disks are standalone consolidated clones"
    echo "of the active VM disk chains."
    echo "Historical snapshot restore points are NOT preserved."
    echo
    echo "VMware version:"
    vmware -vl
    echo
    echo "Snapshot information:"
    echo "$SNAPSHOT_INFO"
    echo
    echo "Disk mapping:"
    cat "$DISK_MAP"

} > "${STAGING_BACKUP}/backup-info.txt"


# ------------------------------------------------------------
# Copy VM metadata
#
# Deliberately NOT copied:
#
#   .vmsd   snapshot metadata
#   .vmsn   snapshot VM state
#
# because backup disks are standalone consolidated disks.
# ------------------------------------------------------------

log "Copying VM configuration files..."


cp "$VMX_PATH" "${STAGING_BACKUP}/${VMX_FILE}" ||
    fail "Could not copy VMX."


for EXT in nvram vmxf
do

    for FILE in "${VM_DIR}"/*.${EXT}
    do

        [ -f "$FILE" ] || continue


        cp "$FILE" "$STAGING_BACKUP/" ||
            fail "Could not copy '$FILE'."

    done

done


BACKUP_VMX="${STAGING_BACKUP}/${VMX_FILE}"


# ------------------------------------------------------------
# Clone attached VMDKs
# ------------------------------------------------------------

while IFS='|' read -r DISK_KEY DISK_REF SOURCE_DISK DEST_NAME
do

    DEST_DISK="${STAGING_BACKUP}/${DEST_NAME}"


    if [ -e "$DEST_DISK" ]; then

        fail "Destination VMDK already exists: $DEST_DISK"
    fi


    log "------------------------------------------------------------"
    log "Cloning disk:"
    log "  Controller : $DISK_KEY"
    log "  Source     : $SOURCE_DISK"
    log "  Destination: $DEST_DISK"


    vmkfstools \
        -i "$SOURCE_DISK" \
        "$DEST_DISK" \
        -d "$DISK_FORMAT"


    RC=$?


    if [ "$RC" -ne 0 ]; then

        fail "vmkfstools failed for '$SOURCE_DISK' with RC=$RC."
    fi


    #
    # Rewrite copied VMX so it references the standalone
    # cloned disk rather than the source snapshot descriptor.
    #

    sed -i \
        "s#^[[:space:]]*${DISK_KEY}\.fileName = \".*\"#${DISK_KEY}.fileName = \"${DEST_NAME}\"#" \
        "$BACKUP_VMX"


    if ! grep -F \
        "${DISK_KEY}.fileName = \"${DEST_NAME}\"" \
        "$BACKUP_VMX" >/dev/null 2>&1; then

        fail "Could not update disk reference for $DISK_KEY in backup VMX."
    fi


    log "Disk clone completed."

done < "$DISK_MAP"


# ------------------------------------------------------------
# Mark staging backup as complete
# ------------------------------------------------------------

{
    echo "VM: $VM_NAME"
    echo "Completed: $(date) UTC"
    echo "ESXi host: $(hostname)"

} > "${STAGING_BACKUP}/backup-complete"


STAGING_COMPLETE=1


log "All backup data created successfully."


# ------------------------------------------------------------
# Restart source VM immediately
#
# Do this BEFORE rotating backups so VM downtime is minimized.
# ------------------------------------------------------------

if ! power_vm_back_on; then

    fail "Backup data is complete, but source VM could not be restarted."
fi


# ------------------------------------------------------------
# Rotate backups
#
# Only reached AFTER:
#
#   - all VMDKs cloned successfully
#   - backup marked complete
#   - source VM restarted successfully (if it was running before)
# ------------------------------------------------------------

log "Rotating backup generations..."


if [ -d "$CURRENT_BACKUP" ]; then


    if [ -f "${CURRENT_BACKUP}/backup-complete" ]; then

        log "Existing current backup is valid."


        if [ -d "$PREVIOUS_BACKUP" ]; then

            log "Removing old previous backup."

            safe_remove_backup_dir "$PREVIOUS_BACKUP" ||
                fail "Could not remove previous backup."
        fi


        log "Moving current backup to previous backup."

        mv "$CURRENT_BACKUP" "$PREVIOUS_BACKUP" ||
            fail "Could not rotate current backup to previous backup."


    else

        log "Existing current backup is incomplete."
        log "Removing incomplete current backup."

        safe_remove_backup_dir "$CURRENT_BACKUP" ||
            fail "Could not remove incomplete current backup."

        #
        # Existing PREVIOUS backup is deliberately retained.
        #
    fi

fi


log "Promoting new backup to current backup."


mv "$STAGING_BACKUP" "$CURRENT_BACKUP" ||
    fail "Could not promote staging backup to current backup."


STAGING_CREATED=0
STAGING_COMPLETE=0


# ------------------------------------------------------------
# Finished
# ------------------------------------------------------------

log "============================================================"
log "BACKUP SUCCESSFUL"
log "Current backup : $CURRENT_BACKUP"
log "Previous backup: $PREVIOUS_BACKUP"
log "============================================================"


exit 0