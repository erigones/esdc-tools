#!/usr/bin/env bash

set -e

TMP_DIR=/opt/esdc_tmp
SMARTOS_GITSTATUS="platform/i86pc/amd64/boot_archive.gitstatus"

CURL="/usr/bin/curl"
CURL_DEFAULT_OPTS="-k --connect-timeout 10 -L --max-time 3600 -f"

. /usbkey/config

die() {
	local exit_code=$1
	shift
	local msg=$*
	local _err_unknown=99

	if [[ -n "${msg}" ]]; then
		echo "ERROR: ${msg}" 1>&2
	fi
	if [[ -z "${exit_code}" ]]; then 
		exit_code=${_err_unknown}
	fi

	exit "${exit_code}"
}

loginfo() {
	echo "** $1"
}

cleanup() {
	if [[ ${FINISHED_SUCCESSFULLY} -ne 1 ]]; then
		echo
		die 10 "INSTALL FAILED!"
		echo
	fi
	rm -rf "${TMP_DIR}"
}

# original from /lib/sdc/usb-key.sh
function usb_key_version()
{
	local readonly devpath=$1
	local readonly mbr_sig_offset=0x1fe
	local readonly mbr_grub_offset=0x3e
	local readonly mbr_stage1_offset=0xfa
	local readonly mbr_grub_version=0203
	local readonly mbr_sig=aa55

	sig=$(echo $(/usr/bin/od -t x2 \
	    -j $mbr_sig_offset -A n -N 2 $devpath) )

	if [[ "$sig" != $mbr_sig ]]; then
		echo "unknown"
		return
	fi

	grub_val=$(echo $(/usr/bin/od -t x2 \
	    -j $mbr_grub_offset -A n -N 2 $devpath) )
	loader_major=$(echo $(/usr/bin/od -t x1 \
	    -j $mbr_stage1_offset -A n -N 1 $devpath) )

	if [[ "$grub_val" = $mbr_grub_version ]]; then
		echo "1"
		return
	fi

	echo $(( 0x$loader_major ))
}

# original from /lib/sdc/usb-key.sh
function check_smartos_usb() 
{
	local mnt=$1
	local check_file="$mnt/$SMARTOS_GITSTATUS"

	if [[ -z "$mnt" ]]; then
		echo "Error: check_smartos_usb(): no mount path provided" >&2
		exit 5
	fi

	if [[ -f "$check_file" ]] && \
	cat "$check_file" | grep -q '"repo": "smartos-live"'; then
		return 0
	else
		return 1
	fi
}

function check_esdc_usb()
{
	local mnt=$1
	local check_file=
	
	if [[ -z "$mnt" ]]; then
		mnt=/mnt/$(svcprop -p "joyentfs/usb_mountpoint" \
		    "svc:/system/filesystem/smartdc:default")
	fi

	check_file="$mnt/version"

	if [[ -f "$check_file" ]] && \
	cat "$check_file" | grep -q '^esdc-'; then
		return 0
	else
		return 1
	fi
}

#
# Mount the usbkey at the standard mount location (or whatever is specified).
#
# original from /lib/sdc/usb-key.sh
function mount_smartos_usb_key()
{
	local mnt=$1

	if [[ -z "$mnt" ]]; then
		mnt=/mnt/$(svcprop -p "joyentfs/usb_mountpoint" \
		    "svc:/system/filesystem/smartdc:default")
	fi

	if check_smartos_usb "$mnt"; then
		devpath=$(awk -v "mnt=$mnt" '$2 == mnt { print $1 }' /etc/mnttab)
		if [ -n "$devpath" ]; then
			# we've found correct mounted usbkey and we also retrieved 
			# the device name
			echo "$devpath"
			return 0
		else
			# we've failed to retrieve the device name...
			# umount the usbkey and try again
			umount_usb_key
		fi
	fi

	if ! mkdir -p $mnt; then
		echo "failed to mkdir $mnt" >&2
		return 1
	fi

	alldisks=$(/usr/bin/disklist -a)

	for disk in $alldisks; do
		version=$(usb_key_version "/dev/dsk/${disk}p0")

		case $version in
		1) devpath="/dev/dsk/${disk}p1" ;;
		2) devpath="/dev/dsk/${disk}s2" ;;
		*) continue ;;
		esac

		fstyp="$(/usr/sbin/fstyp $devpath 2>/dev/null)"

		if [[ "$fstyp" != "pcfs" ]]; then
			continue
		fi

		/usr/sbin/mount -F pcfs -o foldcase,noatime $devpath $mnt \
		    2>/dev/null

		if [[ $? -ne 0 ]]; then
			continue
		fi

		if check_smartos_usb "$mnt"; then
			echo $devpath
			return 0
		fi

	done

	echo "Couldn't find USB key" >&2
	return 1
}

