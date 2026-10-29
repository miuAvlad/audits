#!/usr/bin/env bash
# Render disposable configurations and generate a random laboratory PSK.
# Usage: ./render_lab.sh RESPONDER_IP INITIATOR_IP [output-directory]

set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

if [[ $# -lt 2 || $# -gt 3 ]]; then
	echo "usage: $0 RESPONDER_IP INITIATOR_IP [output-directory]" >&2
	exit 2
fi

responder_ip=$1
initiator_ip=$2
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
output=${3:-${script_dir}/generated}

if [[ -e ${output} ]]; then
	echo "refusing to overwrite ${output}; remove it explicitly first" >&2
	exit 2
fi

for command in openssl sed install; do
	if ! command -v "${command}" >/dev/null 2>&1; then
		echo "missing host command: ${command}" >&2
		exit 2
	fi
done

install -d -m 700 "${output}"
psk=$(openssl rand -hex 32)

sed \
	-e "s|@@RESPONDER_IP@@|${responder_ip}|g" \
	-e "s|@@INITIATOR_IP@@|${initiator_ip}|g" \
	"${script_dir}/server.conf.in" > "${output}/server.conf"
sed \
	-e "s|@@RESPONDER_IP@@|${responder_ip}|g" \
	-e "s|@@INITIATOR_IP@@|${initiator_ip}|g" \
	"${script_dir}/client.conf.in" > "${output}/client.conf"
printf '@fragment-poc-initiator @fragment-poc-responder : PSK "%s"\n' \
	"${psk}" > "${output}/ipsec.secrets"

chmod 600 "${output}/server.conf" "${output}/client.conf" \
	"${output}/ipsec.secrets"
echo "Generated disposable lab files under ${output}"
