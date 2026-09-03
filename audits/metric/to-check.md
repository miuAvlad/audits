## Preliminary Findings in `buyToken1InBinSpecifiedIn`

| Priority | Potential Issue                                                        | Current Assessment                                                                        |
| -------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| 1        | Split swaps may receive better execution than a single equivalent swap | Confirmed path dependence, but no profitable round trip; Informational/known design       |
| 2        | Bin cursor may move despite zero token output                          | Confirmed; economically bounded by output granularity; Low/QA                              |
| 3        | `targetPos` and `out1Scaled` are rescaled independently                | Confirmed one-cursor-quantum mismatch; no Medium impact found; Low/QA                      |
| 4        | Remaining input may be consumed without additional output              | Fuzzed below one basis point at economic scale; Low/QA                                     |
| 5        | Cursor may be advanced into a boundary-only next bin                   | Valid integration-level issue; already investigated separately                            |
| 6        | Bin token balance may exceed the `uint104` storage capacity            | **Medium candidate:** high decimals make a persistent directional DoS cheaply reachable   |

## Validation results

The focused regression suite is in `metric-core/test/SwapMath.toCheck.audit.t.sol`.

- **Split execution:** confirmed. A 64-part exact-input swap in a factory-valid `6.5535%` bin receives about `1.6` bps more output than a one-shot swap. An extreme but valid low-price bin shows a much larger fixed-movement difference. However, the endpoint-mean model and its path dependence are explicitly documented. A reverse swap remains loss-making even with zero additional fee, and the documented width fee makes the tested round trip lose `316` bps. No LP drain was established.
- **Zero-output cursor movement:** confirmed. A price-limited swap can change `curPosInBin` while transferring and charging zero tokens. The movable fraction is bounded by output granularity: material liquidity makes the free movement economically negligible, while a large movement requires dust inventory. The existing boundary-bin/extension finding remains the stronger integration impact.
- **Independent rescaling:** confirmed. The returned cursor can imply a different output by approximately one cursor quantum, which scales with `token1Balance / curPosInBin`. No profitable amplification was found.
- **Input overcharge/undercharge:** 50,001 economic-scale fuzz cases with inputs of at least `1e12` internal units found no endpoint-quote mismatch above one basis point. Small-unit mismatches exist in both directions, so the code does not literally round toward the pool in every branch, but no Medium impact was demonstrated.
- **Boundary-only adjacent bin:** already covered by `my-audit/vulnerabilities/oracle-stop-loss-boundary-bin-dos.md`.
- **`uint104` capacity:** promoted to a Medium candidate. The end-to-end PoC in `metric-core/test/MetricOmmPool.uint104Capacity.audit.t.sol` uses standard 18- and 30-decimal ERC-20s plus ordinary `lengthE6 = 100` bins. Two permissionless swaps leave less than one external token0 wei of capacity while token1 remains in the current bin, causing every swap in that direction to revert and blocking all lower-bin liquidity. Full write-up: `my-audit/vulnerabilities/uint104-bin-capacity-directional-dos.md`.

---

### 1. Split swaps may receive better execution than a single equivalent swap

The function prices a traversal by averaging the inverted prices at the starting and final bin positions. Because the reciprocal of a linearly interpolated price is nonlinear, splitting one large swap into several smaller swaps may produce a different—and potentially more favorable—result for the trader.

This makes execution path-dependent:

```text
output(single swap with input A + B)
may be less than
output(swap with input A) + output(swap with input B)
```

If the advantage remains material after fees, rounding and full pool settlement are included, a trader may extract additional value from LP inventory simply by splitting a swap into multiple transactions.

**Final assessment:** Informational/known design. Execution improves under fragmentation, but the model is documented and both zero-fee and fee-protected round trips remained loss-making in the regression tests.

---

### 2. The pool cursor may advance into an adjacent boundary-only bin without consuming liquidity from that bin

`calculateOutputToken1FromBinPosition()` rounds the calculated output down. For small token balances or small position movements, the resulting output can therefore be zero even when `targetPos` differs from `currBinPos`.

The exact-input function does not always reset the position when `out1Scaled == 0`. As a result, it may return:

```text
finalBinPos != currBinPos
out1Scaled == 0
delta0Scaled == 0
delta1Scaled == 0
```

