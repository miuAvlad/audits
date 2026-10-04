 cd /workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi

cp my-audit/pocs/OraclePositiveRebaseAsyncExitMainnetForkPoC.t.sol test/

MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/2o5N9kkjEP7R7ZQwunJ60nqZz-q4R1PK" forge test \
  --match-contract OraclePositiveRebaseAsyncExitMainnetForkPoC \
  --match-test test_currentMainnet_24HourFivePercentAprReturnsCapitalAndPositiveNativeEthProfit \
  -vv


  To understand the bug, focus on five connected flows. Validator creation and most external integrations are not necessary.

## 1. eETH share accounting

This is the foundation.

An account’s balance is derived from:

```text
eETH balance =
    accountShares × totalPooledEther / totalShares
```

Important functions:

```text
EETH.balanceOf()
LiquidityPool.amountForShare()
LiquidityPool.sharesForAmount()
LiquidityPool.getTotalPooledEther()
```

Core principle:

```text
Increasing totalPooledEther without increasing totalShares
→ increases every existing eETH balance
```

Relevant files:

- [EETH.sol](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/EETH.sol)
- [LiquidityPool.sol](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/LiquidityPool.sol)

## 2. Permissionless deposit and share minting

The attacker enters through this flow:

```text
attacker
  → LiquidityPool.deposit{value: amount}()
  → deposit(address(0))
  → _deposit(attacker, amount, 0)
  → _sharesForDepositAmount(amount) 
  → EETH.mintShares(attacker, shares)
```

Share calculation:

```solidity
uint256 totalPooledEther =
    getTotalPooledEther() - depositAmount; @note

shares =
    depositAmount * eETH.totalShares()
    / totalPooledEther;
```

The deposit is priced using the currently recorded TVL. A pending oracle reward has not yet been added, so the attacker receives shares at the pre-rebase rate.

Relevant code:

- [LiquidityPool.deposit()](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/LiquidityPool.sol:179)
- [LiquidityPool._deposit()](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/LiquidityPool.sol:521)
- [LiquidityPool._sharesForDepositAmount()](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/LiquidityPool.sol:533)

## 3. Oracle report lifecycle

This establishes when the rewards were earned and when their value becomes public.

```text
oracle members
  → EtherFiOracle.submitReport(report)
  → verifyReport(report)
  → report receives quorum
  → _publishReport(report, hash)
  → ReportPublished emitted
```

The report contains:

```text
refSlotFrom
refSlotTo
accruedRewards
protocolFees
```

`accruedRewards` corresponds to the historical reference interval ending at `refSlotTo`.

After consensus:

- the report is public;
- the reward amount is fixed;
- another report cannot replace it normally;
- execution is prohibited during the configured waiting period.

Relevant code:

- [EtherFiOracle.submitReport()](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/EtherFiOracle.sol:72)
- [EtherFiOracle.verifyReport()](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/EtherFiOracle.sol:130)
- [EtherFiOracle._publishReport()](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/EtherFiOracle.sol:168)

## 4. Report execution and positive rebase

This is where the historical reward is assigned to the live share supply.

```text
authorized executor
  → EtherFiAdmin.executeTasks(report)
  → _handleAccruedRewards(report)
  → APR sanity check
  → MembershipManager.rebase(accruedRewards)
  → LiquidityPool.rebase(accruedRewards)
```

The final operation is:

```solidity
totalValueOutOfLp =
    uint128(int128(totalValueOutOfLp) + accruedRewards);
```

`totalShares` is not snapshotted or changed. Consequently, shares minted after consensus participate in the historical reward.

Relevant code:

- [EtherFiAdmin.executeTasks()](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/EtherFiAdmin.sol:179)
- [EtherFiAdmin._handleAccruedRewards()](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/EtherFiAdmin.sol:237)
- [MembershipManager.rebase()](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/MembershipManager.sol:261)
- [LiquidityPool.rebase()](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/LiquidityPool.sol:440)

The vulnerable transition is:

