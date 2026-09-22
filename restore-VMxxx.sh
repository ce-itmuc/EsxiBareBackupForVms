#!/bin/sh
#
# ESXi Restore Script
#
# Restores a VM from a backup created by our cold-backup script.
#
# IMPORTANT:
#   - The original VM is NOT modified.
#   - The backup is NOT modified.
#   - The restored VM receives a new ESXi display name.
#   - All virtual NICs are initially DISCONNECTED.
#   - VMware UUID/MAC identity data is regenerated.
#
#

# ============================================================
# Configuration
# ============================================================

SOURCE_VM_NAME="VMxxx"

# Allowed values:
#   current   = latest successful backup
#   previous  = backup generation before that
#
BACKUP_GENERATION="current"

BACKUP_ROOT="/vmfs/volumes/data/backup"

# New VM display name
RESTORE_VM_NAME="VMxxxRestore"

# Restore location
RESTORE_ROOT="/vmfs/volumes/data/restore"
RESTORE_DIR="${RESTORE_ROOT}/${RESTORE_VM_NAME}"

# Restore disks as thin-provisioned VMDKs
DISK_FORMAT="thin"

# Safer default for first test:
#
#   NO  = register VM but do not start it
#   YES = start VM after successful registration
#
POWER_ON_AFTER_RESTORE="NO"

POWERON_TIMEOUT=120
POLL_INTERVAL=5

LOCK_DIR="/tmp/${RESTORE_VM_NAME}-restore.lock"

DISK_LIST="/tmp/${RESTORE_VM_NAME}-restore-disks.$$"
NIC_LIST="/tmp/${RESTORE_VM_NAME}-restore-nics.$$"


# ============================================================
# Derived configuration
# ============================================================

case "$BACKUP_GENERATION" in

    current)
        BACKUP_DIR="${BACKUP_ROOT}/${SOURCE_VM_NAME}.current-backup"
        ;;

    previous)
        BACKUP_DIR="${BACKUP_ROOT}/${SOURCE_VM_NAME}.previous-backup"
        ;;

    *)
        echo "ERROR: BACKUP_GENERATION must be 'current' or 'previous'."
        exit 1
        ;;
esac


# ============================================================
# Safety checks for configured paths
# ============================================================

case "$BACKUP_ROOT" in
    /vmfs/volumes/data/backup)
        ;;
    *)
        echo "ERROR: Unexpected BACKUP_ROOT: $BACKUP_ROOT"
        exit 1
        ;;
esac


case "$RESTORE_ROOT" in
    /vmfs/volumes/data/restore)
        ;;
    *)
        echo "ERROR: Unexpected RESTORE_ROOT: $RESTORE_ROOT"
        exit 1
        ;;
esac


# ============================================================
# Helper functions
# ============================================================

log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') UTC  $*"
}


fail()
{
    log "ERROR: $*"
    exit 1
}


cleanup()
{
    RC=$?

    trap - 0 1 2 15

    rm -f "$DISK_LIST"
    rm -f "$NIC_LIST"

    rmdir "$LOCK_DIR" 2>/dev/null

    exit "$RC"
}


get_power_state()
{
    vim-cmd vmsvc/power.getstate "$1" 2>/dev/null | tail -1
}


# ============================================================
# Start
# ============================================================

trap cleanup 0 1 2 15


log "============================================================"
log "Starting RESTORE"
log "Source VM        : $SOURCE_VM_NAME"
log "Backup generation: $BACKUP_GENERATION"
log "Backup directory : $BACKUP_DIR"
log "Restore VM       : $RESTORE_VM_NAME"
log "Restore directory: $RESTORE_DIR"
log "============================================================"


# ------------------------------------------------------------
# Prevent concurrent restores
# ------------------------------------------------------------

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "Another restore appears to be running: $LOCK_DIR"
fi


# ------------------------------------------------------------
# Verify backup
# ------------------------------------------------------------

[ -d "$BACKUP_DIR" ] ||
    fail "Backup directory does not exist: $BACKUP_DIR"


[ -f "${BACKUP_DIR}/backup-complete" ] ||
    fail "Backup is not marked complete: $BACKUP_DIR"


log "Backup completeness marker found."


# ------------------------------------------------------------
# Locate backup VMX
# ------------------------------------------------------------

BACKUP_VMX="${BACKUP_DIR}/${SOURCE_VM_NAME}.vmx"


[ -f "$BACKUP_VMX" ] ||
    fail "Backup VMX not found: $BACKUP_VMX"


log "Backup VMX: $BACKUP_VMX"