This means the pool cursor can move without any corresponding token transfer or balance change.

Possible consequences include:

* changing the effective starting price for subsequent traders;
* creating a mismatch between the cursor position and bin inventory;
* affecting hooks or extensions that infer touched bins from cursor movement;
* enabling boundary-position manipulation.

**Final assessment:** Low/QA in isolation. A meaningful free movement requires dust-sized outgoing inventory. Use the separate boundary-bin extension finding for the stronger integration impact.

---

### 3. `targetPos` and `out1Scaled` are rescaled independently

When the initially calculated input exceeds the remaining user input, the function rescales both the position movement and the output:

```solidity
scaledDelta = ceil(delta * remainingInput / calculatedInput);
targetPos = currBinPos - scaledDelta;

out1Scaled =
    out1Scaled * remainingInput / calculatedInput;
```

However, `out1Scaled` is not recalculated directly from the newly selected `targetPos`.

The following invariant may therefore be violated:

```text
returned out1Scaled
==
calculateOutputToken1FromBinPosition(
    originalToken1Balance,
    originalCurrBinPos,
    returnedTargetPos
)
```

This can leave the returned position and token balance movement representing slightly different states.

Possible consequences include:

* accumulation of rounding dust;
* inconsistencies between cursor position and remaining liquidity;
* different results depending on swap fragmentation;
* unexpected behavior at bin boundaries.

**Final assessment:** Low/QA. The mismatch was confirmed but remained bounded to approximately one cursor quantum, and no profitable amplification was found.

---

### 4. Remaining input may be consumed without additional output

After the analytical estimation and refinement steps, the calculated input may still be slightly below the user's remaining exact-input amount.

The function then contains logic equivalent to:

```solidity
if (
    totalIn0Scaled < amountSpecifiedRemainingScaled
    && targetPos > minFinalBinPos
) {
    totalIn0Scaled = amountSpecifiedRemainingScaled;
}
```

This consumes the full remaining input without changing:

* `targetPos`;
* `out1Scaled`;
* the calculated final price.

The user may therefore pay a slightly larger input amount without receiving any additional output.

This may be intentional to eliminate a one-unit rounding remainder, but it should be verified that the difference is always bounded to negligible dust.

**Final assessment:** Low/QA. Economic-scale fuzzing found no mismatch above one basis point; small undercharges and overcharges exist but no repeatable Medium loss was demonstrated.

---

### 5. Cursor may be advanced into a boundary-only next bin

When the current bin is fully consumed, the outer swap loop may advance the cursor into the adjacent bin and set the position to that bin's boundary, even if no liquidity from the new bin was actually traded.

For example:

```text
curBinIdx = i - 1
curPosInBin = MAX_POS_BIN
```

may represent only that the previous bin was exhausted—not that the new bin had non-zero swap deltas.

Extensions that determine “touched bins” only from the initial and final cursor indexes may incorrectly process the adjacent bin.

Possible consequences include:

* false hook execution;
* incorrect watermark or accounting updates;
* one-directional swap denial;
* manipulation of extension state for bins that were not economically affected.

**Final assessment:** Valid integration-level concern already investigated separately in the context of boundary-only bins and extension checks.

---

### 6. Bin token balance may exceed the `uint104` storage capacity

At the end of the function, the incoming token0 amount is added to the bin balance and cast to `uint104`:

```solidity
binState.token0BalanceScaled =
    (
        uint256(binState.token0BalanceScaled)
        + totalIn0Scaled
        - protocolFeeAmountScaled
    ).toUint104();
```

The function does not appear to explicitly limit the swap based on the remaining `uint104` capacity of the bin balance.

If:

```text
current token0 balance
+ net incoming token0
> type(uint104).max
```

the cast will revert, potentially preventing an otherwise valid swap from being partially filled.

This may be reachable for bins with:

* a high existing token0 balance;
* a large token1 inventory;
* extreme but valid price ratios;
* a sufficiently large exact-input swap.

**Final assessment:** Medium candidate. High token decimals make the cap cheaply reachable, and the end-to-end PoC proves a persistent directional DoS that blocks downstream bins. See `my-audit/vulnerabilities/uint104-bin-capacity-directional-dos.md`.
