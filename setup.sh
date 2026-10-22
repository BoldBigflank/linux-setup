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
# Shares on $NFS_SERVER, as "remote_path:local_mount_point"
NFS_SHARES=(
    "/Public:/nfs/public"
    "/Downloads:/nfs/downloads"
)
NFS_OPTIONS="_netdev,x-systemd.automount,x-systemd.mount-timeout=90,hard,intr,timeo=30,retrans=3,rw"

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
    echo "SETTING UP NFS MOUNTS (${NFS_SERVER})"
    sudo apt install -y -qq nfs-common

    if ! getent hosts "$NFS_SERVER" > /dev/null; then
        echo " - Warning: $NFS_SERVER doesn't resolve. Run the 'local DNS' step or add a DNS record first."
    fi

    # Build the exact fstab lines we want, plus a lookup of our mount points
    local -a wanted=()
    local -A ours=()
    local share remote mount
    for share in "${NFS_SHARES[@]}"; do
        remote="${share%%:*}"
        mount="${share#*:}"
        wanted+=("${NFS_SERVER}:${remote} ${mount} nfs ${NFS_OPTIONS} 0 0")
        ours["$mount"]="${NFS_SERVER}:${remote}"
    done

    # --- Remove old mounts -------------------------------------------------
    # An fstab NFS line is "old" if it points at the old subnet, or uses one of
    # our mount points with a different source. Lines that already match what we
    # want are left alone, so reruns are a no-op.
    local -a old_mountpoints=()
    local dev mp fstype
    while read -r dev mp fstype _; do
        [[ "$fstype" == nfs* ]] || continue
        if [[ "$dev" == ${OLD_SUBNET}.* ]] \
           || { [[ -n "${ours[$mp]:-}" ]] && [[ "$dev" != "${ours[$mp]}" ]]; }; then
            old_mountpoints+=("$mp")
        fi
    done < <(grep -vE '^[[:space:]]*(#|$)' /etc/fstab)

    if (( ${#old_mountpoints[@]} > 0 )); then
        sudo cp -a /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d-%H%M%S)"
        for mp in "${old_mountpoints[@]}"; do
            echo " - Removing old mount: $mp"
            # Stop the automount unit first, then lazily detach (works on a dead server)
            sudo systemctl stop "$(systemd-escape -p --suffix=automount "$mp")" 2>/dev/null || true
            sudo umount -l "$mp" 2>/dev/null || true
            awk -v mp="$mp" '$1 !~ /^#/ && $2 == mp && $3 ~ /^nfs/ { next } { print }' \
                /etc/fstab | sudo tee /etc/fstab.new > /dev/null
            sudo mv /etc/fstab.new /etc/fstab
        done
    fi

    # --- Add the new mounts ----------------------------------------------------
    local line
    for line in "${wanted[@]}"; do
        mp=$(awk '{print $2}' <<< "$line")
        sudo mkdir -p "$mp"
        if grep -qxF "$line" /etc/fstab; then
            echo " - $mp already up to date"
        else
            echo " - Adding $mp"
            echo "$line" | sudo tee -a /etc/fstab > /dev/null
        fi
    done

    echo " - Mounting NFS shares"
    sudo systemctl daemon-reload
    sudo mount -a || echo " - Warning: mount -a reported errors"

    for mount in "${!ours[@]}"; do
        # x-systemd.automount mounts on first access, so touch it
        ls "$mount" > /dev/null 2>&1 || true
        if mountpoint -q "$mount"; then
            echo " - Mounted $mount from ${ours[$mount]}"
        else
            echo " - Warning: $mount is not mounted"
        fi
    done
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
