#!/usr/bin/env bash
# Replace the active Libreswan configuration on a disposable responder VM.

set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [[ ${EUID} -ne 0 || $# -ne 2 ]]; then
	echo "usage: sudo $0 RESPONDER_IP INITIATOR_IP" >&2
	exit 2
fi

responder_ip=$1
initiator_ip=$2
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
template=${script_dir}/responder.conf.in
backup=/etc/ipsec.conf.ike-tcp-uaf-backup
temporary=$(mktemp)
trap 'rm -f -- "${temporary}"' EXIT

for command in ipsec install sed systemctl; do
	if ! command -v "${command}" >/dev/null 2>&1; then
		echo "missing responder command: ${command}" >&2
		exit 2
	fi
done

if [[ ! -r ${template} ]]; then
	echo "missing configuration template: ${template}" >&2
	exit 2
fi

sed \
	-e "s|@@RESPONDER_IP@@|${responder_ip}|g" \
	-e "s|@@INITIATOR_IP@@|${initiator_ip}|g" \
	"${template}" > "${temporary}"

ipsec addconn --checkconfig --config "${temporary}"
if [[ ! -e ${backup} ]]; then
	cp -a /etc/ipsec.conf "${backup}"
fi
install -m 600 "${temporary}" /etc/ipsec.conf
systemctl restart ipsec

echo "Responder configured on ${responder_ip}; TCP/4500 must be reachable."
echo "Log: /tmp/pluto-ike-tcp-uaf.log"
