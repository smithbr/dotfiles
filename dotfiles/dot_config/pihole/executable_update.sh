#!/bin/bash -e

# Run with: sudo /home/pi/.config/pihole/update.sh

# Update packages
apt-get update --fix-missing
apt-get full-upgrade -y
apt-get autoremove --purge -y
apt-get autoclean -y
apt-get clean

# Update Pi-hole
pihole -up

# Update PADD
/home/pi/.config/padd/padd.sh -u

# Reboot the system
# reboot
