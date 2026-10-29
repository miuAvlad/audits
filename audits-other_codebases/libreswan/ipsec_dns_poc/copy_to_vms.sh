#!/usr/bin/env bash
# Copy the appropriate half of the PoC to each explicitly supplied test VM.
# Usage: ./copy_to_vms.sh user@responder user@initiator [remote-directory]

set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [[ $# -lt 2 || $# -gt 3 ]]; then
	echo "usage: $0 user@responder user@initiator [remote-directory]" >&2
	exit 2
fi

responder_target=$1
initiator_target=$2
remote_dir=${3:-/tmp/ipsec-dns-uaf-poc}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [[ ! ${remote_dir} =~ ^/tmp/[A-Za-z0-9._/-]+$ ]]; then
	echo "remote directory must be a simple absolute path below /tmp" >&2
	exit 2
fi

ssh -- "${responder_target}" "install -d -m 700 '${remote_dir}'"
ssh -- "${initiator_target}" "install -d -m 700 '${remote_dir}'"

scp -p -- \
	"${script_dir}/uaf2_responder.conf.in" \
	"${script_dir}/uaf2_prepare_responder.sh" \
	"${responder_target}:${remote_dir}/"

scp -p -- \
	"${script_dir}/uaf2_initiator.conf.in" \
	"${script_dir}/uaf2_named.conf" \
	"${script_dir}/uaf2-poc.net.zone.in" \
	"${script_dir}/uaf2_prepare_initiator.sh" \
	"${script_dir}/uaf2_trigger.sh" \
	"${initiator_target}:${remote_dir}/"

echo "Responder files: ${responder_target}:${remote_dir}"
echo "Initiator files: ${initiator_target}:${remote_dir}"
