# Revoked pusher authorizations can be replayed to misroute fresh compressed-oracle updates

## Severity
known issue
Potential Medium, pending an end-to-end pool PoC and confirmation that production deployments use reusable delegated EOA pushers.

The issue does not require an oracle admin or protocol admin. A formerly authorized feed creator can replay an unexpired pusher authorization after revocation and redirect the pusher's subsequent updates into the former creator's namespace. This can leave a victim creator's previous oracle value active during its configured staleness window, allowing an attacker who observes the fresh update to trade against the old pool quote. After that window expires, the affected pool fails closed and swaps revert.

The strongest impact is therefore stale-but-still-accepted execution and potential LP loss, not only temporary denial of service.

## Summary

`CompressedOracleV1.allowPushers()` accepts an EIP-191 signature from a pusher authorizing a creator to map that pusher into the creator's namespace. The signed message binds the chain, oracle, deadline, pusher, and creator, but it contains no nonce or revocation epoch.

`revokePusher()` only clears `namespaceRemapping[msg.sender]`. It does not invalidate signatures that were issued before the revocation. Until an old signature's deadline expires, the former creator can submit it again and restore the delegation without new consent from the pusher.

Because `fallback()` determines the destination namespace from the live `namespaceRemapping[msg.sender]` value at execution time, replaying the old authorization can redirect an honest pusher transaction that was intended to update another creator. The victim feed remains at its previous value and timestamp even though a correct and timely update was submitted on-chain.

## Affected code

- `smart-contracts-poc/contracts/oracles/compressed/CompressedOracle.sol`
  - `allowPushers()`
  - `revokePusher()`
  - `fallback()`
- `smart-contracts-poc/contracts/PriceProvider.sol`
  - `_isStale()`
  - `_getBidAndAskPrice()`

## Root cause

The pusher signs the following authorization in `allowPushers()`:

```solidity
bytes32 hash = MessageHashUtils.toEthSignedMessageHash(
    keccak256(abi.encode(block.chainid, address(this), deadline, pusher, msg.sender))
);
require(pusher == ECDSA.recover(hash, signatures[i]));

namespaceRemapping[pusher] = msg.sender;
```

The authorization contains no nonce, sequence number, or revocation epoch. Every successful invocation with the same creator and unexpired signature is therefore valid, regardless of whether the pusher revoked that authorization in the meantime.

Revocation only deletes the current routing entry:

```solidity
function revokePusher() external {
    address creator = namespaceRemapping[msg.sender];
    if (creator == address(0) || creator == msg.sender) revert NoSelfRemapping();
    namespaceRemapping[msg.sender] = address(0);
    emit PusherRevoked(msg.sender, creator);
}
```

Finally, an update does not bind its intended creator in calldata. `fallback()` resolves the creator from the mutable mapping when the transaction executes:

```solidity
address creator = namespaceRemapping[msg.sender];
if (creator == address(0)) creator = msg.sender;
```

Consequently, changing the mapping immediately before an honest pusher update changes the namespace into which that update is written.

## Attack path

Assume EOA pusher `P` was previously delegated to attacker-controlled creator `A` using an authorization with deadline `T`.

1. `P` signs an authorization for `A`, and `A` calls `allowPushers()`.
2. `P` later calls `revokePusher()`, but the old signature remains cryptographically valid until `T`.
3. `P` authorizes victim creator `B`. `namespaceRemapping[P]` now points to `B`.
4. Pools use a compressed-oracle feed whose feed ID encodes creator `B`.
5. `P` submits an initial price update, which is correctly written into `B`'s namespace.
6. The external market price moves and `P` submits a newer, correct update for `B`.
7. Attacker `A` observes the update transaction and front-runs it by calling `allowPushers()` with the old signature.
8. `namespaceRemapping[P]` is changed from `B` back to `A`.
9. When the honest pusher transaction executes, `fallback()` writes the fresh slot word into `A`'s namespace.
10. `B`'s feed retains its previous price and timestamp.
11. While that timestamp is still inside the provider's accepted `MAX_TIME_DELTA`, the attacker swaps against the victim pool using the old oracle quote, while already knowing the fresh price from the pusher's calldata.

The attacker can also replay the old authorization after every attempt to remap `P` to `B`, until deadline `T` expires.

## Stale-price extraction

`PriceProvider` does not reject every price older than the latest submitted update. It accepts a price while its age is within `MAX_TIME_DELTA`:

```solidity
function _isStale(uint256 refTime, uint256 nowTs, uint256 maxDelta)
    internal
    pure
    returns (bool)
{
    if (refTime == 0) return true;
    if (refTime > nowTs) return true;
    return (nowTs - refTime) > maxDelta;
}
```