# original from /lib/sdc/usb-key.sh
function umount_usb_key()
{
	local mnt=$1

	if [[ -z "$mnt" ]]; then
		mnt=/mnt/$(svcprop -p "joyentfs/usb_mountpoint" \
		    "svc:/system/filesystem/smartdc:default")
	fi

	typ=$(awk -v "mnt=$mnt" '$2 == mnt { print $3 }' /etc/mnttab)

	if [[ -z $typ ]]; then
		return 0
	fi

	if ! check_smartos_usb "$mnt"; then
		echo "$mnt does not contain SmartOS USB key" >&2
		return 0
	fi

	umount "$mnt"
}

ip_to_num()
{
	IP=$1

	OLDIFS="$IFS"
	IFS="."
	set -- $IP
	num_a=$(($1 << 24))
	num_b=$(($2 << 16))
	num_c=$(($3 << 8))
	num_d=$4
	IFS="$OLDIFS"

	num=$((num_a + $num_b + $num_c + $num_d))
}

num_to_ip()
{
	NUM=$1

	fld_d=$(($NUM & 255))
	NUM=$(($NUM >> 8))
	fld_c=$(($NUM & 255))
	NUM=$(($NUM >> 8))
	fld_b=$(($NUM & 255))
	NUM=$(($NUM >> 8))
	fld_a=$NUM

	ip_addr="$fld_a.$fld_b.$fld_c.$fld_d"
}

#
# Converts an IP and netmask to their numeric representation.
# Sets the global variables IP_NUM, NET_NUM, NM_NUM and BCAST_ADDR to their
# respective numeric values.
#
ip_netmask_to_network()
{
	ip_to_num $1
	IP_NUM=$num

	ip_to_num $2
	NM_NUM=$num

	NET_NUM=$(($NM_NUM & $IP_NUM))

	ip_to_num "255.255.255.255"
	local bcasthost=$((~$NM_NUM & $num))
	BCAST_ADDR=$(($NET_NUM + $bcasthost))
}

# check if specified IP belongs to the subnet
ip_from_subnet()
{
	local myip="$1"
	local net="$2"
	local mask="$3"

	if [[ ${myip} == "none" ]]; then
		# consider no IP as from the subnet
		# (because it is a valid value)
		return 0
	fi
	ip_netmask_to_network "$net" "$mask"
	ip_to_num "$myip"

	if [[ "$num" -gt "$NET_NUM" && "$num" -lt "$BCAST_ADDR" ]]; then
		# $myip is from the subnet
		return 0
	else
		# not from subnet
		return 1
	fi
}

# check if specified IP belongs to the subnet
ip_from_subnet()
{
	local myip="$1"
	local net="$2"
	local mask="$3"

	if [[ ${myip} == "none" ]]; then
		# consider no IP as from the subnet
		# (because it is a valid value)
		return 0
	fi
	ip_netmask_to_network "$net" "$mask"
	ip_to_num "$myip"

	if [[ "$num" -gt "$NET_NUM" && "$num" -lt "$BCAST_ADDR" ]]; then
		# $myip is from the subnet
		return 0
	else
		# not from subnet
		return 1
	fi
}

