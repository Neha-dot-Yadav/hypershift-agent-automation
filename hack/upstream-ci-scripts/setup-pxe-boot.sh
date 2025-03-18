#!/bin/bash

# This script sets up PXE boot for agents created via upstream CI.
# Run this script inside the bastion configured for PXE boot.
# Usage: ./setup-pxe-boot.sh $CLUSTER_NAME $NODE_COUNT $NODE_1_DETAIL ...
# $NODE_1_DETAIL - Pass name, MAC, and IP details separated by a comma.
#
# Sample usage: ./setup-pxe-boot.sh dummy 2 agent-1,fa:c5:e7:72:da:20,192.168.140.10 agent-2,fa:fd:c9:9d:9f:20,192.168.140.11
#

set -x
set -e

export CLUSTER_NAME=$1
if [ -z "$CLUSTER_NAME" ]; then
  echo "CLUSTER_NAME is not passed"
  exit 1
fi

NODE_COUNT=$2
if [ -z "$NODE_COUNT" ]; then
  echo "NODE_COUNT is not passed"
  exit 1
fi

GRUB_MENU_START="# menuentry for ${CLUSTER_NAME} start"
GRUB_MENU_END="# menuentry for ${CLUSTER_NAME} end"

# Parse server details
SERVER_NAME=()
MAC=()
IP=()

IFS=','

for arg in "${@:3}"; do
    read -ra serverDet <<< "$arg"
    indexArg=0
    for det in "${serverDet[@]}"; do
        case "$indexArg" in
            0) SERVER_NAME+=("$det") ;;
            1) MAC+=("$det") ;;
            2) IP+=("$det") ;;
        esac
        indexArg=$((indexArg+1))
    done
done

if [ ${#SERVER_NAME[@]} -ne ${NODE_COUNT} ] || [ ${#MAC[@]} -ne ${NODE_COUNT} ] || [ ${#IP[@]} -ne ${NODE_COUNT} ]; then
  echo "Node count does not match the server details provided"
  exit 1
fi

ISO_FILE="/tmp/${CLUSTER_NAME}.iso"
DISCOVERY_ISO_DOWNLOAD_LINK_FILE="/tmp/${CLUSTER_NAME}-iso-download-link"

# Download discovery ISO
curl -k "$(cat ${DISCOVERY_ISO_DOWNLOAD_LINK_FILE})" -o "${ISO_FILE}"

# Mount ISO
MOUNT_LOCATION="/mnt/${CLUSTER_NAME}"
mkdir -p ${MOUNT_LOCATION}
mount -o loop ${ISO_FILE} ${MOUNT_LOCATION}

# Copy images from mount
mkdir -p /var/lib/tftpboot/images/${CLUSTER_NAME}
cp -rf ${MOUNT_LOCATION}/images/* /var/lib/tftpboot/images/${CLUSTER_NAME}

# Extract GRUB menu entry
MENU_ENTRY_CONTENT=$(sed -n "/menuentry /,/}/p" /mnt/${CLUSTER_NAME}/boot/grub/grub.cfg | sed '1d;$d' | sed "s|/images|/images/${CLUSTER_NAME}|g")
MENU_ENTRY_CONTENT=$(echo "$MENU_ENTRY_CONTENT" | envsubst)

# Extract and Modify Ignition Config
IGNITION_CONFIG="${MOUNT_LOCATION}/config.ign"
UPDATED_IGNITION_CONFIG="/var/www/html/${CLUSTER_NAME}/config-updated.ign"

if [ -f "$IGNITION_CONFIG" ]; then
    echo "Modifying Ignition config to include afterburn-hostname.service..."
    jq '.systemd.units += [{
        "name": "afterburn-hostname.service",
        "enabled": true,
        "contents": "[Unit]\nDescription=Afterburn Hostname\nBefore=network-online.target\nAfter=NetworkManager-wait-online.service\nBefore=node-valid-hostname.service\n[Service]\nExecStart=/usr/bin/afterburn --provider powervs --hostname=/etc/hostname\nType=oneshot\n[Install]\nWantedBy=network-online.target"
    }]' "$IGNITION_CONFIG" > "$UPDATED_IGNITION_CONFIG"
else
    echo "Ignition configuration not found in ISO. Exiting..."
    exit 1
fi

# Update GRUB menu entry with modified Ignition URL
MENU_ENTRY_CONTENT=$(echo "$MENU_ENTRY_CONTENT" | sed "s|coreos.inst.ignition_url=[^ ]*|coreos.inst.ignition_url=http://192.168.140.2/${CLUSTER_NAME}/config-updated.ign|g")
export MENU_ENTRY_CONTENT

# Download rootfs image
ROOTFS_DOWNLOAD_LINK=$(echo "$MENU_ENTRY_CONTENT" | sed -n "s/.*\(https:\/\/[^[:space:]\']*\).*/\1/p")
mkdir -p /var/www/html/${CLUSTER_NAME}
curl -k "$ROOTFS_DOWNLOAD_LINK" --output /var/www/html/${CLUSTER_NAME}/rootfs.img

# Modify rootfs URL in GRUB menu
MENU_ENTRY_CONTENT=$(echo "$MENU_ENTRY_CONTENT" | sed "s|'coreos.live.rootfs_url=[^ ]*'|'coreos.live.rootfs_url=http://192.168.140.2/${CLUSTER_NAME}/rootfs.img'|g")

# Generate GRUB Menu Output
export GRUB_MAC_CONFIG="\${net_default_mac}"
GRUB_MENU_OUTPUT="${GRUB_MENU_START}\n"

for (( i = 0; i < ${NODE_COUNT}; i++ )); do
    export SERVER_MAC=${MAC[i]}
    CONFIG=$(cat grub-menu.template | envsubst)
    GRUB_MENU_OUTPUT+="${CONFIG}\n"
done

GRUB_MENU_OUTPUT+="\n${GRUB_MENU_END}"
GRUB_MENU_OUTPUT_FILE="/tmp/${CLUSTER_NAME}-grub-menu.output"
echo -e "${GRUB_MENU_OUTPUT}" > "${GRUB_MENU_OUTPUT_FILE}"

# Add a newline before "initrd" (required for TFTP parsing)
sed -i 's/initrd/\
        initrd/' "${GRUB_MENU_OUTPUT_FILE}"

# Use lock to update DHCP and TFTP configuration
LOCK_FILE="lockfile.lock"
(
flock 200 || exit 1
echo "Writing menuentry to grub.cfg"
sed -i -e "/menuentry 'RHEL CoreOS (Live)' --class fedora --class gnu-linux --class gnu --class os {/r $(printf '%s' "$GRUB_MENU_OUTPUT_FILE")" /var/lib/tftpboot/boot/grub2/grub.cfg
systemctl restart tftp

echo "Writing host entries to dhcpd.conf"
for (( i = 0; i < ${NODE_COUNT}; i++ )); do
    HOST_ENTRY="host ${SERVER_NAME[i]} { hardware ethernet ${MAC[i]}; fixed-address ${IP[i]}; }"
    sed -i "/# Static entries/a\    $(printf '%s' "$HOST_ENTRY")" /etc/dhcp/dhcpd.conf
done

echo "Restarting services tftp & dhcpd"
systemctl restart dhcpd
) 200>"$LOCK_FILE"
