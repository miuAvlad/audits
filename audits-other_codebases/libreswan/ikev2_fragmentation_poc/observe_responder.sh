#!/usr/bin/env bash
# Print the responder state and memory relevant to the bounded PoC.

set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

ipsec_command=${IPSEC_COMMAND:-/usr/sbin/ipsec}
log_file=${LOG_FILE:-/tmp/ikev2-fragment-server.log}
pid=$(pgrep -o -x pluto || true)

if [[ -z ${pid} ]]; then
	echo "Pluto is not running" >&2
	exit 1
fi

echo "Pluto PID: ${pid}"
grep -E '^(VmRSS|VmSize|RssAnon):' "/proc/${pid}/status" || true
echo
printf 'Incomplete fragment PoC states: '
"${ipsec_command}" whack --showstates 2>/dev/null |
	grep 'fragment-retention-poc.*IKE_SA_INIT_R' |
	wc -l
echo
"${ipsec_command}" whack --showstates 2>/dev/null |
	grep -E 'fragment-retention-poc|IKE_SA_INIT|IKE_AUTH' || true
echo
grep -E 'received IKE encrypted fragment|collecting fragments|fragment .*decrypted|EVENT_v2_DISCARD' \
	"${log_file}" 2>/dev/null | tail -80 || true

