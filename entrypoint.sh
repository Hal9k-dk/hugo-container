#!/bin/bash
set -Eeuo pipefail
umask 022

: "${REPO_URL:?Set REPO_URL to the Hugo site Git repository URL}"
: "${BRANCH:=main}"
: "${HUGO_ENVIRONMENT:=production}"

if [[ -n "${DEPLOY_AUTHORIZED_KEYS:-}" ]]; then
    printf '%s\n' "$DEPLOY_AUTHORIZED_KEYS" > /etc/ssh/authorized_keys/deploy
    chmod 644 /etc/ssh/authorized_keys/deploy
elif [[ -s /run/secrets/deploy_authorized_keys ]]; then
    install -m 644 /run/secrets/deploy_authorized_keys /etc/ssh/authorized_keys/deploy
else
    echo 'Set DEPLOY_AUTHORIZED_KEYS to the CI public key(s), one per line' >&2
    exit 1
fi

install -d -m 700 /data/ssh
if [[ ! -s /data/ssh/ssh_host_ed25519_key ]]; then
    ssh-keygen -q -t ed25519 -N '' -f /data/ssh/ssh_host_ed25519_key
fi
install -d -m 755 -o deploy -g deploy /data/site /data/site/releases
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
if [[ -f /run/secrets/repo_key ]]; then
    if [[ ! -s /run/secrets/repo_known_hosts ]]; then
        echo 'A repository SSH key requires /run/secrets/repo_known_hosts' >&2
        exit 1
    fi
    install -m 600 -o deploy -g deploy /run/secrets/repo_key /home/deploy/.ssh/id_ed25519
fi
if [[ -f /run/secrets/repo_known_hosts ]]; then
    install -m 600 -o deploy -g deploy /run/secrets/repo_known_hosts /home/deploy/.ssh/known_hosts
fi

# sshd does not forward the container environment into forced commands.
# Write a shell-escaped, root-owned snapshot without exposing private keys.
{
    printf 'export REPO_URL=%q\n' "$REPO_URL"
    printf 'export BRANCH=%q\n' "$BRANCH"
    printf 'export HUGO_ENVIRONMENT=%q\n' "$HUGO_ENVIRONMENT"
    printf 'export HUGO_BASEURL=%q\n' "${HUGO_BASEURL:-}"
} > /run/deploy-env
chmod 644 /run/deploy-env

/usr/sbin/sshd -t
nginx -t
su-exec deploy:deploy env HOME=/home/deploy /usr/local/bin/deploy-site

nginx -g 'daemon off;' &
nginx_pid=$!
/usr/sbin/sshd -D -e &
sshd_pid=$!
cleanup() {
    trap - EXIT INT TERM
    kill -TERM "$nginx_pid" "$sshd_pid" 2>/dev/null || true
    wait "$nginx_pid" "$sshd_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
# Stop the container if either of its services exits.
set +e
wait -n "$nginx_pid" "$sshd_pid"
status=$?
set -e
(( status != 0 )) || status=1
exit "$status"