# ------------------------------------------------------------
# Ensure restore VM is not already registered
# ------------------------------------------------------------

EXISTING_VMID="$(
    vim-cmd vmsvc/getallvms |
    awk -v vm="$RESTORE_VM_NAME" '
        NR > 1 && $2 == vm {
            print $1
            exit
        }
    '
)"


if [ -n "$EXISTING_VMID" ]; then

    fail "VM '$RESTORE_VM_NAME' is already registered with VMID $EXISTING_VMID."
fi


# ------------------------------------------------------------
# Refuse to overwrite an existing restore directory
# ------------------------------------------------------------

if [ -e "$RESTORE_DIR" ]; then

    fail "Restore directory already exists: $RESTORE_DIR"
fi


# ------------------------------------------------------------
# Create restore root
# ------------------------------------------------------------

[ -d "$RESTORE_ROOT" ] ||
    mkdir -p "$RESTORE_ROOT" ||
    fail "Cannot create restore root: $RESTORE_ROOT"


# ------------------------------------------------------------
# Basic capacity check
#
# Uses awk for arithmetic because ESXi/BusyBox shell integer
# comparisons can overflow on multi-TB datastores.
# ------------------------------------------------------------

BACKUP_KB="$(
    du -sk "$BACKUP_DIR" |
    awk '{print $1}'
)"

FREE_KB="$(
    df -k "$RESTORE_ROOT" |
    tail -1 |
    awk '{print $4}'
)"


[ -n "$BACKUP_KB" ] ||
    fail "Could not determine backup size."

[ -n "$FREE_KB" ] ||
    fail "Could not determine free datastore capacity."


REQUIRED_KB="$(
    awk -v size="$BACKUP_KB" \
        'BEGIN { printf "%.0f", size * 1.20 }'
)"


BACKUP_GIB="$(
    awk -v size="$BACKUP_KB" \
        'BEGIN { printf "%.2f", size / 1024 / 1024 }'
)"

FREE_GIB="$(
    awk -v size="$FREE_KB" \
        'BEGIN { printf "%.2f", size / 1024 / 1024 }'
)"

REQUIRED_GIB="$(
    awk -v size="$REQUIRED_KB" \
        'BEGIN { printf "%.2f", size / 1024 / 1024 }'
)"


log "Backup consumed size : ${BACKUP_GIB} GiB"
log "Datastore free space : ${FREE_GIB} GiB"
log "Required safety space: ${REQUIRED_GIB} GiB"


if ! awk \
    -v free="$FREE_KB" \
    -v required="$REQUIRED_KB" \
    'BEGIN { exit !(free >= required) }'
then

    fail "Not enough free datastore space for safe restore."
fi


# ------------------------------------------------------------
# Determine disks referenced by backup VMX
# ------------------------------------------------------------

awk -F'"' '

/^[[:space:]]*(scsi|sata|ide|nvme)[0-9]+:[0-9]+\.fileName = ".*\.vmdk"/ {

    key=$1

    sub(/^[[:space:]]*/, "", key)
    sub(/\.fileName[[:space:]]*=[[:space:]]*$/, "", key)
    sub(/[[:space:]]*$/, "", key)

    print key "|" $2
}

' "$BACKUP_VMX" > "$DISK_LIST"


[ -s "$DISK_LIST" ] ||
    fail "No VMDKs referenced by backup VMX."


log "Backup VMDKs:"


