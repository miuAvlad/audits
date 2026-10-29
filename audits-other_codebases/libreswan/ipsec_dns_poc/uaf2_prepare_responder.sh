#!/usr/bin/env bash
# Prepare VM1 (vulnerable Pluto responder) for the UAF_2 lab.

set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [[ ${EUID} -ne 0 || $# -lt 2 || $# -gt 3 ]]; then
	echo "usage: sudo $0 RESPONDER_IP INITIATOR_IP [lab-directory]" >&2
	exit 2
fi

responder_ip=$1
initiator_ip=$2
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
lab_dir=${3:-${script_dir}}
responder_template=${lab_dir}/uaf2_responder.conf.in
dns_server=${initiator_ip}

if [[ ! -f ${responder_template} ]]; then
	echo "missing ${responder_template}" >&2
	exit 2
fi

for command in ipsec dig systemctl; do
	if ! command -v "${command}" >/dev/null 2>&1; then
		echo "missing command '${command}'; install libreswan and bind-utils" >&2
		exit 2
	fi
done

echo "checking the authoritative DNS service on VM2"
dig +time=2 +tries=1 @${dns_server} attacker.uaf2-poc.net A
dig +time=2 +tries=1 @${dns_server} attacker.uaf2-poc.net IPSECKEY

if [[ ! -e /etc/ipsec.conf.uaf2-backup ]]; then
	cp -a /etc/ipsec.conf /etc/ipsec.conf.uaf2-backup
fi
if [[ ! -e /etc/resolv.conf.uaf2-backup ]]; then
	cp -aL /etc/resolv.conf /etc/resolv.conf.uaf2-backup
fi

tmp_conf=$(mktemp)
trap 'rm -f "${tmp_conf}"' EXIT

# v5.4-346-gb49d6bcaeb contains a parser typo: the registered ipsec.conf
# keyword is literally "dns-match-id,".  Released builds normally accept
# "dns-match-id".  Probe both spellings and install the one accepted by the
# Pluto/addconn pair under test.
dns_match_keyword=
for candidate in dns-match-id dns-match-id,; do
	sed \
		-e "s/@@DNS_MATCH_KEYWORD@@/${candidate}/g" \
		-e "s|@@RESPONDER_IP@@|${responder_ip}|g" \
		-e "s|@@INITIATOR_IP@@|${initiator_ip}|g" \
		"${responder_template}" > "${tmp_conf}"
	if ipsec addconn --checkconfig --config "${tmp_conf}" >/dev/null 2>&1; then
		dns_match_keyword=${candidate}
		break
	fi
done

if [[ -z ${dns_match_keyword} ]]; then
	echo "neither dns-match-id nor dns-match-id, is accepted by ipsec addconn" >&2
	exit 1
fi

sed \
	-e "s/@@DNS_MATCH_KEYWORD@@/${dns_match_keyword}/g" \
	-e "s|@@RESPONDER_IP@@|${responder_ip}|g" \
	-e "s|@@INITIATOR_IP@@|${initiator_ip}|g" \
	"${responder_template}" > "${tmp_conf}"
ipsec addconn --checkconfig --config "${tmp_conf}"
install -m 600 "${tmp_conf}" /etc/ipsec.conf

# Pluto reads resolv.conf only at startup. If systemd-resolved owns it,
# preserve the symlink target and replace it with a deterministic lab resolver.
if [[ -L /etc/resolv.conf ]]; then
	readlink /etc/resolv.conf > /etc/resolv.conf.uaf2-link
	systemctl stop systemd-resolved || true
	unlink /etc/resolv.conf
fi
printf 'nameserver %s\noptions timeout:1 attempts:1\n' "${dns_server}" > /etc/resolv.conf
chmod 644 /etc/resolv.conf

if [[ -z $(dig +short attacker.uaf2-poc.net IPSECKEY) ]]; then
	echo "system resolver cannot retrieve the lab IPSECKEY record" >&2
	exit 1
fi

if command -v firewall-cmd >/dev/null 2>&1 &&
   systemctl is-active --quiet firewalld; then
	firewall-cmd --permanent --add-service=ipsec >/dev/null || true
	firewall-cmd --permanent --add-port=500/udp >/dev/null
	firewall-cmd --permanent --add-port=4500/udp >/dev/null
	firewall-cmd --reload >/dev/null
fi

systemctl restart ipsec

# The lab zone is deliberately unsigned.  This impairment changes only the
# acceptance of insecure DNS answers; production reachability uses DNSSEC.
if ! ipsec whack --impair allow_dns_insecure; then
	echo "failed to enable allow_dns_insecure; verify that this Pluto build exposes the impairment" >&2
	exit 1
fi

if ! grep -q 'IPSECKEY support \[enabled\]' /tmp/pluto-uaf2.log; then
	echo "warning: the log does not confirm IPSECKEY support; inspect /tmp/pluto-uaf2.log" >&2
fi

echo
echo "VM1 ready"
echo "  keyword:  ${dns_match_keyword}=yes"
echo "  resolver: ${dns_server} (loaded by Pluto at restart)"
echo "  config:   ipsec status | grep uaf2-ipseckey"
echo "  log:      tail -f /tmp/pluto-uaf2.log"
