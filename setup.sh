#!/bin/bash
set -euo pipefail

# ----------------------------------------------------------------------------
# CONFIG — edit these for your own setup before running.
# Consider moving this block to a separate config.sh (and gitignoring it)
# if you ever share this repo, since it currently bakes in a personal
# SSH key, NFS server IP, and git identity.
# ----------------------------------------------------------------------------
GIT_USER_NAME="Alex Swan"
GIT_USER_EMAIL="smashcubed@gmail.com"
SSH_PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDmj4g00bh3y2megexhBpJ4dNnaH14WlszHVOQL5HrodZ20+l7m3pwB++qoV63GTDSeNUkr4MYWW45x6JJgjI2yRCEPYMrSgZxpV/GsNmF60HTVICgxqpobDwpkEodfah66BhV7PYvNDVjo3wJSjzr1WmI20EZkyREGHgZYD97CtcbvI2JB5YgMlhynMNf0+Lip8Ygy8Hy6XZrPMBNQvwSOkjoYUzAiDT5a34m7eLf/GJdT+9iGEIYdg3rWjxdc9emjFb+b9wwK6tldOc2TwZF1RJTwhh/F5vzOEZK/zPPyL+BLXy0gNNLCOYCbR+Sub88M8pSx7zTIx8x3JcnydpXf alex@Alex-PC"
NFS_SERVER="192.168.7.47"
NFS_PUBLIC_REMOTE="/Public"
NFS_PUBLIC_LOCAL="/nfs/public"
NFS_DOWNLOADS_REMOTE="/Downloads"
NFS_DOWNLOADS_LOCAL="/nfs/downloads"

export DEBIAN_FRONTEND=noninteractive

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# ----------------------------------------------------------------------------
# Base packages
# ----------------------------------------------------------------------------
sudo apt update
sudo apt install -y -qq dialog

# ----------------------------------------------------------------------------
# Checklist — tags are names now, not numbers, so nothing can collide
# (e.g. "1" matching inside "10") and it's easy to add new items.
# ----------------------------------------------------------------------------
dialog --checklist "Choose fixes:" 20 62 11 \
    upgrade      "apt upgrade"                  on \
    motd         "motd"                         on \
    gitprompt    "git branch in PROMPT"         off \
    sshkey       "ssh public key"               on \
    gitconfig    "git username/email"           on \
    cls          "cls alias"                    on \
    nfspublic    "NFS /Public → /nfs/public"    off \
    nfsdownloads "NFS /Downloads → /nfs/downloads" off \
    docker       "install docker"               off \
    k3s          "install k3s"                  off \
    unattended   "unattended-upgrades"          off \
    2> "$TMPFILE"

RESULT=$(cat "$TMPFILE")

has() {
    # word-boundary match against the space-separated dialog result
    [[ " $RESULT " == *" $1 "* ]]
}

# ----------------------------------------------------------------------------
# Task functions
# ----------------------------------------------------------------------------

do_upgrade() {
    echo "APT UPGRADE"
    sudo apt upgrade -y
}

do_motd() {
    echo "SETTING MESSAGE OF THE DAY"
    sudo apt install -y -qq figlet
    cat /sys/firmware/devicetree/base/model \
        | sed -E 's/Raspberry Pi /Rpi/g' \
        | sed -E 's/Model //g' \
        | figlet -f slant \
        | sudo tee /etc/motd > /dev/null
    sudo apt remove -y -qq figlet
}

do_gitprompt() {
    echo "ADDING GIT BRANCH TO PROMPT"
    local marker="# git branch in prompt (setup.sh)"
    if grep -qF "$marker" ~/.bashrc; then
        echo " - Already configured"
    else
        cat >> ~/.bashrc <<'EOF'

# git branch in prompt (setup.sh)
parse_git_branch() {
    git branch 2>/dev/null | sed -n '/\* /s///p' | sed 's/^/(/;s/$/)/'
}
export PS1="\u@\h:\w\[\033[32m\]\$(parse_git_branch)\[\033[00m\]\$ "
EOF
    fi
}

do_sshkey() {
    echo "ADDING PUBLIC KEY TO AUTHORIZED_KEYS"
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    if grep -qF "$SSH_PUBLIC_KEY" ~/.ssh/authorized_keys; then
        echo " - Public key already in authorized_keys"
    else
        echo "$SSH_PUBLIC_KEY" >> ~/.ssh/authorized_keys
    fi
}

do_gitconfig() {
    echo "SETTING GIT USERNAME/EMAIL"
    git config --global user.name "$GIT_USER_NAME"
    git config --global user.email "$GIT_USER_EMAIL"
}

do_cls() {
    echo "SETTING CLS ALIAS"
    if grep -q "alias cls" ~/.bashrc; then
        echo " - Alias already exists"
    else
        { echo ""; echo "alias cls='printf \"\033c\"'"; } >> ~/.bashrc
    fi
}

ensure_nfs_common() {
    if ! dpkg -s nfs-common &>/dev/null; then
        sudo apt install -y -qq nfs-common
    fi
}

mount_nfs() {
    local remote_path="$1"
    local local_mount="$2"

    echo "SETTING UP NFS MOUNT ${NFS_SERVER}:${remote_path} → ${local_mount}"
    ensure_nfs_common
    sudo mkdir -p "$local_mount"

    local nfs_entry="${NFS_SERVER}:${remote_path} ${local_mount} nfs _netdev,x-systemd.automount,x-systemd.mount-timeout=90,hard,intr,timeo=30,retrans=3,rw 0 0"

    if grep -q "${NFS_SERVER}:${remote_path}" /etc/fstab; then
        echo " - NFS entry already in /etc/fstab"
    else
        echo " - Adding NFS entry to /etc/fstab"
        echo "$nfs_entry" | sudo tee -a /etc/fstab > /dev/null
    fi

    echo " - Mounting NFS share"
    sudo mount -a

    if mountpoint -q "$local_mount"; then
        echo " - Successfully mounted $local_mount"
    else
        echo " - Warning: $local_mount is not mounted"
    fi
}

do_docker() {
    echo "INSTALLING DOCKER"
    if command -v docker &> /dev/null; then
        echo " - Docker already installed"
    else
        curl -fsSL https://get.docker.com | sh
        sudo usermod -aG docker "$USER"
        echo " - Added $USER to the docker group (log out/in for it to take effect)"
    fi
}

do_k3s() {
    echo "INSTALLING K3S"
    if command -v k3s &> /dev/null; then
        echo " - k3s already installed"
    else
        curl -sfL https://get.k3s.io | sh -
    fi
}

do_unattended() {
    echo "ENABLING UNATTENDED-UPGRADES"
    sudo apt install -y -qq unattended-upgrades
    sudo dpkg-reconfigure -f noninteractive unattended-upgrades
}

# ----------------------------------------------------------------------------
# Run whatever was selected
# ----------------------------------------------------------------------------
has upgrade    && do_upgrade
has motd       && do_motd
has gitprompt  && do_gitprompt
has sshkey     && do_sshkey
has gitconfig  && do_gitconfig
has cls        && do_cls
has nfspublic    && mount_nfs "$NFS_PUBLIC_REMOTE" "$NFS_PUBLIC_LOCAL"
has nfsdownloads && mount_nfs "$NFS_DOWNLOADS_REMOTE" "$NFS_DOWNLOADS_LOCAL"
has docker       && do_docker
has k3s          && do_k3s
has unattended   && do_unattended

echo "DONE"