while IFS='|' read -r DISK_KEY DISK_REF
do

    #
    # Our backup format intentionally uses local standalone
    # disk names. Do NOT follow arbitrary absolute/datastore
    # references during restore.
    #

    case "$DISK_REF" in

        /*|\[*\]*)
            fail "Unsafe/non-local VMDK reference in backup VMX: $DISK_REF"
            ;;

    esac


    SOURCE_DISK="${BACKUP_DIR}/${DISK_REF}"


    [ -f "$SOURCE_DISK" ] ||
        fail "Backup VMDK not found: $SOURCE_DISK"


    log "  $DISK_KEY -> $DISK_REF"

done < "$DISK_LIST"


# ------------------------------------------------------------
# Verify backup VMDKs before creating anything
# ------------------------------------------------------------

log "Checking backup VMDK consistency..."


while IFS='|' read -r DISK_KEY DISK_REF
do

    SOURCE_DISK="${BACKUP_DIR}/${DISK_REF}"

    log "Checking: $SOURCE_DISK"


    if ! vmkfstools -e "$SOURCE_DISK"; then

        fail "VMDK consistency check failed: $SOURCE_DISK"
    fi

done < "$DISK_LIST"


# ------------------------------------------------------------
# Create restore directory
# ------------------------------------------------------------

mkdir "$RESTORE_DIR" ||
    fail "Could not create restore directory: $RESTORE_DIR"


log "Restore directory created."


# ------------------------------------------------------------
# Clone all VMDKs
#
# Disk filenames are intentionally retained.
# Because the restore has its own directory, there is no
# collision with source VM or backup.
# ------------------------------------------------------------

while IFS='|' read -r DISK_KEY DISK_REF
do

    SOURCE_DISK="${BACKUP_DIR}/${DISK_REF}"
    DEST_DISK="${RESTORE_DIR}/${DISK_REF}"


    log "------------------------------------------------------------"
    log "Cloning disk:"
    log "  Controller : $DISK_KEY"
    log "  Source     : $SOURCE_DISK"
    log "  Destination: $DEST_DISK"


    if [ -e "$DEST_DISK" ]; then

        fail "Restore disk already exists: $DEST_DISK"
    fi


    vmkfstools \
        -i "$SOURCE_DISK" \
        "$DEST_DISK" \
        -d "$DISK_FORMAT"


    RC=$?


    if [ "$RC" -ne 0 ]; then

        fail "vmkfstools failed for '$SOURCE_DISK' with RC=$RC."
    fi


    log "Disk clone completed."

done < "$DISK_LIST"


# ------------------------------------------------------------
# Copy VMX
# ------------------------------------------------------------

RESTORE_VMX="${RESTORE_DIR}/${RESTORE_VM_NAME}.vmx"


cp "$BACKUP_VMX" "$RESTORE_VMX" ||
    fail "Could not copy backup VMX."


# ------------------------------------------------------------
# Copy NVRAM if present
#
# We preserve the filename because the copied VMX already
# references it.
# ------------------------------------------------------------

for FILE in "${BACKUP_DIR}"/*.nvram
do

    [ -f "$FILE" ] || continue


    log "Copying NVRAM: $(basename "$FILE")"


    cp "$FILE" "$RESTORE_DIR/" ||
        fail "Could not copy NVRAM '$FILE'."

done


# ------------------------------------------------------------
# Sanitize VMX identity
#
# Remove identity/path metadata belonging to original VM.
#
# Broadcom recommends removing:
#
#   uuid.bios
#   uuid.location
#   vc.uuid
#
# so new UUIDs can be generated.
# ------------------------------------------------------------

log "Sanitizing restored VM configuration..."


sed -i \
    -e '/^[[:space:]]*displayName[[:space:]]*=/d' \
    -e '/^[[:space:]]*uuid\.bios[[:space:]]*=/d' \
    -e '/^[[:space:]]*uuid\.location[[:space:]]*=/d' \
    -e '/^[[:space:]]*uuid\.action[[:space:]]*=/d' \
    -e '/^[[:space:]]*vc\.uuid[[:space:]]*=/d' \
    -e '/^[[:space:]]*sched\.swap\.derivedName[[:space:]]*=/d' \
    -e '/^[[:space:]]*migrate\.hostLog[[:space:]]*=/d' \
    -e '/^[[:space:]]*checkpoint\.vmState[[:space:]]*=/d' \
    -e '/^[[:space:]]*extendedConfigFile[[:space:]]*=/d' \
    "$RESTORE_VMX"


echo "displayName = \"${RESTORE_VM_NAME}\"" >> "$RESTORE_VMX"


# ------------------------------------------------------------
# Disable Changed Block Tracking metadata for the restore copy
# ------------------------------------------------------------

sed -i \
    -e '/^[[:space:]]*ctkEnabled[[:space:]]*=/d' \
    -e '/^[[:space:]]*\(scsi\|sata\|ide\|nvme\)[0-9]*:[0-9]*\.ctkEnabled[[:space:]]*=/d' \
    "$RESTORE_VMX"


echo 'ctkEnabled = "FALSE"' >> "$RESTORE_VMX"


# ------------------------------------------------------------
# Discover NICs
# ------------------------------------------------------------

sed -n \
    's/^[[:space:]]*\(ethernet[0-9][0-9]*\)\..*/\1/p' \
    "$RESTORE_VMX" |
    sort -u \
    > "$NIC_LIST"


# ------------------------------------------------------------
# Disconnect all NICs and remove copied network identity
# ------------------------------------------------------------

