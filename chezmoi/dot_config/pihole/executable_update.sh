#!/bin/bash -e

# Add the following line to your sudoers file using visudo:
#
# sudo visudo -f /etc/sudoers.d/update-script
# yourusername ALL=(ALL) NOPASSWD: /home/yourusername/update.sh

# Update packages
apt-get update --fix-missing
apt-get full-upgrade -y
apt-get autoremove --purge -y
apt-get autoclean -y
apt-get clean

# Update Unbound
apt upgrade unbound

# Update Pi-hole
pihole -up

# Update PADD
~/padd.sh -u

# Reboot the system
# reboot
