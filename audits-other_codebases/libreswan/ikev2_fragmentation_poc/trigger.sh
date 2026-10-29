#!/usr/bin/env bash
# Create a bounded number of incomplete protected-fragment queues.

set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

ipsec_command=${IPSEC_COMMAND:-/usr/local/sbin/ipsec}
connection=${CONNECTION:-fragment-retention-poc}
fragment_bytes=${FRAGMENT_BYTES:-65000}
sa_count=${SA_COUNT:-1}
hard_max_sas=8

case ${fragment_bytes} in
	''|*[!0-9]*) echo "FRAGMENT_BYTES must be an integer" >&2; exit 2 ;;
esac
case ${sa_count} in
	''|*[!0-9]*) echo "SA_COUNT must be an integer" >&2; exit 2 ;;
esac

if (( fragment_bytes < 1 || fragment_bytes > 65000 )); then
	echo "FRAGMENT_BYTES must be between 1 and 65000" >&2
	exit 2
fi
if (( sa_count < 1 || sa_count > hard_max_sas )); then
	echo "SA_COUNT must be between 1 and ${hard_max_sas}" >&2
	exit 2
fi

if ! "${ipsec_command}" whack --impair help 2>&1 |
	grep -q v2_incomplete_fragments; then
	echo "the client build does not contain the test impairment" >&2
	exit 1
fi

cleanup()
{
	"${ipsec_command}" whack --no-impair v2_incomplete_fragments \
		>/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

"${ipsec_command}" whack --impair "v2_incomplete_fragments:${fragment_bytes}"

for ((attempt = 1; attempt <= sa_count; attempt++)); do
	"${ipsec_command}" whack --initiate --name "${connection}" --asynchronous
	echo "launched incomplete SA ${attempt}/${sa_count}"
done

sleep 2
echo "Trigger complete. Inspect the responder with observe_responder.sh."
echo "The queues remain until the responder's incomplete-SA timeout expires."