is_priv_net() {
	local ip="$1"

	if [[ "${ip}" =~ ^10\.|^172\.[1-3]|^192\.168\. ]]; then
		return 0
	else
		return 1
	fi
}

check_cfgdb()
{
	local ec
	printf "Checking cfgdb availability..."
	curl -m 15 -k -s -I "https://${cfgdb_admin_ip}:12181" 2>/dev/null | grep -q "ESDC ZooKeeper REST"
	ec=$?

	if [[ "${ec}" -eq 0 ]]; then
		printf "OK\n"
	else
		printf "UNAVAILABLE\n"
	fi

	return "${ec}"
}

query_cfgdb()
{
	local ec
	local curl_ec
	local curl_out
	local json_ec
	local zk_ec
	printf "Accessing cfgdb..."

	curl_out=$(curl -m 15 -k -s -S -H "zk-username:esdc" -H "zk-password:${esdc_install_password}" "https://${cfgdb_admin_ip}:12181/esdc/settings/dc/datacenter_name" 2>&1)
	curl_ec=$?
	zk_ec="$(echo "${curl_out}" | json "returncode" 2> /dev/null)"
	json_ec=$?

	if [[ "${curl_ec}" -eq 0 ]] && [[ "${json_ec}" -eq 0 ]] && [[ "${zk_ec}" == "0" ]]; then
		datacenter_name="$(echo "${curl_out}" | json "stdout")"
		printf "OK\n"
		ec=0
	else
		printf "ERROR (${curl_out})\n"
		ec=1
	fi

	return "${ec}"
}

is_ip() {
	local ip="$1"

	if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
		return 0
	else
		return 1
	fi
}

# creates global variable $VAL
prompt_entry() {
	local def="${1}"

	read VAL
	if [ -z "$VAL" ]; then
		VAL="$def"
	fi
}

prompt_nonempty_entry() {
	while [ /usr/bin/true ]; do
		prompt_entry
		if [ -z "$VAL" ]; then
			echo "The value cannot be empty."
		else
			break
		fi
	done
}

prompt_yes_no()
{
	local msg="${1}"
	local def="${2:-yes}"


	printf "$msg"
	while [ /usr/bin/true ]; do
		prompt_entry "$def"

		VAL=$(echo "${VAL}" | tr '[:upper:]' '[:lower:]')

		case "${VAL}" in
			"y"|"yes"|"true"|"1")
				VAL=1
				if [ "${def}" == "yes" ]; then
					return 0
				else
					return 1
				fi
			;;
			"n"|"no"|"false"|"0")
				VAL=0
				if [ "${def}" == "no" ]; then
					return 0
				else
					return 1
				fi
			;;
			*)
				echo "The value must be 'yes' or 'no'."
				printf "Answer: "
			;;
		esac
	done
}

prompt_ip() {
	while [ /usr/bin/true ]; do
		printf "Addr: "
		prompt_nonempty_entry
		if is_ip "${VAL}"; then
			break
		else
			echo "Invalid IP address."
		fi
	done
}

