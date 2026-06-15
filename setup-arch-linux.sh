echo "DisableSandbox" >> /etc/pacman.conf
pacman -Sy base-devel vim git --noconfirm

export U=summer
useradd -m $U
echo "$U ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

cd /tmp
git clone https://aur.archlinux.org/yay.git
chown -R $U yay
cd yay
sudo -u $U makepkg -si --noconfirm
sudo -u $U yay -S claude-code rustup --noconfirm
