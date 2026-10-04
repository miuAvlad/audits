- probleme cu salt-ul ownershipul lp-ilor? poate cu binurile
- extensii optionale pot bloca chestii
- tick-uri, tranzitii, dos la nivel de gas sau la nivel de optimizari daca au
- multihop swap
- 6 decimale pentru accounting intern/bin-uri? + posibile probleme pe alocare de biti?
- staleness
- 2 metode de add liquidity?
- 2 metode de swap
- rounding care duce la probleme aici? 
    ```midPriceX64 = Math.sqrt(bidPriceX64 * askPriceX64);
    baseFeeX64 = askPriceX64 * ONE_X64 / midPriceX64 - ONE_X64; 
    ```
- ce se intampla cu bin-urile daca nu sunt initializate?

- am nevoie de niste fuzzing tests
- ce se intampla daca am provide lp de doua ori in acelasi bin ?
- reentrancy view pe extensii?(impart aceeasi extensie) pool 1 call -> hook attacker -> pool 2 call -> extensie -> extensie
- pare ca in create pool cand am peste 18 decimale scale factorul e stricat‼️
- createpool nu verifica daca poolul creat exista ‼️
- collect pool fees nu verifica daca poolul e creat sau nu de el ‼️
- Poate creatorul providerului să seteze marginStep la o valoare care face update-urile de margin prea permisive sau blochează providerul?
- Update invalid mai nou poate suprascrie un preț valid vechi (pyth related)  
- feedId este uint32 în update, dar provider factory primește bytes32 (pyth related)
- expectedProperties poate conține duplicate și brichează deployment-ul 
- Fixed PYTH_VERIFICATION_FEE = 1 wei poate rupe update path-ul
- Un feed problematic poate face întreg batch-ul să revert-uiască✅
- routerul nu are pricelimit✅
- daca ceva ramane in router poate fe sweeped de oricine ✅
- Mai interesant este dacă pot exista bin-uri cu: 0 < totalShares < minimalMintableLiquidity✅
- extensia si pool-ul folosesc mid diferit, una foloseste media geometrica alta foloseste media aritmetica ✅
- in router sunt buguri de genul se trimit bani catre router si trebuia sa fie trimisi catre user sau se da bypass la allowlist din cauza ca sender e router sau chestii de genul? ✅
- folosesc 2 mecanisme de timestamp diferit care ar putea duce la probleme intre extensii? sau pot sa schimb pretul primit de oracol mid swap-uri/actiuni (ma refer la pyth aici, incercand sa trimit) 
- poate un pool admin sa scoata un profit din swap-uri modificand ceva fee-uri? dar nu profit doar din a plati mai putine fee-uri ci ceva din tranzitia asta, posibil adaugat si alte path-uri pe aici ca acel bin traversal



Next best goal: **swap flow + oracle flow together**.



**Findings**
1. **Medium candidate: confidence spreads are scaled 100x too low.** Oracle contracts return whole bps, but `PriceProvider` divides `spread * confidenceParam` by `1e10` instead of `1e8`. At the operational `300_000` setting, a 500 bps spread becomes roughly 150 bps rather than the documented 30x multiplier. This affects `PriceProvider`, both L2/protected variants, but not the clamped Anchored provider. See [PriceProvider.sol](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/smart-contracts-poc/contracts/PriceProvider.sol:137).

   With two fresh feeds at 100 and 104 whose 500 bps bands overlap, the real two-pool route turns `100` tokens into `100.719335540287460221`, extracting **71 bps from LPs after fees and bin traversal**. This supports Medium, although the README’s trusted-provider configuration language remains a judging risk.

2. **Low: repeated-pool routes break quoter assumptions.** Exact-input quotes differ from execution because each quoted hop rolls pool state back. Exact-output is quoted successfully, but execution reenters the same active pool and reverts. This causes failed transactions or unreliable quotes, not direct loss.

3. **Informational: splitting swaps creates microscopic rounding advantages.** Exact-output splitting can occasionally reduce input slightly, but 2,001 runs in both directions kept value and cursor differences below `1e-8`. Gas costs dominate this effect.

**Other Results**
Partial fills cannot persist through multihop routes: exact input verifies every hop consumed the requested input, exact output verifies every intermediate debt exactly, and any failure reverts all nested transfers and state.

Upward and downward bin transitions update `curBinIdx`, `curPosInBin`, distance, and boundary prices consistently. Each pool reads its provider once per swap. Exact-input oracle reads happen forward; exact-output reads happen final-to-first. I found no exploitable ordering issue with the standard providers.

The router has aggregate slippage protection only, with open per-hop limits. That is explicitly documented and does not independently bypass the final minimum-output or maximum-input check.

