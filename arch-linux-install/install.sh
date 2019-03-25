#!/bin/bash


set -x
set -e

## Connect to wifi :
#
#ip link set wlp2s0 up
#iw dev wlp2s0 scan | grep "SSID"
#iw dev wlp2s0 connect S2
#sleep 5
#iw dev wlp2s0 link
#dhclient wlp2s0

ping -c1 archlinux.org

# disable beep during install
if lsmod | grep pcspkr; then
	rmmod pcspkr
fi

if test -e /dev/mapper/cryptlvm; then 
	cryptsetup close cryptlvm
fi
	

# Partitionning :

parted /dev/nvme0n1 print
parted -s /dev/nvme0n1 mklabel gpt
parted -s /dev/nvme0n1 mkpart primary fat32 1MiB 551MiB
parted -s /dev/nvme0n1 set 1 esp on
parted -s /dev/nvme0n1 mkpart primary 551MiB 100%
parted -s /dev/nvme0n1 set 2 lvm on


parted /dev/nvme0n1 print

# Crypt :

cryptsetup luksFormat --type luks2 /dev/nvme0n1p2
cryptsetup open /dev/nvme0n1p2 cryptlvm
sleep 5


# LVM :
pvcreate /dev/mapper/cryptlvm
pvs

vgcreate arch /dev/mapper/cryptlvm
vgs

lvcreate -L 8G arch -n swap
lvcreate -L 40G arch -n root
lvcreate -l 100%FREE arch -n home
lvs

# Formating

mkfs.ext4 /dev/arch/root
mkfs.ext4 /dev/arch/home
mkfs.fat -F32 /dev/nvme0n1p1
mkswap /dev/arch/swap

# Mount

swapon /dev/arch/swap
mount /dev/arch/root /mnt
mkdir -p /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot
mkdir -p /mnt/home
mount /dev/arch/home /mnt/home

mount | grep /mnt

timedatectl set-ntp true
loadkeys fr-latin9

# Install
pacstrap /mnt base
genfstab -U /mnt >> /mnt/etc/fstab

# time
ln -sf /usr/share/zoneinfo/Europe/Paris /mnt/etc/localtime
arch-chroot /mnt hwclock --systohc

# locales
sed -i '/\(en_US.UTF-8\|fr_FR.UTF-8\)/s/^#[[:space:]]*//' /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo 'LANG=en_US.UTF-8' >  /mnt/etc/locale.conf

# network
echo 'archie' > /mnt/etc/hostname
cat > /mnt/etc/hosts << EOF
127.0.0.1       localhost
::1             localhost
127.0.1.1       archie.localdomain archie
EOF



# Install grub
arch-chroot /mnt pacman -Syu --noconfirm  grub lvm2 cryptsetup efibootmgr
mkdir -p /mnt/boot/EFI

echo 'KEYMAP=fr' > /mnt/etc/vconsole.conf

# 
uuid="$(blkid | sed -n '/nvme0n1p2/s/.*\<UUID="\([^"]*\)".*/\1/p')"
echo "cryptlvm    UUID=$uuid    none luks,timeout=180"  > /mnt/etc/crypttab.initramfs

# Initial ramfs
sed -i 's/\(^[[:space:]]*HOOKS=\).*/\1(base systemd autodetect keyboard sd-vconsole  modconf block sd-encrypt sd-lvm2 filesystems fsck)/' /mnt/etc/mkinitcpio.conf
arch-chroot /mnt << EOF
export HOOKS=(base systemd autodetect keyboard sd-vconsole  modconf block sd-encrypt sd-lvm2 filesystems fsck)
mkinitcpio -p linux
EOF

modprobe dm-mod
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="Arch Linux GRUB" --recheck

# workaround for issue with udev/lvm and grub-mkconfig
mkdir -p /mnt/hostlvm
mount --bind /run/lvm /mnt/hostlvm
arch-chroot /mnt << EOF
ln -s /hostlvm /run/lvm
grub-mkconfig -o /boot/grub/grub.cfg
EOF


# disable beep
echo 'blacklist pcspkr' > /mnt/etc/modprobe.d/nobeep.conf

# define pacman repo
if ! grep -q 'archlinuxfr' /mnt/etc/pacman.conf; then
	cat >> /mnt/etc/pacman.conf << 'EOF'
[archlinuxfr]
SigLevel = Optional TrustAll
Server = http://repo.archlinux.fr/$arch
EOF
fi

arch-chroot /mnt pacman -Syu --noconfirm i3 dmenu network-manager-applet gnome-keyring \
	termite firefox vim git zip unzip \
        lightdm  lightdm-webkit-theme-litarvan\
	alsa-utils syslog-ng networkmanager bash-completion zsh base-devel \
       	xorg-server xorg-xinit xorg-xmessage  xf86-input-mouse

arch-chroot /mnt systemctl enable NetworkManager.service


## configure xorg
#Cat > /mnt/etc/skel/.xinitrc << EOF
#exec i3 -V >> ~/.i3/i3.log 2>&1
#EOF
mkdir -p /mnt/etc/skel/.i3


# gdm
#pacman -Syu archlinux-themes-slim slim 
## select slim theme
#sed -i 's/\(^[[:space:]]*current_theme[[:space:]]*\).*/\1archlinux-darch-grey/' /etc/slim.conf 
#systemctl enable slim
sed -i 's/^.*\(greeter-session=\).*/\1lightdm-webkit2-greeter/' /mnt/etc/lightdm/lightdm.conf
sed -i 's/\(^[[:space:]]*webkit_theme[[:space:]]*=[[:space:]]*\).*/\1litarvan/' /mnt/etc/lightdm/lightdm-webkit2-greeter.conf
arch-chroot /mnt systemctl enable lightdm

# Configure sudo for wheel group
sed -i '/%wheel ALL=(ALL) ALL/s/^[[:space:]]*#[[:space:]]*//' /mnt/etc/sudoers


# User creation
arch-chroot /mnt useradd -m seb -s /bin/zsh
arch-chroot /mnt passwd seb
#arch-chroot /mnt groupadd wheel
arch-chroot /mnt usermod -a -G wheel seb

# clean workaround for lvm
umount /mnt/hostlvm
rmdir  /mnt/hostlvm