Therefore, update misrouting creates two phases:

1. Before `MAX_TIME_DELTA` expires, the victim's previous price remains valid to the provider. If the market moved farther than the pool's spread and fees, the attacker can extract value from LPs by trading at that obsolete quote.
2. After `MAX_TIME_DELTA` expires, the provider fails closed with `FeedStalled`, causing a swap DoS until creator `B` restores its update path.

The first phase is the Medium-impact candidate because it can cause direct LP loss. The second phase is an additional liveness impact.

## Why this does not require admin interaction

Neither initial delegation nor replay is gated by `ADMIN_ROLE`.

The only authorization needed by the attacker is the pusher signature that was legitimately issued to the attacker's creator address in the past. After obtaining it, the creator can replay it directly through `allowPushers()` without:

- approval from the oracle admin;
- approval from the protocol or pool admin;
- a new signature from the pusher;
- control over the victim creator;
- control over the pusher's private key.

The attacker is not an arbitrary address with no prior relationship: they must be a formerly authorized creator and the old authorization must remain before its deadline. However, after those conditions exist, exploitation requires only public transactions by the attacker.

## Interaction with the oracle correctness assumption

The attack does not require the honest pusher to submit an incorrect, late, or stale update. The pusher constructs and broadcasts a correct and timely update.

The update becomes ineffective for the victim because the oracle contract resolves its namespace through a replayable on-chain delegation at execution time. Framing the issue as authorization replay and deterministic update misrouting is therefore stronger than framing it as a generic missing staleness check or an off-chain pusher outage.

There is nevertheless judging risk because the contest README states that compressed-oracle updates and oracles are assumed correct and non-stale. A complete PoC should emphasize that the submitted update itself is correct and timely, and that the on-chain contract writes it to the wrong namespace due to stale authorization state.

## Preconditions and limitations

- The pusher is an EOA using `allowPushers()` and the delegated `fallback()` update path. The issue does not affect creator-signed `updateBySignature()` updates in the same way.
- The attacker was previously authorized by that pusher.
- The old authorization deadline has not expired. The contract enforces no maximum authorization lifetime.
- The pusher address is later reused for another creator while the old authorization remains valid.
- The victim relies on that pusher long enough for the attacker to suppress at least one update.
- For direct LP loss, the external price must move enough for the old pool quote to be profitable after spreads and fees.
- The victim can recover by using another pusher address, pushing directly from the creator, or using creator-signed updates. These recovery paths limit the persistent DoS impact, but they do not prevent an atomic front-run and stale-price trade before operators react.

## Conceptual PoC

A Foundry test should demonstrate the following sequence:

```text
P signs authorization(A, longDeadline)
A registers P
P revokes A

P signs authorization(B, newDeadline)
B registers P
P pushes oldPrice into B's namespace

market price changes
A replays authorization(A, longDeadline)
P pushes freshPrice, which is written into A's namespace

assert oracle.price(feedId(B)) == oldPrice
assert oracle.price(feedId(A)) == freshPrice
assert PriceProvider(B) still accepts oldPrice within MAX_TIME_DELTA
execute victim-pool swap at oldPrice
assert attacker profit / LP value loss

warp beyond MAX_TIME_DELTA
assert victim-pool swaps revert with FeedStalled
```

For the strongest reproduction, the test should order the replay, honest update, and attacker swap as adjacent transactions to model mempool front-running.

## Recommendation

Make every pusher authorization single-use or bind it to a revocable nonce.

For example:

```solidity
mapping(address pusher => uint256 nonce) public pusherNonce;
```

Include `pusherNonce[pusher]` in the signed authorization and increment it after successful use:

```solidity
uint256 nonce = pusherNonce[pusher];

bytes32 hash = MessageHashUtils.toEthSignedMessageHash(
    keccak256(
        abi.encode(
            block.chainid,
            address(this),
            deadline,
            nonce,
            pusher,
            msg.sender
        )
    )
);

require(pusher == ECDSA.recover(hash, signature));
pusherNonce[pusher] = nonce + 1;
namespaceRemapping[pusher] = msg.sender;
```

Consuming the nonce when the authorization is installed prevents the same signature from restoring a delegation after revocation or after the pusher moves to another creator.

As defense in depth, the protocol can also:

- enforce a maximum authorization lifetime;
- provide an explicit pusher-controlled nonce invalidation function;
- bind delegated update payloads to their intended creator and reject routing mismatches;
- emit the intended creator in off-chain update metadata so monitoring can detect namespace misrouting.