```text
Report describes historical rewards R
              ↓
Report reaches consensus
              ↓
Attacker deposits and mints new shares
              ↓
executeTasks() adds R to totalPooledEther
              ↓
New attacker shares receive part of R
```

## 5. Asynchronous withdrawal

This demonstrates that the captured balance can become native ETH.

### Request creation

```text
attacker
  → EETH.approve(LiquidityPool, amount)
  → LiquidityPool.requestWithdraw(attacker, amount)
  → EETH.transferFrom(attacker, WithdrawRequestNFT, amount)
  → WithdrawRequestNFT.requestWithdraw(...)
  → withdrawal NFT minted
```

Relevant code:

- [LiquidityPool.requestWithdraw()](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/LiquidityPool.sol:250)
- [WithdrawRequestNFT.requestWithdraw()](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/WithdrawRequestNFT.sol:109)

### Oracle finalization

A later normal report includes the withdrawal request:

```text
EtherFiAdmin.executeTasks(nextReport)
  → _handleWithdrawals(nextReport)
  → WithdrawRequestNFT.finalizeRequests(requestId)
  → LiquidityPool.addEthAmountLockedForWithdrawal(amount)
```

### Claim

```text
attacker
  → WithdrawRequestNFT.claimWithdraw(tokenId)
  → _claimWithdraw(tokenId, attacker)
  → LiquidityPool.withdraw(attacker, amount)
  → EETH.burnShares(WithdrawRequestNFT, shares)
  → native ETH transferred to attacker
```

Relevant code:

- [EtherFiAdmin._handleWithdrawals()](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/EtherFiAdmin.sol:287)
- [WithdrawRequestNFT.claimWithdraw()](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/WithdrawRequestNFT.sol:138)
- [LiquidityPool.withdraw()](/workspaces/web3-dev-containers/foundry/second_setup/projects/etherfi/src/LiquidityPool.sol:213)

## Complete bug flow

```text
Validators/restaking positions earn rewards
                    ↓
Oracle calculates historical accruedRewards
                    ↓
Report reaches consensus and becomes public
                    ↓
Mandatory 10-minute execution delay
                    ↓
Attacker calls LiquidityPool.deposit()
                    ↓
Attacker receives shares at pre-report TVL
                    ↓
Normal executor calls executeTasks()
                    ↓
LiquidityPool.rebase() adds historical rewards
                    ↓
Attacker’s newly minted shares increase in value
                    ↓
Attacker requests withdrawal
                    ↓
Later reports finalize the request
                    ↓
Attacker claims native ETH
```

The essential comparison is:

```text
Reward measurement cutoff: report.refSlotTo
Reward ownership cutoff:    executeTasks() block
```

The vulnerability exists because those two cutoffs are different and deposits remain open between them.



@audit
in oracol am:
`return slotEpoch + 2 < currEpoch;`
dar nu pot fi sigur ca beacon chainul a terminat cu adevarat 
Contractul nu pare să consulte direct un finalized checkpoint. El deduce finalitatea din vechimea epoch-ului.
Asta este o presupunere arhitecturală importantă.

pot fi generate gresit rewardurile pe un slot sau pot fi blocate rewardurile pe un slot din cauza asta?

Aș prioritiza următoarele:
Finalitatea este aproximată prin vechime, nu verificată prin finalized checkpoint.
Maparea refSlotTo → refBlockTo este complet dependentă de mecanismul off-chain.
Missed slots pot cauza off-by-one și alegerea greșită a block range-ului.
reportStartSlot trebuie verificat dacă este aliniat la epoch.
Epoch-boundary semantics trebuie definite exact pentru rewards.
Raportul trebuie generat din finalized, non-optimistic Beacon state.
Rapoartele care traversează un consensus fork trebuie tratate explicit.
Finality delays pot mări foarte mult perioada și valoarea unui raport.
Withdrawals Beacon trebuie corelate fără double counting cu ETH-ul primit pe EL.
Committee diversity trebuie să reducă common-mode client/API failures.