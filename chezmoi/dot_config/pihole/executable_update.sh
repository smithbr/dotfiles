#!/bin/bash -e

# Add the following line to your sudoers file using visudo:
#
# sudo visudo -f /etc/sudoers.d/update-script
# yourusername ALL=(ALL) NOPASSWD: /home/yourusername/update.sh

# Update Pi-hole
pihole -up

# Update PADD
~/padd.sh -u

# Update packages
apt-get update --fix-missing
apt-get full-upgrade -y
apt-get autoremove --purge -y
apt-get autoclean -y
apt-get clean

# Reboot the system
# reboot
