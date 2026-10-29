#!/usr/bin/env bash
# Copy the generated lab files to two explicitly supplied disposable VMs.
# Usage: ./copy_to_vms.sh user@responder user@initiator [remote-directory]

set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [[ $# -lt 2 || $# -gt 3 ]]; then
	echo "usage: $0 user@responder user@initiator [remote-directory]" >&2
	exit 2
fi

responder_target=$1
initiator_target=$2
remote_dir=${3:-/tmp/ikev2-fragmentation-poc}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
generated=${script_dir}/generated

if [[ ! ${remote_dir} =~ ^/tmp/[A-Za-z0-9._/-]+$ ]]; then
	echo "remote directory must be a simple absolute path below /tmp" >&2
	exit 2
fi

for file in server.conf client.conf ipsec.secrets; do
	if [[ ! -r ${generated}/${file} ]]; then
		echo "missing ${generated}/${file}; run render_lab.sh first" >&2
		exit 2
	fi
done

ssh -- "${responder_target}" "install -d -m 700 '${remote_dir}'"
ssh -- "${initiator_target}" "install -d -m 700 '${remote_dir}'"

scp -p -- \
	"${generated}/server.conf" \
	"${generated}/ipsec.secrets" \
	"${script_dir}/observe_responder.sh" \
	"${responder_target}:${remote_dir}/"

scp -p -- \
	"${generated}/client.conf" \
	"${generated}/ipsec.secrets" \
	"${script_dir}/trigger.sh" \
	"${initiator_target}:${remote_dir}/"

echo "Files copied. The patched initiator build must be installed separately."