if [ -s "$NIC_LIST" ]; then

    log "Preparing restored NICs:"


    while IFS= read -r NIC
    do

        log "  $NIC -> disconnected, new MAC on next power-on"


        sed -i \
            -e "/^[[:space:]]*${NIC}\.startConnected[[:space:]]*=/d" \
            -e "/^[[:space:]]*${NIC}\.addressType[[:space:]]*=/d" \
            -e "/^[[:space:]]*${NIC}\.address[[:space:]]*=/d" \
            -e "/^[[:space:]]*${NIC}\.generatedAddress[[:space:]]*=/d" \
            -e "/^[[:space:]]*${NIC}\.generatedAddressOffset[[:space:]]*=/d" \
            -e "/^[[:space:]]*${NIC}\.externalId[[:space:]]*=/d" \
            "$RESTORE_VMX"


        echo "${NIC}.startConnected = \"FALSE\"" \
            >> "$RESTORE_VMX"

        echo "${NIC}.addressType = \"generated\"" \
            >> "$RESTORE_VMX"

    done < "$NIC_LIST"

else

    log "No virtual NICs detected in VMX."
fi


# ------------------------------------------------------------
# Restore metadata
# ------------------------------------------------------------

{
    echo "Restore source VM: $SOURCE_VM_NAME"
    echo "Backup generation: $BACKUP_GENERATION"
    echo "Backup directory: $BACKUP_DIR"
    echo "Restore VM: $RESTORE_VM_NAME"
    echo "Restore directory: $RESTORE_DIR"
    echo "Restore created: $(date) UTC"
    echo
    echo "Network adapters were restored DISCONNECTED."
    echo "VM UUID identity was removed before registration."
    echo "Original VM and backup were not modified."
    echo
    echo "Source backup marker:"
    cat "${BACKUP_DIR}/backup-complete"

} > "${RESTORE_DIR}/restore-info.txt"


# ------------------------------------------------------------
# Register restored VM
# ------------------------------------------------------------

log "Registering restored VM..."


NEW_VMID="$(
    vim-cmd solo/registervm "$RESTORE_VMX" 2>&1
)"


case "$NEW_VMID" in

    ''|*[!0-9]*)

        log "Registration response: $NEW_VMID"
        fail "Could not register restored VM."
        ;;

esac


log "Restored VM registered successfully."
log "New VMID: $NEW_VMID"


echo "New VMID: $NEW_VMID" \
    >> "${RESTORE_DIR}/restore-info.txt"


# ------------------------------------------------------------
# Verify registration
# ------------------------------------------------------------

REGISTERED_NAME="$(
    vim-cmd vmsvc/getallvms |
    awk -v id="$NEW_VMID" '
        $1 == id {
            print $2
            exit
        }
    '
)"


[ "$REGISTERED_NAME" = "$RESTORE_VM_NAME" ] ||
    fail "Registered VM name mismatch: '$REGISTERED_NAME'"


log "Registration verified."


# ------------------------------------------------------------
# Optional power-on
#
# All NICs are still configured startConnected=FALSE.
# ------------------------------------------------------------

case "$POWER_ON_AFTER_RESTORE" in

    YES)

        log "Powering on restored VM with NICs disconnected..."


        vim-cmd vmsvc/power.on "$NEW_VMID" ||
            fail "Could not power on restored VM."


        ELAPSED=0


        while [ "$ELAPSED" -lt "$POWERON_TIMEOUT" ]
        do

            sleep "$POLL_INTERVAL"

            ELAPSED=$((ELAPSED + POLL_INTERVAL))

            STATE="$(get_power_state "$NEW_VMID")"

            log "Waiting for power-on: ${ELAPSED}s - $STATE"


            if [ "$STATE" = "Powered on" ]; then
                break
            fi

        done


        [ "$STATE" = "Powered on" ] ||
            fail "Restored VM did not reach Powered on state."


        log "Restored VM is powered on."

        ;;


    NO)

        log "POWER_ON_AFTER_RESTORE=NO"
        log "Restored VM remains powered off."

        ;;


    *)

        fail "POWER_ON_AFTER_RESTORE must be YES or NO."
        ;;
esac


# ------------------------------------------------------------
# Finished
# ------------------------------------------------------------

log "============================================================"
log "RESTORE SUCCESSFUL"
log "Backup generation: $BACKUP_GENERATION"
log "New VM name      : $RESTORE_VM_NAME"
log "New VMID         : $NEW_VMID"
log "Restore path     : $RESTORE_DIR"
log "NICs             : DISCONNECTED"
log "Power-on         : $POWER_ON_AFTER_RESTORE"
log "============================================================"


exit 0