prompt_pw() {
	local cfg_pass1
	local cfg_pass2

	while [ /usr/bin/true ]; do
		printf "Passwd: "
		stty -echo
		read cfg_pass1
		stty echo
		echo
		if [ ${#cfg_pass1} -lt 6 ]; then
			echo "Password is too short"
			continue
		fi

		printf "Repeat the passwd: "
		stty -echo
		read cfg_pass2
		stty echo
		echo
		if [ "${cfg_pass1}" != "${cfg_pass2}" ]; then
			echo "Passwords don't match!"
			continue
		else
			VAL="${cfg_pass1}"
			break
		fi
	done
}

print_dc_conf() {
	local nopw="$1"

if [ "${IMG_TYPE}" == "hn" ]; then
	cat << EOF
datacenter_name='${datacenter_name}'
admin_email='${admin_email}'
mgmt_admin_ip=${mgmt_admin_ip}
mon_admin_ip=${mon_admin_ip}
dns_admin_ip=${dns_admin_ip}
img_admin_ip=${img_admin_ip}
cfgdb_admin_ip=${cfgdb_admin_ip}
install_to_hdd=0
EOF
else
	cat << EOF
datacenter_name='${datacenter_name}'
cfgdb_admin_ip=${cfgdb_admin_ip}
install_to_hdd=0
remote_node=0
EOF
fi

if [ -n "${nopw}" ]; then
	# scramble password
	cat << EOF
esdc_install_password="<<hidden>>"
EOF
else
	cat << EOF
esdc_install_password="${esdc_install_password}"
EOF
fi
}

# **** START ****

if [ "$USER" != "root" ] || [ "$(zonename)" != "global" ]; then
	die 2 "This script must be run as a root in a global zone"
fi

message="
SmartOS to Danube Cloud conversion tool
=======================================

This script will convert your plain SmartOS installation to Danube Cloud compute node. 
You will be prompted whether this is the first compute node (management VMs will be deployed) or you already have existing Danube Cloud installation and you want to add this node to it.

These steps will be performed:

* check prerequisites
* search for the SmartOS USB key
* prompt for additional Danube Cloud config (passwords, mgmt IP addresses, etc)
* download latest Danube Cloud USB image
* create zones/iso dataset
* write additional config into /usbkey/config
* upgrade the USB image
* reboot
* deploy management VMs or connect to the existing management
* initialize Danube Cloud services and discover existing VMs

During the deployment, these directories will be created:
/opt/erigones
/opt/local
/opt/custom
/opt/zabbix

If the /opt/local exists, it will be moved away into /opt/backup/local.

Networking:
Admin network (the default SmartOS network) is used for internal Danube Cloud services and it must not be publicly accessible from the internet. If your admin network is publicly accessible from the internet, please move the admin NIC tag to safe space and use 'external' NIC tag for public network instead. 
Danube Cloud platform supports vlan tagging on the admin network (unlike SmartOS) so you can add to your /usbkey/config something like 'admin_vlan_id=4001' and it will be configured after reboot (existing VMs will not be touched).

Do you want to continue? (Y/n) "
if ! prompt_yes_no "$message" "yes"; then
	echo "Exiting..."
	exit 0
fi

# admin network must exist and it must not be 
if [[ -z "${admin_nic}" || -z "${admin_ip}" || -z "${admin_netmask}" ]] ; then
	die 2 "No usable admin network found in /usbkey/config"
elif ! is_priv_net "${admin_ip}"; then
	echo "Admin network has public IP! For security reasons Danube Cloud admin network must NOT be accessible from internet. It is strongly advised to reconfigure your networking."
	if prompt_yes_no "Continue? (y/N) " "no"; then
		echo "Exiting..."
		exit 0
	fi
fi

cat << EOF


Checking /usbkey/config networking:
Config variable 'admin_gateway' is not used by plain SmartOS. However it is used by Danube Cloud and should point to a real gateway.
Current configuration:
admin_gateway=${admin_gateway}
headnode_default_gateway=${headnode_default_gateway}

EOF
if [[ "${admin_gateway}" == "${admin_ip}" ]] && ip_from_subnet "${headnode_default_gateway}" "${admin_ip}" "${admin_netmask}"; then
	if ! prompt_yes_no "Should I set admin_gateway to the value of headnode_default_gateway? (Y/n) " "yes"; then
		echo "Exiting. Please change the network configuration manually and re-run this script."
		exit 0
	else 
		sed -i '' -re "s/^(admin_gateway=).*$/\1${headnode_default_gateway}/" /usbkey/config
		echo "/usbkey/config updated."
	fi

elif [[ "${admin_gateway}" == "${admin_ip}" ]]; then
	echo "I don't know how to set admin_gateway. Please set it manually as it will be used as default gw by all Danube Cloud's management VMs."
	exit 3
else
	echo "* Note: IP address '${admin_gateway}' (admin_gateway) will be set as default gw for all Danube Cloud's management VMs. If this is not desirable, please hit Ctrl+C and change the admin_gateway variable."
fi

echo
loginfo "Searching for USB key"
USB_DEV="$(mount_smartos_usb_key)"
RC="$?"
umount_usb_key

if [ "$RC" -ne 0 ]; then
	die 2 "Error during search for USB key (found device: $USB_DEV)"
fi


# remove reference to mounted partition so we target the whole disk
if [[ "${USB_DEV}" =~ s2$ ]]; then
	# change trailing s2 for p0 (c1t1d0s2 -> c1t1d0p0)
	# (GPT partition table)
	USB_DEV_P0="${USB_DEV/s2*}p0"
elif [[ "${USB_DEV}" =~ p1$ ]]; then
	# change trailing p1 for p0 (c1t1d0p1 -> c1t1d0p0)
	USB_DEV_P0="${USB_DEV/p1*}p0"
elif [[ "${USB_DEV}" =~ p0:1$ ]]; then
	# remove trailing :1 (c1t0d0p0:1 -> c1t0d0p0)
	USB_DEV_P0="${USB_DEV/:1*}"
else
	die 9 "Unrecognized partition specification: ${USB_DEV}"
fi


USB_DEV_SHORT="${USB_DEV_P0%%p0}"
USB_DEV_SHORT="${USB_DEV_SHORT##/dev/dsk/}"
message="
*** Available disks ***
$(diskinfo)

Discovered USB key device: $USB_DEV_SHORT

Does it look reasonable? (Y/n) "
if ! prompt_yes_no "$message" "yes"; then
	echo "Exiting..."
	exit 0
fi

message="
Is this the first Danube Cloud compute node (deploy management VMs)? (Y/n) "
if prompt_yes_no "$message" "yes"; then
	IMG_TYPE=hn
else
	IMG_TYPE=cn
fi

ESDC_IMG="esdc-ce-${IMG_TYPE}-latest.img"
ESDC_DOWNLOAD_URL="https://download.danube.cloud/esdc/usb/stable/${ESDC_IMG}.gz"
ESDC_NOTES_URL="https://download.danube.cloud/esdc/usb/stable/${ESDC_IMG%%img}notes"
ESDC_IMG_FULL="${TMP_DIR}/${ESDC_IMG}"

echo
loginfo "Test connection for image download"
if ! ${CURL} -sk --connect-timeout 10 "${ESDC_NOTES_URL}" | grep -q 'Platform password'; then
	die 5 "Cannot download release notes (${ESDC_NOTES_URL})."
fi


if [ -d /opt/local ]; then
	OPTLOCAL_EXISTS="true"
fi



if [ "${IMG_TYPE}" == "hn" ]; then
	echo
	printf "Please enter datacenter name: "
	prompt_nonempty_entry
	datacenter_name="${VAL}"

	echo
	printf "Please enter admin e-mail address: "
	prompt_nonempty_entry
	admin_email="${VAL}"

	echo
	echo "Please enter the first IP address of management VM. Four next consecutive IP addresses will be used for management VMs."
	while [ /usr/bin/true ]; do
		prompt_ip
		if ip_from_subnet "${VAL}" "${admin_ip}" "${admin_netmask}"; then
			mgmt_admin_ip="${VAL}"
			break
		else
			echo "Entered IP is not from the admin subnet (${admin_ip}/${admin_netmask})."
		fi
	done


	echo
	echo "Please enter configuration master password (the one that is used to add new compute nodes)"
	prompt_pw
	esdc_install_password="${VAL}"

	# Calculate admin network address for every core VM.
	ip_netmask_to_network "$mgmt_admin_ip" "$admin_netmask"

	next_addr=$(($IP_NUM + 1))
	num_to_ip "$next_addr"
	mon_admin_ip="$ip_addr"

	next_addr=$(($next_addr + 1))
	num_to_ip "$next_addr"
	dns_admin_ip="$ip_addr"

	next_addr=$(($next_addr + 1))
	num_to_ip "$next_addr"
	img_admin_ip="$ip_addr"

	next_addr=$(($next_addr + 1))
	num_to_ip "$next_addr"
	cfgdb_admin_ip="$ip_addr"


else
	echo
	echo "Please enter configuration master password (the one that is used to add new compute nodes). "
	prompt_pw
	esdc_install_password="${VAL}"

	echo
	echo "Please enter IP address of cfgdb01 of the existing Danube Cloud installation."
	while [ /usr/bin/true ]; do
		prompt_ip
		cfgdb_admin_ip="${VAL}"
		echo
		if check_cfgdb; then
			break
		else
			echo "Please enter the correct IP address of cfgdb01.local."
		fi
	done

	echo
	# retrieve datacenter_name
	if ! query_cfgdb; then
		die 3 "Failed to query the cfgdb. Invalid password?"
	fi
fi

if [ "${IMG_TYPE}" == "hn" ]; then
	nextlog="/var/log/headnode-install.log"
else
	nextlog="/var/log/computenode-install.log"
fi

message="

Final summary
=============

This configuration will be appended to /usbkey/config:

$(print_dc_conf nopw)

Steps to go
===========

* download Danube Cloud image from ${ESDC_DOWNLOAD_URL}
* create zones/iso dataset
* append config to /usbkey/config
* write image ${ESDC_IMG} to $USB_DEV_P0
* reboot
* initialize Danube Cloud

After reboot, watch the server console or ${nextlog}

Continue? (Y/n) "
if ! prompt_yes_no "$message" "yes"; then
	echo "Exiting..."
	exit 0
fi

trap cleanup EXIT

mkdir -p "${TMP_DIR}"

echo
loginfo "Downloading Danube Cloud image"
if ! ${CURL} ${CURL_DEFAULT_OPTS} -o "${ESDC_IMG_FULL}.gz" "${ESDC_DOWNLOAD_URL}"; then
	die 5 "Cannot download new USB image archive. Please check your internet connection."
fi

echo
loginfo "Extracting the image"
if ! gunzip -c "${ESDC_IMG_FULL}.gz" > "${ESDC_IMG_FULL}"; then
	die 5 "Error durin extracting the image"
fi
rm -f "${ESDC_IMG_FULL}.gz"

if [ "$OPTLOCAL_EXISTS" == "true" ]; then
	loginfo "Moving /opt/local"
	mkdir /opt/backup
	mv /opt/local "/opt/backup/local.$(date +%Y%m%d-%H%M)"
fi

if ! zfs list zones/iso &> /dev/null; then
	loginfo "Creating zones/iso dataset"
	zfs create -o mountpoint=/iso zones/iso
	zfs set atime=on zones/iso
fi

BACKUPDS=zones/backups
if ! zfs list ${BACKUPDS} &> /dev/null; then
	set +e
	loginfo "Creating ${BACKUPDS} dataset"
	zfs create ${BACKUPDS}
	zfs create -o compression=lz4 ${BACKUPDS}/file
	zfs create -o compression=lz4 ${BACKUPDS}/ds
	zfs create -o compression=lz4 ${BACKUPDS}/manifests
	set -e
fi


loginfo "Write /usbkey/config vars"
echo >> /usbkey/config
echo '# Danube Cloud settings' >> /usbkey/config
print_dc_conf >> /usbkey/config

loginfo "Writing new image to the USB device: ${USB_DEV_P0}"
if ! /usr/bin/dd if="${ESDC_IMG_FULL}" of="${USB_DEV_P0}" bs=16M; then
	die 2 "Failed to write USB key. Please write the USB key manually and reboot."
fi

loginfo "Verifying newly written USB"
if ! mount_smartos_usb_key > /dev/null || ! check_esdc_usb; then
	die 2 "Failed to mount USB key. Please write the USB key manually and reboot."
fi

umount_usb_key

FINISHED_SUCCESSFULLY=1

loginfo "USB image has been written successfully."
loginfo "Rebooting..."

init 6
