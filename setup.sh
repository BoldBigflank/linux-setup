#!/bin/bash

# # Install packages
sudo apt update
# sudo NEEDRESTART_MODE=a apt upgrade -y
sudo apt install -y dialog
# # TODO: k3s, docker, etc
TMPFILE=$(mktemp)

dialog --checklist "Choose fixes:" 15 45 6 \
        1 "apt upgrade" on \
        2 "motd" on \
        3 "git branch in PROMPT" off \
        4 "ssh public key" on \
        5 "git username/email config" on \
        6 "cls alias" on 2> $TMPFILE

RESULT=$(cat $TMPFILE)

if [[ $RESULT =~ 1 ]]; then
    echo "APT UPGRADE"
    sudo NEEDRESTART_MODE=a apt upgrade -y
fi

if [[ $RESULT =~ 2 ]]; then
    echo "SETTING MESSAGE OF THE DAY"
    sudo apt install -y figlet

    # Create a motd with figlet
    sudo cat /sys/firmware/devicetree/base/model \
    | sed -E 's/Raspberry Pi /Rpi/g' \
    | sed -E 's/Model //g' \
    | figlet -f slant \
    | sudo tee /etc/motd

    # Don't need figlet for an extended time
    sudo apt remove figlet
fi

if [[ $RESULT =~ 3 ]]; then
    echo "TODO: ADDING GIT BRANCH IN PROMPT"
    # # Git branch in PROMPT
fi

if [[ $RESULT =~ 4 ]]; then
    echo "ADDING ALEX-PC TO AUTHORIZED KEYS"
    mkdir -p ~/.ssh
    touch ~/.ssh/authorized_keys
    PUBLIC_KEY=AAAAB3NzaC1yc2EAAAADAQABAAABAQDmj4g00bh3y2megexhBpJ4dNnaH14WlszHVOQL5HrodZ20+l7m3pwB++qoV63GTDSeNUkr4MYWW45x6JJgjI2yRCEPYMrSgZxpV/GsNmF60HTVICgxqpobDwpkEodfah66BhV7PYvNDVjo3wJSjzr1WmI20EZkyREGHgZYD97CtcbvI2JB5YgMlhynMNf0+Lip8Ygy8Hy6XZrPMBNQvwSOkjoYUzAiDT5a34m7eLf/GJdT+9iGEIYdg3rWjxdc9emjFb+b9wwK6tldOc2TwZF1RJTwhh/F5vzOEZK/zPPyL+BLXy0gNNLCOYCbR+Sub88M8pSx7zTIx8x3JcnydpXf
    if grep -q $PUBLIC_KEY ~/.ssh/authorized_keys; then
        echo " - Public key already in authorized_keys"
    else
        echo "ssh-rsa $PUBLIC_KEY alex@Alex-PC" >> ~/.ssh/authorized_keys
    fi
fi

if [[ $RESULT =~ 5 ]]; then
    echo "SETTING GIT USERNAME/EMAIL"
    # # Git username/email config
    git config --global user.name "Alex Swan"
    git config --global user.email "smashcubed@gmail.com"
fi

if [[ $RESULT =~ 6 ]]; then
    # Make cls clear the screen
    echo "SETTING CLS ALIAS"
    if grep -q "alias cls" ~/.bashrc; then
        echo " - Alias already exists"
    else
        (echo ""; echo "alias cls='printf \"\033c\"'") >> ~/.bashrc
        source ~/.bashrc
    fi
fi

rm $TMPFILE
echo "DONE"
