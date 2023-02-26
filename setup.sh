#!/bin/bash

# Install packages
sudo apt update
sudo apt upgrade -y
sudo apt install -y figlet
# TODO: k3s, docker, etc

# add Alex-PC public key
mkdir -p ~/.ssh
touch ~/.ssh/authorized_keys
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDmj4g00bh3y2megexhBpJ4dNnaH14WlszHVOQL5HrodZ20+l7m3pwB++qoV63GTDSeNUkr4MYWW45x6JJgjI2yRCEPYMrSgZxpV/GsNmF60HTVICgxqpobDwpkEodfah66BhV7PYvNDVjo3wJSjzr1WmI20EZkyREGHgZYD97CtcbvI2JB5YgMlhynMNf0+Lip8Ygy8Hy6XZrPMBNQvwSOkjoYUzAiDT5a34m7eLf/GJdT+9iGEIYdg3rWjxdc9emjFb+b9wwK6tldOc2TwZF1RJTwhh/F5vzOEZK/zPPyL+BLXy0gNNLCOYCbR+Sub88M8pSx7zTIx8x3JcnydpXf alex@Alex-PC" >> ~/.ssh/authorized_keys

# TODO: Set up preferred bash prompt


# Create a motd with figlet
sudo cat /sys/firmware/devicetree/base/model \
| sed -E 's/Raspberry Pi /Rpi/g' \
| sed -E 's/Model //g' \
| figlet -f slant \
| sudo tee /etc/motd

# Don't need figlet for an extended time
sudo apt uninstall figlet
