# SuperDCA Gauge / Staking Audit Findings (Draft)

> **Author:** Vlad  
> **Scope:** `SuperDCAStaking.sol`, `SuperDCAGauge.sol`  
> **Type:** Security Findings / Economic Exploits  
> **Status:** Draft (no PoC provided)

---

## Finding 1 — Reward distribution can be temporarily blocked (backlog sniping via `delta == 0`)

### Summary
In `SuperDCAStaking`, the reward distribution for a given token bucket can be **temporarily prevented** by forcing `accrueReward(token)` to return `0` repeatedly.  
Because `SuperDCAGauge` skips minting when `rewardAmount == 0`, an attacker can cause **reward distribution delays**, accumulate an internal “backlog”, and later attempt to **snipe** the distribution by becoming the dominant liquidity provider right before distribution resumes.

### Relevant Code Paths

#### `SuperDCAStaking.sol` — `stake` / `unstake`
Both `stake()` and `unstake()` call `_updateRewardIndex()` and then set:
```solidity
info.lastRewardIndex = rewardIndex;
```
So after staking/unstaking, `lastRewardIndex` becomes **exactly equal** to the current global `rewardIndex`.

#### `SuperDCAStaking.sol` — `accrueReward`
`accrueReward(token)` computes:
```solidity
uint256 delta = rewardIndex - info.lastRewardIndex;
if (delta == 0) return 0;
```
If `accrueReward(token)` is called in the same block (or after a `stake/unstake` that caused `lastRewardIndex == rewardIndex`), then `delta == 0` and `rewardAmount == 0`.

#### `SuperDCAGauge.sol` — `_handleDistributionAndSettlement`
`accrueReward()` is called in hooks such as:
```solidity
uint256 rewardAmount = staking.accrueReward(otherToken);
if (rewardAmount == 0) return;
```
Therefore, **the entire minting / distribution flow is skipped** whenever `rewardAmount == 0`.

### Why this matters in Uniswap v4
In Uniswap v4, amounts distributed via `donate` are accounted as **fees** (credited to `feeGrowth`) rather than as increased effective liquidity. This makes “distribution timing” and “who is LP at distribution time” economically meaningful: whoever controls the fee-earning liquidity at the time distribution finally occurs can capture the majority of donated rewards.

### Root Cause
- **`SuperDCAStaking.sol`** (around line ~285 in `eaa790c`)
  - `if (delta == 0) return 0;`
- **`SuperDCAGauge.sol`** (around line ~335 in `eaa790c`)
  - `if (rewardAmount == 0) return;`

### Preconditions

#### Internal Preconditions
- None

#### External Preconditions
- Attacker can call `stake/unstake`
- Attacker can front-run transactions
- Attacker can provide enough liquidity to capture most of the eventual donated-fee distribution  
  (optionally via flash liquidity/flash loans)

### Attack Path (Backlog Sniping)
1. **Block reward distribution** for LPs by repeatedly timing `stake/unstake` so that `lastRewardIndex == rewardIndex` right before `accrueReward()` is triggered by gauge hooks.
2. Rewards **virtually accrue in internal accounting**, but the distribution transaction path is skipped due to `rewardAmount == 0`.
3. Once the internal accounting implies a large “burst” can happen, attacker:
   - provides large liquidity in the fee-earning range,
   - ensures distribution does **not** occur before they become LP (by again blocking it in the same tx / ordering window via hook timing),
4. In subsequent blocks, someone triggers distribution again (by add/remove liquidity etc.).
5. Attacker, as dominant LP, captures the majority of the “donated fees” via fee growth.
6. (Optional upgrade) Attacker attempts price manipulation (flash loan) to move price into a range with fewer LPs at the moment distribution resumes, maximizing their share. This is harder in Uniswap v4 due to constraints on large price moves, but may still be feasible with sufficient capital/engineering.

> The attack is significantly more cost-effective on low-gas chains, but can be profitable on higher-gas networks if token unit value and “reward burst” size exceed transaction costs.

### Impact
- **Delay in rewards distribution** for LPs (temporary reward stoppage).
- **Backlog sniping opportunity**: attacker positions as dominant LP when distribution resumes and captures a disproportionate share of donated rewards.
- Potential reduction in long-term accrued rewards if LPs become disincentivized and withdraw liquidity/stake due to missing rewards.

