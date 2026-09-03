Critical
Protocol permanent insolvency

Critical
Direct theft of any user funds, whether at-rest or in-motion, other than unclaimed yield

Critical
Direct theft of any user NFTs, whether at-rest or in-motion, other than unclaimed royalties

Critical
Permanent freezing of funds

Critical
Unauthorized minting of NFTs

Critical
Protocol insolvency

High
Manipulation of on-chain governance voting result deviating from voted outcome and resulting in a direct change from intended effect of original results

High
Theft of material unclaimed yield

High
Permanent freezing of material unclaimed yield

High
Permanent freezing of material unclaimed royalties

High
Protocol insolvency that can be fixed

Medium
Temporary freezing of material funds

Medium
Smart contract unable to operate due to lack of token funds

Low
Block stuffing that results in material freezing or loss of funds or significantly impedes the operation of the protocol

Low
Griefing (e.g. no profit motive for an attacker, but damage to the users or the protocol) that results in material freezing or loss of funds or significantly impedes operation of the protocol

Low
Theft of gas

Low
Unbounded gas consumption


| Rank | Fișiere | Likelihood | Motiv |
|---:|---|---:|---|
| 1 | `MembershipManager.sol`, `MembershipNFT.sol`, `GlobalIndexLibrary.sol` | 9.5/10 | Findings Medium încă active, două versiuni contabile |
| 2 | `LiquidityPool.sol` | 9/10 | Accounting central, locks, rebase, staking outflows |
| 3 | `EtherFiNodesManager.sol`, `EtherFiNode.sol` | 8.5/10 | Arbitrary forwarding și integrare EigenLayer |
| 4 | `EtherFiAdmin.sol`, `EtherFiOracle.sol` | 8/10 | Oracle reports, TVL și lock-uri bazate pe input off-chain |
| 5 | `PriorityWithdrawalQueue.sol` | 7.5/10 | Logică nouă și complexă; majoritatea finding-urilor au fost fixate |
| 6 | `WithdrawRequestNFT.sol` | 7.5/10 | Negative rebase, fee și accounting rezidual |
| 7 | `EtherFiRedemptionManager.sol` | 7/10 | Fee/share rounding, rate limits și lock underflow |
| 8 | `StakingManager.sol` | 6.5/10 | Pubkey lifecycle și front-run credentials |
| 9 | `Liquifier.sol`, `EtherFiRestaker.sol` | 6/10 | Lido/EigenLayer accounting și configurare externă |
| 10 | `EETH.sol`, `WeETH.sol`, adaptoarele | 5/10 | Rounding și dust, dar suprafață mai simplă |


| Rank | Fișiere | Șansă bounty |
|---|---|---:|
| 1 | `LiquidityPool`, cele trei withdrawal contracts | 9/10 |
| 2 | `StakingManager`, `EtherFiNodesManager`, `EtherFiNode` | 8.5/10 |
| 3 | `EtherFiAdmin`, `EtherFiOracle` | 8/10 |
| 4 | `Liquifier`, `EtherFiRestaker` | 7/10 |
| 5 | `RoleRegistry`, `EtherFiRateLimiter` | 6.5/10 |
| 6 | `EETH`, `WeETH`, adaptoare | 5.5/10 |
| 7 | `AuctionManager`, `NodeOperatorManager` | 5/10 |
| 8 | `MembershipManager`, `MembershipNFT`, `GlobalIndexLibrary` | 1/10 |


| External system | Purpose | Main integration files |
|---|---|---|
| Ethereum Beacon Deposit Contract | Creates and tops up validators | `StakingManager.sol` |
| Beacon Chain / Pectra | Validator balances, `0x02` withdrawal credentials, EIP-7002 exits, EIP-7251 consolidations | `StakingManager`, `EtherFiNodesManager`, `EtherFiNode` |
| EigenLayer | Native restaking, EigenPods, delegation, strategies, queued withdrawals, proofs and rewards | `EtherFiNode`, `EtherFiNodesManager`, `EtherFiRestaker` |
| Lido | Accepts stETH/wstETH deposits, pays instant redemptions in stETH and uses Lido’s withdrawal queue | `Liquifier`, `DepositAdapter`, `EtherFiRestaker`, `EtherFiRedemptionManager` |
| Curve | Quotes stETH/ETH, cbETH/ETH and wbETH/ETH market values | `Liquifier` |
| Coinbase cbETH | Accepted LST; uses `exchangeRate()` and Curve pricing | `Liquifier` |
| Binance WBETH | Accepted LST; uses `exchangeRate()` and Curve pricing | `Liquifier` |
| WETH | Adapter unwraps WETH into ETH before staking | `DepositAdapter` |
| External LayerZero-style tellers/vaults | Deposits into whitelisted external vaults through `LiquidRefer` | `LiquidRefer` |
| Ether.fi AVS operator infrastructure | Controls AVS/restaking operations | Separate Ether.fi repository |
| KING Protocol | Distribution of restaking rewards | Separate repository |