#!/bin/bash

# https://wiki.gentoo.org/wiki/Custom_Initramfs

# needed to make parsing outputs more reliable
export LC_ALL=C
# we can never know what aliases may be set, so remove them all
unalias -a

# destination
CURRENT_DIR=$PWD
INITRAMFS=${CURRENT_DIR}/initramfs
INITRAMFS_ROOT=${INITRAMFS}/root

if [ "$1" = '--update' ]
then
    UPDATE_BOOT='yes'
else
    UPDATE_BOOT='no'
fi

echo '### Removing old stuff'

# remove old cruft
rm -rf ${INITRAMFS}/

mkdir -p ${INITRAMFS}
mkdir -p ${INITRAMFS_ROOT}

echo '### Creating initramfs root'

mkdir -p ${INITRAMFS_ROOT}/{bin,dev,etc,lib,lib64,newroot,proc,sbin,sys,usr} ${INITRAMFS_ROOT}/usr/{bin,sbin}
cp -a /dev/{null,console,tty} ${INITRAMFS_ROOT}/dev
cp -a /bin/busybox ${INITRAMFS_ROOT}/bin/busybox
cp $(ldd "/bin/busybox" | egrep -o '/.* ') ${INITRAMFS_ROOT}/lib/

cp -a /sbin/e2fsck ${INITRAMFS_ROOT}/sbin/e2fsck
cp $(ldd "/sbin/e2fsck" | egrep -o '/.* ') ${INITRAMFS_ROOT}/lib/

cp -a /bin/btrfs* ${INITRAMFS_ROOT}/bin
cp -a /sbin/*btrfs ${INITRAMFS_ROOT}/sbin
cp $(ldd "/bin/btrfs" | egrep -o '/.* ') ${INITRAMFS_ROOT}/lib/

cp -a /sbin/mdadm ${INITRAMFS_ROOT}/sbin
cp $(ldd "/sbin/mdadm" | egrep -o '/.* ') ${INITRAMFS_ROOT}/lib/

cp -a /usr/local/bin/mcu_ctl ${INITRAMFS_ROOT}/bin

cp -a /usr/sbin/ubiattach ${INITRAMFS_ROOT}/sbin

cat << EOF > ${INITRAMFS_ROOT}/init
#!/bin/busybox sh
/bin/busybox --install

rescue_shell() {
	printf '\e[1;31m' # bold red foreground
	printf "\$1 Dropping you to a shell."
	printf "\e[00m\n" # normal colour foreground
	#exec setsid cttyhack /bin/busybox sh
	exec /bin/busybox sh
}

ask_for_stop() {
        key='boot'
        read -r -p "### Press any key to stop and run shell... (2)" -n1 -t5 key
        if [ \$key != 'boot' ]; then
                rescue_shell
        fi
}


# initialise
mount -t devtmpfs none /dev || rescue_shell "mount /dev failed."
mount -t proc none /proc || rescue_shell "mount /proc failed."
mount -t sysfs none /sys || rescue_shell "mount /sys failed."

ubiattach /dev/ubi_ctrl -m 7 
mkdir -p /reserve2
mount /dev/ubi0_0 /reserve2
ip link set dev eth0 address $(cat /mnt/mac_addr)
umount /reserve2
ubidetach /dev/ubi_ctrl -m 7 

ask_for_stop
sleep 2

# Set fan speed to quarter
mcu_ctl fan_set_25

btrfs device scan
/sbin/mdadm --assemble --scan

# get cmdline parameters
init="/sbin/init"
root=\$1
rootflags=\$2
rootfstype=auto
ro="ro"

for param in \$(cat /proc/cmdline); do
	case \$param in
		init=*		) init=\${param#init=}			;;
		root=*		) root=\${param#root=}			;;
		rootfstype=*	) rootfstype=\${param#rootfstype=}	;;
		rootflags=*	) rootflags=\${param#rootflags=}	;;
		ro		) ro="ro"				;;
		rw		) ro="rw"				;;
	esac
done

# try to mount the root filesystem from kernel options
if [ "\${root}"x != "/dev/ram"x ]; then
	mount -t \${rootfstype} -o \${ro},\${rootflags} \${root} /newroot || rescue_shell "mount \${root} failed."
fi

try 2nd partition on usb
if [ ! -x /newroot/\${init} ] && [ ! -h /newroot/\${init} ] && [ -b /dev/sda1 ] && [ -b /dev/sda2 ]; then
	mount -t \${rootfstype} -o \${ro},\${rootflags} /dev/sda2 /newroot
	if [ ! -x /newroot/\${init} ] && [ ! -h /newroot/\${init} ]; then
		umount /dev/sda2
	fi
fi

# try 1st partition on hdd
if [ ! -x /newroot/\${init} ] && [ ! -h /newroot/\${init} ] && [ -b /dev/sda1 ]; then
	mount -t \${rootfstype} -o \${ro},\${rootflags} /dev/sda1 /newroot
	if [ ! -x /newroot/\${init} ] && [ ! -h /newroot/\${init} ]; then	
		umount /dev/sda1
	fi
fi

# WD My Cloud: get mac from memory and set
# ip link set dev eth0 address \$(dd if=/dev/ram bs=1 count=17 2>/dev/null)

# clean up.
umount /sys /proc /dev

# boot the real thing.
exec switch_root /newroot \${init} || rescue_shell

rescue_shell "end reached"
EOF
chmod +x ${INITRAMFS_ROOT}/init

echo '### Creating uRamdisk'

cd ${INITRAMFS_ROOT}
find . -print | cpio -ov --format=newc | gzip -9 > ${INITRAMFS}/custom-initramfs.cpio.gz
mkimage -A arm -O linux -T ramdisk -a 0x00e00000 -e 0x0 -n "Custom initramfs" -d ${INITRAMFS}/custom-initramfs.cpio.gz ${INITRAMFS}/uRamdisk

if [ "$UPDATE_BOOT" = 'yes' ] 
then 
    if [ -e '/boot/boot/' ]; then
        echo '### Updating /boot/boot'    
    
        if [ -e '/boot/boot/uRamdisk' ]; then
            mv /boot/boot/uRamdisk /boot/boot/uRamdisk.old
        fi
    
        mv ${INITRAMFS}/uRamdisk /boot/boot/uRamdisk        
    elif [ -e '/boot/' ]; then
        echo '### Updating /boot'
    
        if [ -e '/boot/uRamdisk' ]; then
            mv /boot/uRamdisk /boot/uRamdisk.old
        fi
    
        mv ${INITRAMFS}/uRamdisk /boot/uRamdisk    
    fi

    rm -rf ${INITRAMFS}
else
    echo '### Cleanup'
    rm -rf ${INITRAMFS}/custom-initramfs.cpio.gz
    rm -rf ${INITRAMFS_ROOT}
fi

echo '### Done.'

