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
# Old subnet: the NFS step removes any NFS mounts still pointing at it
OLD_SUBNET="192.168.7"

# Local DNS. Use names instead of IPs everywhere (fstab, ssh config, etc.) so
# the next network change only means updating DNS records, not every device.
# Use ".lan" or "home.arpa" for the domain, NOT ".local" (collides with mDNS).
LOCAL_DOMAIN="lan"
LOCAL_DNS_SERVER="192.168.0.1"   # your DNS box (router/Pi-hole/etc.) -- update me

NFS_SERVER="comeau.${LOCAL_DOMAIN}"   # hostname, resolved by local DNS
NFS_REMOTE_PATH="/Public"
NFS_LOCAL_MOUNT="/nfs/public"

export DEBIAN_FRONTEND=noninteractive

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# ----------------------------------------------------------------------------
# Base packages
# ----------------------------------------------------------------------------
# Only touch the network here if dialog is missing, so the script can still run
# on a device that has lost its network.
if ! command -v dialog &> /dev/null; then
    sudo apt update
    sudo apt install -y -qq dialog
fi

# ----------------------------------------------------------------------------
# Checklist — tags are names now, not numbers, so nothing can collide
# (e.g. "1" matching inside "10") and it's easy to add new items.
# ----------------------------------------------------------------------------
dialog --checklist "Choose fixes:" 22 72 12 \
    dns       "local DNS (${LOCAL_DNS_SERVER}, .${LOCAL_DOMAIN})"     off \
    upgrade   "apt upgrade"              on \
    motd      "motd"                     on \
    gitprompt "git branch in PROMPT"     off \
    sshkey    "ssh public key"           on \
    gitconfig "git username/email"       on \
    cls       "cls alias"                on \
    nfs       "NFS mount (${NFS_SERVER}); removes old ${OLD_SUBNET}.x mounts" off \
    docker    "install docker"           off \
    k3s       "install k3s"              off \
    unattended "unattended-upgrades"     off \
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

APT_UPDATED=0
apt_update_once() {
    if (( APT_UPDATED == 0 )); then
        sudo apt update
        APT_UPDATED=1
    fi
}

do_fixnet() {
    echo "MIGRATING ${OLD_SUBNET}.x -> ${NEW_SUBNET}.x REFERENCES"
    local old_re="${OLD_SUBNET//./\\.}\\."
    local stamp changed=0 netplan_changed=0 f
    stamp=$(date +%Y%m%d-%H%M%S)

    # Places that commonly hard-code an IP: mounts, host overrides,
    # static IP configs (netplan on Ubuntu, dhcpcd on Raspberry Pi OS), ssh shortcuts
    for f in /etc/fstab /etc/hosts /etc/netplan/*.yaml /etc/dhcpcd.conf "$HOME/.ssh/config"; do
        [[ -f "$f" ]] || continue
        if sudo grep -qE "\\b${old_re}" "$f"; then
            echo " - Updating $f (backup: $f.bak-$stamp)"
            sudo cp -a "$f" "$f.bak-$stamp"
            sudo sed -i -E "s/\\b${old_re}/${NEW_SUBNET}./g" "$f"
            sudo diff "$f.bak-$stamp" "$f" | sed 's/^/     /' || true
            changed=1
            [[ "$f" == /etc/netplan/* ]] && netplan_changed=1
        fi
    done

    if (( changed == 0 )); then
        echo " - Nothing references ${OLD_SUBNET}.x (DHCP, or already migrated)"
    fi
    if (( netplan_changed == 1 )); then
        echo " - netplan config changed: run 'sudo netplan apply' (or reboot) to pick up the new address"
    fi
}

do_dns() {
    echo "CONFIGURING LOCAL DNS (${LOCAL_DNS_SERVER}, search domain ${LOCAL_DOMAIN})"
    sudo mkdir -p /etc/systemd/resolved.conf.d
    sudo tee /etc/systemd/resolved.conf.d/local-dns.conf > /dev/null <<EOF
[Resolve]
DNS=${LOCAL_DNS_SERVER}
Domains=${LOCAL_DOMAIN}
EOF
    sudo systemctl restart systemd-resolved

    if getent hosts "$NFS_SERVER" > /dev/null; then
        echo " - $NFS_SERVER resolves to $(getent hosts "$NFS_SERVER" | awk '{print $1}')"
    else
        echo " - Warning: $NFS_SERVER does not resolve yet (is the record created on the DNS server?)"
    fi
}

do_nfs() {
    echo "SETTING UP NFS MOUNT (${NFS_SERVER})"
    sudo apt install -y -qq nfs-common
    sudo mkdir -p "$NFS_LOCAL_MOUNT"

    local nfs_entry="${NFS_SERVER}:${NFS_REMOTE_PATH} ${NFS_LOCAL_MOUNT} nfs _netdev,x-systemd.automount,x-systemd.mount-timeout=90,hard,intr,timeo=30,retrans=3,rw 0 0"

    if ! getent hosts "$NFS_SERVER" > /dev/null; then
        echo " - Warning: $NFS_SERVER doesn't resolve. Run the 'local DNS' step or add a DNS record first."
    fi

    # Match on the mount point (not the server) so an old entry that points at
    # a previous IP is replaced instead of duplicated.
    if awk -v mp="$NFS_LOCAL_MOUNT" '$2 == mp { found = 1 } END { exit !found }' /etc/fstab; then
        if grep -qxF "$nfs_entry" /etc/fstab; then
            echo " - NFS entry already up to date"
        else
            echo " - Replacing stale NFS entry for $NFS_LOCAL_MOUNT"
            sudo cp -a /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d-%H%M%S)"
            sudo sed -i "\\|[[:space:]]${NFS_LOCAL_MOUNT}[[:space:]]|d" /etc/fstab
            echo "$nfs_entry" | sudo tee -a /etc/fstab > /dev/null
        fi
    else
        echo " - Adding NFS entry to /etc/fstab"
        echo "$nfs_entry" | sudo tee -a /etc/fstab > /dev/null
    fi

    echo " - Mounting NFS share"
    # Detach any mount still bound to the old address, then let systemd re-read fstab
    sudo umount -l "$NFS_LOCAL_MOUNT" 2>/dev/null || true
    sudo systemctl daemon-reload
    sudo mount -a || echo " - Warning: mount -a reported errors"
    # x-systemd.automount mounts on first access, so touch it
    ls "$NFS_LOCAL_MOUNT" > /dev/null 2>&1 || true

    if mountpoint -q "$NFS_LOCAL_MOUNT"; then
        echo " - Successfully mounted $NFS_LOCAL_MOUNT"
    else
        echo " - Warning: $NFS_LOCAL_MOUNT is not mounted"
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
has dns         && do_dns

# Refresh apt lists once, after any network repair above
if has upgrade || has motd || has nfs || has unattended; then
    apt_update_once
fi

has upgrade    && do_upgrade
has motd       && do_motd
has gitprompt  && do_gitprompt
has sshkey     && do_sshkey
has gitconfig  && do_gitconfig
has cls        && do_cls
has nfs        && do_nfs
has docker     && do_docker
has k3s        && do_k3s
has unattended && do_unattended

echo "DONE"
