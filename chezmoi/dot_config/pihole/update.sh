#!/bin/bash -e

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