The complete Medium write-up is in [price-provider-confidence-unit-compression-multihop-arbitrage.md](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/my-audit/price-provider-confidence-unit-compression-multihop-arbitrage.md:1).

PoCs are in [provider PoC](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/smart-contracts-poc/test/PriceProviderSpreadUnitsMultiFeedPoC.t.sol:73), [router PoC](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/metric-periphery/test/MetricOmmRouterMultiFeedSpreadPoC.t.sol:43), [repeated-pool tests](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/metric-periphery/test/MetricOmmRouterRepeatedPool.audit.t.sol:11), and [bin-split fuzzing](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/metric-core/test/MetricOmmPool.splitBoundary.audit.t.sol:50). All tests passed.


**Confirmed Finding**
**Medium candidate: fixed-width metrics can silently disable the stop-loss.**

At [OracleValueStopLossExtension.sol:246](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/metric-periphery/contracts/extensions/OracleValueStopLossExtension.sol:246), the effective representation is approximately:

```solidity
storedMetric = min(floor(value * 1e6 / totalShares), type(uint104).max);
```

This fails in both directions:

- **Precision loss:** A valuable bin with many shares can produce `metric = 0`. Then `_applyWatermark(0, 0, ...)` never reports a breach.
- **Saturation:** Two true metrics above `uint104.max` both clamp to the same value, hiding an arbitrarily large relative drawdown.

The stronger PoC uses ordinary fresh oracle prices:

- Bin holds one million token0.
- Oracle moves correctly from `1.0` to `0.1`.
- True metric falls by approximately 90%.
- Configured stop-loss permits only 5%.
- Production watermark remains `0`.
- A permissionless swap successfully removes approximately 90% of the bin’s token0.

This is not dust: the small per-share value comes only from the arbitrary share denomination. The factory permits the density because it only checks nonzero values and the `uint128` upper bound at [MetricOmmPoolFactory.sol:166](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/metric-core/contracts/MetricOmmPoolFactory.sol:166).

No stale/incorrect oracle or attacker role is required. It does require a valid but nondefault share-density configuration and a price movement, so **Medium is more defensible than High**. The main judging risk is whether the share density is characterized as operator misconfiguration, although no compatible range is documented or enforced.

PoCs:

- [OracleValueStopLossPrecision.audit.t.sol:39](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/metric-periphery/test/extensions/OracleValueStopLossPrecision.audit.t.sol:39)
- [OracleValueStopLossClamp.audit.t.sol:44](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/metric-periphery/test/extensions/OracleValueStopLossClamp.audit.t.sol:44)

Both tests pass. The proper fix is a share-denomination-independent metric representation. At minimum, nonempty bins producing `0` or exceeding `uint104.max` should fail closed instead of silently truncating.


**2 of the 7 findings in `my-audit` are solid enough to submit now.**

1. **Submit first:** [PriceProvider confidence scaling](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/my-audit/price-provider-confidence-unit-compression-multihop-arbitrage.md)  
   Strong Medium. Clear unit contradiction plus real two-pool/router profit of `71 bps`.

2. **Submit second:** [Stop-loss metric saturation/precision bypass](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/my-audit/oracle-stop-loss-metric-clamp-bypass.md)  
   Medium with configuration risk, but still defensible. Present saturation and rounding-to-zero as one fixed-width metric failure.

**Borderline, not ready:**

- [Synthetic ratio spread underestimation](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/my-audit/anchored-synthetic-ratio-spread-underestimation.md): mathematically real, but the PoC mainly proves reduced expected spread income relative to a hypothetical conservative provider, not indisputable fair-value loss.
- [Shifted stop-loss midpoint](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/my-audit/oracle-stop-loss-shifted-midpoint-bypass.md): requires proving the stop-loss must value assets at the raw midpoint. A previous audit already discussed the arithmetic/geometric discrepancy, creating duplicate and intent risk. [Collaborative audit report](https://ams3.digitaloceanspaces.com/sherlock-files/additional_resources/2026-07-06_Metric-Collaborative_Audit_Report.pdf)

**Do not submit:**

- Boundary-bin DoS: too close to intended stop-loss behavior and previously known zero-delta cursor movement.
- `uint104` high-decimal bin DoS: technically strong, but the prior audit already acknowledged unsupported high-decimal scaling as M-4, likely making this a known-root-cause duplicate.
- Pusher revocation replay: explicitly documented in the prior Zellic report as replayable after revocation. [Zellic report](https://ams3.digitaloceanspaces.com/sherlock-files/additional_resources/Metric%20OMM%20-%20Zellic%20Audit%20Report%20Draft.pdf)

I reran the four principal PoCs for the two sendable findings: all passed.





