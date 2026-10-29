#!/usr/bin/env bash
# Prepare VM2 (IKE initiator + authoritative DNS) for the UAF_2 lab.

set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [[ ${EUID} -ne 0 || $# -lt 2 || $# -gt 3 ]]; then
	echo "usage: sudo $0 INITIATOR_IP RESPONDER_IP [lab-directory]" >&2
	exit 2
fi

initiator_ip=$1
responder_ip=$2
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
lab_dir=${3:-${script_dir}}
client_template=${lab_dir}/uaf2_initiator.conf.in
zone_template=${lab_dir}/uaf2-poc.net.zone.in
named_template=${lab_dir}/uaf2_named.conf
ckaid_file=/etc/ipsec.d/uaf2-ckaid

for path in "${client_template}" "${zone_template}" "${named_template}"; do
	if [[ ! -f ${path} ]]; then
		echo "missing ${path}" >&2
		exit 2
	fi
done

for command in ipsec named-checkconf named-checkzone systemctl awk sed; do
	if ! command -v "${command}" >/dev/null 2>&1; then
		echo "missing command '${command}'; install libreswan, bind and bind-utils" >&2
		exit 2
	fi
done

mkdir -p /etc/ipsec.d

if [[ ! -f /var/lib/ipsec/nss/cert9.db ]]; then
	echo "initializing the Libreswan NSS database"
	ipsec initnss
fi

if [[ -s ${ckaid_file} ]]; then
	ckaid=$(tr -d '[:space:]' < "${ckaid_file}")
	echo "reusing RSA key CKAID ${ckaid}"
else
	echo "generating a dedicated RSA host key in the Libreswan NSS database"
	key_output=$(ipsec newhostkey --keytype rsa 2>&1) || {
		echo "${key_output}" >&2
		exit 1
	}
	echo "${key_output}"
	ckaid=$(sed -n 's/^.*ckaid[[:space:]]\+//p' <<<"${key_output}" | tail -n 1)
	if [[ -z ${ckaid} ]]; then
		echo "could not extract CKAID from ipsec newhostkey output" >&2
		exit 1
	fi
	printf '%s\n' "${ckaid}" > "${ckaid_file}"
	chmod 600 "${ckaid_file}"
fi

if ! ipsec showhostkey --list | grep -Fqi "${ckaid}"; then
	echo "CKAID ${ckaid} is not present in the active NSS database" >&2
	exit 1
fi

ipseckey_rdata=$(
	ipsec showhostkey --ipseckey --ckaid "${ckaid}" |
	awk '$3 == "IPSECKEY" {
		for (i = 4; i <= NF; i++) {
			printf "%s%s", (i == 4 ? "" : " "), $i
		}
		printf "\n"
		exit
	}'
)

if [[ -z ${ipseckey_rdata} ]]; then
	echo "could not derive IPSECKEY RDATA for CKAID ${ckaid}" >&2
	exit 1
fi

tmp_conf=$(mktemp)
tmp_zone=$(mktemp)
tmp_named=$(mktemp)
trap 'rm -f "${tmp_conf}" "${tmp_zone}" "${tmp_named}"' EXIT

sed \
	-e "s|@@CKAID@@|${ckaid}|g" \
	-e "s|@@INITIATOR_IP@@|${initiator_ip}|g" \
	-e "s|@@RESPONDER_IP@@|${responder_ip}|g" \
	"${client_template}" > "${tmp_conf}"
sed \
	-e "s|@@IPSECKEY_RDATA@@|${ipseckey_rdata}|g" \
	-e "s|@@DNS_IP@@|${initiator_ip}|g" \
	"${zone_template}" > "${tmp_zone}"
sed "s|@@DNS_IP@@|${initiator_ip}|g" "${named_template}" > "${tmp_named}"

if [[ ! -e /etc/ipsec.conf.uaf2-backup ]]; then
	cp -a /etc/ipsec.conf /etc/ipsec.conf.uaf2-backup
fi
if [[ ! -e /etc/named.conf.uaf2-backup ]]; then
	cp -a /etc/named.conf /etc/named.conf.uaf2-backup
fi

install -m 600 "${tmp_conf}" /etc/ipsec.conf
install -m 640 -o root -g named "${tmp_zone}" /var/named/uaf2-poc.net.zone
install -m 640 -o root -g named "${tmp_named}" /etc/named.conf

mkdir -p /var/log/named
chown named:named /var/log/named
restorecon -RF /var/named /var/log/named /etc/named.conf 2>/dev/null || true

named-checkconf /etc/named.conf
named-checkzone uaf2-poc.net /var/named/uaf2-poc.net.zone

systemctl enable --now named
systemctl restart named

if command -v firewall-cmd >/dev/null 2>&1 &&
   systemctl is-active --quiet firewalld; then
	firewall-cmd --permanent --add-service=dns >/dev/null
	firewall-cmd --reload >/dev/null
fi

systemctl restart ipsec
ipsec whack --impair suppress_retransmits || true

echo
echo "VM2 ready"
echo "  CKAID: ${ckaid}"
echo "  DNS:   dig @${initiator_ip} attacker.uaf2-poc.net A"
echo "         dig @${initiator_ip} attacker.uaf2-poc.net IPSECKEY"
echo "  IKE:   ipsec status | grep uaf2-ipseckey"
