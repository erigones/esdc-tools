# esdc-tools
Tools for Danube Cloud

Convert SmartOS to Danube Cloud
===============================
convert-smartos-to-danube-cloud.sh
------

It is possible to easily convert standalone SmartOS installation to Danube Cloud, with all existing virtual machines. You can choose to either deploy the Danube Cloud management VMs or you can join the standalone SmartOS system to existing Danube Cloud installation.

Just download the conversion script and follow the instructions:
```
smartos# wget https://github.com/erigones/esdc-tools/raw/main/convert-smartos-to-danube-cloud.sh
smartos# chmod +x convert-smartos-to-danube-cloud.sh
smartos# ./convert-smartos-to-danube-cloud.sh
```

Requirements
------------
* 6GB USB key size for first compute node or 2GB for next compute node (non-management)
* 100GB+ of HDD size
* Intel CPU (because of KVM)
* Private admin network (see instructions after running the conversion script)

Rollback
--------
In case you want do return back to plain SmartOS, just rewrite (or replace) the USB key with SmartOS image and reboot.

Cleanup
-------
To do complete cleanup after rollback, you can 
* remove Danube Cloud entries in the bottom from `/usbkey/config`
* `zfs destroy zones/iso`
* `zfs destroy zones/backup`
* remove directories `/opt/erigones`, `/opt/zabbix`, `/opt/local` (you might want to keep this), `/opt/custom` (in case you don't have your own SMF customizations in `/opt/custom/smf`)

None of these bits affect the plain SmartOS functionality so their removal is optional.