### PoC
- Not provided.

### Mitigation
**Enforce time-locking / cooldown** on `stake` and `unstake` (per token bucket or per user) to prevent block-by-block toggling that can repeatedly force `delta == 0` at critical times.

Additional mitigation ideas (optional, defense-in-depth):
- Do not skip distribution on `rewardAmount == 0`; accumulate and attempt again in a bounded way (careful of gas).
- Separate “index update” from “bucket last index update” so a stake/unstake cannot trivially zero-out `delta` right before a gauge-triggered accrual.
- Consider a minimum elapsed time or minimum index delta requirement for updating `lastRewardIndex` on stake/unstake.

---

## Finding 2 — Keeper role can be flip-flopped cheaply for fee arbitrage (missing minimum bid increment)

### Summary
The `keeper` role in `SuperDCAGauge` can be seized for a **very short window** by outbidding the existing keeper by an extremely small amount (e.g., **+1 wei**).  
An attacker can front-run a legitimate keeper-bid transaction or simply outbid the current keeper by a trivial increment, become keeper briefly, and take advantage of **lower keeper fees** (e.g., 0.1% vs 0.5%) to execute swaps cheaply—then allow the original user/protocol to reclaim the role.

Because the docs frame the role as a competitive “king-of-the-hill” contest, users are incentivized to bid the smallest possible increment, enabling systematic **micro-flip** keeper changes that capture discounted fees without meaningful commitment.

### Root Cause
- **`SuperDCAGauge.sol`** (around line ~451 in `eaa790c`)
  - `function becomeKeeper(uint256 amount) external { ... }`  
  - Missing **minimum increment** check beyond `amount > keeperDeposit`.

### Preconditions

#### Internal Preconditions
- Different fee tiers exist for keeper vs normal users (keeper has better fees)

#### External Preconditions
- Attacker holds `DCA` tokens
- Attacker can front-run transactions
- Attacker can profit off swapping during the brief keeper window

### Attack Path
1. User/protocol submits a transaction to become keeper with deposit `X`.
2. Attacker front-runs and bids `keeperDeposit + 1 wei` (or similarly minimal increment) to steal keeper role briefly.
3. During the short window, attacker executes swaps benefiting from lower keeper fee.
4. User/protocol tx executes afterward and reclaims keeper role.
5. Attacker repeats opportunistically to harvest discounted fees during high-volume activity.

### Impact
- **Anyone can benefit from reduced fees** (potentially up to 5× lower vs normal flow).
- **LPs earn less fees** overall because swap fees paid into the pool are reduced.
- Loss scales with swap volume; in high-volume periods the fee shortfall can accumulate significantly.

### PoC
- Not provided.

### Mitigation
Add a **minimum required increment** (a “bid step”) above the previous `keeperDeposit`.

Example patch:
```solidity
function becomeKeeper(uint256 amount) external {
    if (amount == 0) revert SuperDCAGauge__ZeroAmount();
    if (amount <= keeperDeposit) revert SuperDCAGauge__InsufficientBalance();

    address oldKeeper = keeper;
    uint256 oldDeposit = keeperDeposit;

    // Enforce meaningful outbidding
    require(amount > oldDeposit + minimumRequired, "Not enough amount added");

    IERC20(superDCAToken).transferFrom(msg.sender, address(this), amount);

    if (oldKeeper != address(0) && oldDeposit > 0) {
        IERC20(superDCAToken).transfer(oldKeeper, oldDeposit);
    }

    keeper = msg.sender;
    keeperDeposit = amount;

    emit KeeperChanged(oldKeeper, msg.sender, amount);
}
```

Recommended policy for `minimumRequired`:
- Fixed minimum (e.g. `1e18` if 18 decimals) **or**
- Percentage-based increment (e.g. `oldDeposit * 1%`) with a floor, to scale with deposit size.

---

## Appendix — Notes & Assumptions
- This report focuses on economic / accounting edge cases and incentive attacks.
- No PoCs were included; findings are based on control flow and index accounting behavior described above.
- The first finding assumes a realistic ability to time `stake/unstake` relative to gauge hook-triggered accrual calls (e.g., via MEV/front-running).

