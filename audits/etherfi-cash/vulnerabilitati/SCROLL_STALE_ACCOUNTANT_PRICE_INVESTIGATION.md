# Scroll V1 PriceProvider accepts indefinitely stale Veda accountant rates

## Conclusion

EtherFi Cash's deployed Scroll `PriceProvider` has a confirmed stale-rate
integration gap. The four Veda accountant integrations return a stored exchange
rate, but neither the accountants nor EtherFi's generic-oracle branch reject the
rate based on `lastUpdateTimestamp`. A Scroll fork test proves that `getRate()`,
`getRateSafe()`, `PriceProvider.price()`, and DebtManager collateral valuation
continue succeeding after the configured `maxStaleness` has elapsed.

This is not currently a demonstrated profitable exploit. An unprivileged actor
cannot stop or manipulate the accountant updates, the observed rates were fresh,
the updater has operated approximately daily, and Scroll's DebtManager currently
has no borrow-token liquidity. The liquidUSD lending market is also dormant.

**Classification:** confirmed stale-oracle acceptance and security-sensitive
consumption, but presently a **configuration/design risk**. Medium severity is
defensible only if oracle-automation failure followed by opportunistic exploitation
is accepted by the threat model. High severity requires an additional PoC showing
a realistic outage, material rate divergence, available liquidity, and extractable
bad debt.

## Deployed contracts and configuration

The in-scope Scroll proxy and implementation are:

```text
PriceProvider proxy:          0x44dd2372FE7B97C4B4D6a7d4DeCf72466485BAcB
ERC-1967 implementation:      0x700a0b9bffc73e4e925e1cea0d4bf523f36369f6
DebtManager:                  0x0078C5a459132e279056B2371fE8A8eC973A9553
```

The implementation is the V1 `PriceProvider`, not `PriceProviderV2`. The address
is also encoded in [`output/UpgradeMainnet.json`](../output/UpgradeMainnet.json).

| Asset | Token/vault | Teller | Accountant | DebtManager role |
|---|---|---|---|---|
| liquidETH | `0xf0bb20865277aBd641a307eCe5Ee04E79073416C` | `0x9AA79C84b79816ab920bBcE20f8f74557B514734` | `0x0d05D94a5F1E76C18fbeB7A13d17C8a314088198` | Collateral only |
| liquidBTC | `0x5f46d540b6eD704C3c8789105F30E075AA900726` | `0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353` | `0xEa23aC6D7D11f6b181d6B98174D334478ADAe6b0` | Collateral only |
| liquidUSD | `0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C` | `0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387` | `0xc315D6e14DDCDC7407784e2Caf815d131Bc1D3E7` | Collateral and borrow token |
| eUSD | `0x939778D83b46B456224A33Fb59630B11DEC56663` | `0xCc9A7620D0358a521A068B444846E3D5DebEa8fA` | `0xEB440B36f61Bf62E0C54C622944545f159C3B790` | Collateral only |

The addresses agree with EtherFi's official documentation for the
[ETH vault](https://etherfi.gitbook.io/etherfi/liquid/eth-yield-vault),
[BTC vault](https://etherfi.gitbook.io/etherfi/liquid/liquid-btc-yield-vault),
[USD vault](https://etherfi.gitbook.io/etherfi/liquid/liquid-usd-vault), and
[eUSD](https://etherfi.gitbook.io/etherfi/staking/eusd).

All four live `tokenConfig()` values use:

```text
isChainlinkType          = false
priceFunctionCalldata   = 0x679aefce  // getRate()
dataType                 = Uint256
maxStaleness             = 15,552,000 seconds (180 days)
```

The original Scroll script uses two days at
[`UpgradeMainnet.s.sol`](../scripts/gnosis-txs/UpgradeMainnet.s.sol), but that is
not the live configuration. Commit `968a88987ea902be68844e0a2defae0c47ab5cb5`
later described 180 days as the "agreed target" and generated the transaction
that produced the current configuration.

The four accountant deployments are direct contracts, not proxies. Their
verified source matches `AccountantWithRateProviders`, compiled with Solidity
0.8.21. They all have an 8,016-byte runtime; liquidETH, liquidUSD, and eUSD also
share the same metadata hash. liquidBTC uses the same contract interface and
behavior but has a different metadata hash.

## Root cause and exact call path

The V1 Chainlink branch checks age in
[`PriceProvider.sol`](../src/oracle/PriceProvider.sol):

```solidity
if (config.isChainlinkType) {
    (, int256 priceInt256, , uint256 updatedAt, ) =
        IAggregatorV3(config.oracle).latestRoundData();

    if (block.timestamp > updatedAt + config.maxStaleness)
        revert OraclePriceTooOld();
}
```

The generic branch instead performs only:

```solidity
(bool success, bytes memory data) =
    address(config.oracle).staticcall(config.priceFunctionCalldata);

if (!success) revert PriceOracleFailed();
tokenPrice = abi.decode(data, (uint256));
```

It never reads `config.maxStaleness` or the accountant state.

The deployed accountant implementation stores both an exchange rate and update
timestamp, but its getters are:

```solidity
function getRate() public view returns (uint256 rate) {
    rate = accountantState.exchangeRate;
}

function getRateSafe() external view returns (uint256 rate) {
    if (accountantState.isPaused)
        revert AccountantWithRateProviders__Paused();

    rate = getRate();
}
```

Neither getter checks `lastUpdateTimestamp`. `getRateSafe()` checks only the
pause flag. Inactivity does not automatically pause the accountant. See the
[official Veda implementation](https://github.com/Se7en-Seas/boring-vault/blob/main/src/base/Roles/AccountantWithRateProviders.sol)
and [Veda accountant documentation](https://docs.veda.tech/architecture-and-flow-of-funds/accountant).

The resulting path is:

```text
DebtManager
  -> PriceProvider.price(asset)
    -> AccountantWithRateProviders.getRate()
      -> stored exchangeRate, without age or pause validation
```

Therefore the following state is possible:

```text
last accountant update = T0
current time > T0 + configured maxStaleness
getRate() returns the rate stored at T0
PriceProvider.price(token) succeeds
DebtManager consumes the unchanged rate
```

The configured 180-day value has no effect whatsoever for these accountant
calls.

## Update mechanism and attacker control

Rates are updated through:

```solidity
updateExchangeRate(uint96 newExchangeRate)
```

The rate is calculated off-chain and submitted on-chain by an authorized
account, as documented by Veda. The deployed authorization state is:

```text
updateExchangeRate selector:  0x3458113d
public capability:            false
required role mask:           0x800 (role 11)
authorized updater Safe:      0x560441fA211AEd16Dd49f70c226380c9D4875225
updater threshold:            2 of 4
```

The accountant owners are zero and each delegates authorization to a
`RolesAuthority`. An arbitrary address is not authorized to call
`updateExchangeRate`, `pause`, or `unpause`.

The latest observed update was transaction
[`0xe1787062...08e4`](https://scrollscan.com/tx/0xe17870627180c5422e41f23cceab7baba7b4ec75a223373bb88c109fb02708e4),
which updated all four accountants in one Safe batch.

At the inspected Scroll snapshot:

```text
block timestamp:                    1786370954
all accountant lastUpdateTimestamp: 1786319010
rate age:                           51,944 seconds (~14.4 hours)
isPaused:                           false
minimumUpdateDelayInSeconds:        21,600 seconds (6 hours)
```

The six-hour value is a minimum spacing between updates, not a maximum age.
The last 50 updates had a maximum observed gap of approximately 30.5 hours,
consistent with routine daily automation.

No unprivileged method was found to stop, delay, update, or pause the
accountants. An attacker can only observe an independently occurring outage or
abnormal state and then try to trade against the stale value.

## Downstream security impact

DebtManager performs the two core conversions at
[`DebtManagerCore.sol`](../src/debt-manager/DebtManagerCore.sol) and
[`DebtManagerStorageContract.sol`](../src/debt-manager/DebtManagerStorageContract.sol):

```solidity
tokenToUsd = tokenAmount * price(token) / 10 ** tokenDecimals;
usdToToken = usdAmount * 10 ** tokenDecimals / price(token);
```

The stale rate reaches:

- collateral valuation;
- LTV borrowing limits;
- account health enforcement;
- liquidation eligibility;
- collateral amounts seized during liquidation;
- borrow and repayment accounting;
- supplier share accounting for borrow tokens;
- Cash credit/debit and repayment conversions.

The live collateral parameters are:

| Asset | LTV | Liquidation threshold | Liquidation bonus |
|---|---:|---:|---:|
| liquidETH | 50% | 70% | 5% |
| liquidBTC | 50% | 70% | 5% |
| liquidUSD | 80% | 90% | 2% |
| eUSD | 80% | 90% | 2% |

### Stale rate overvalues collateral

If a vault suffers a loss while the old rate remains high:

- `getMaxBorrowAmount()` grants excessive borrowing power;
- `ensureHealth()` accepts economically unhealthy debt;
- `liquidatable()` delays liquidation;
- a user can potentially acquire discounted shares and use the stale NAV as
  collateral.

At maximum LTV, immediate economic insolvency requires the reported price to be
more than 2x fair value for liquidETH/liquidBTC or more than 1.25x fair value for
liquidUSD/eUSD, before fees and other collateral are considered.

For example, the observed liquidUSD rate was `1.171348` USD and its LTV was 80%:

```text
maximum reported borrowing power per liquidUSD = 1.171348 * 80%
                                                = 0.9370784 USD
```

If realizable value falls below approximately $0.937 while the reported rate
remains unchanged, stale valuation can support undercollateralized borrowing.

### Stale rate undervalues collateral

If the vault rate should increase but remains stale-low:

- borrowing capacity is understated;
- debt interest can make an economically healthy account appear liquidatable;
- liquidation converts USD debt into too many collateral shares because it
  divides by the stale-low price;
- an untrusted liquidator can capture more economically valuable collateral than
  intended.

An increasing fair value alone does not change the reported health factor.
Another factor, normally debt interest, must push the account over the stale
liquidation threshold.

### liquidUSD as a borrow token

liquidUSD is registered as a borrow token, so its rate can theoretically affect:

- USD debt recorded when liquidUSD is borrowed;
- token amounts used to repay liquidUSD debt;
- liquidation repayment amounts;
- `_getTotalBorrowTokenAmount()` and supplier share accounting;
- Cash credit/debit amount conversion.

These paths are presently dormant on Scroll. At the observation block:

```text
liquidUSD totalNormalizedBorrowingAmount = 0
liquidUSD totalSharesOfBorrowTokens      = 0
DebtManager liquidUSD balance            = 0
liquidUSD minShares                       = type(uint128).max
all supported borrow-token balances      = 0
```

An ordinary initial supplier cannot satisfy `type(uint128).max` minimum shares,
and new borrowing fails without DebtManager liquidity. Consequently, current
borrow/repayment/LP impact cannot support an active exploit claim.

### Asset-specific caveats

- liquidETH and liquidBTC multiply the accountant rate by an independent
  ETH/USD or BTC/USD Chainlink feed. That feed's timestamp is checked, but the
  accountant timestamp is not. A live chain can therefore have a fresh base
  feed and indefinitely stale accountant leg.
- At the inspected block, `price(liquidBTC)` already reverted because its BTC/USD
  Chainlink leg was stale. liquidBTC currently fails closed rather than exposing
  a usable stale accountant valuation.
- liquidUSD and eUSD are direct-USD paths and provide the cleanest stale-rate
  demonstration.
- The eUSD accountant's base asset is USDe, while EtherFi treats the numeric
  accountant rate as USD. A USDe depeg is a separate integration assumption.

## Fork proof of concept

The focused PoC is
[`test/price-provider/PriceProviderV1ScrollStaleness.t.sol`](../test/price-provider/PriceProviderV1ScrollStaleness.t.sol).
It does not use OpenKritt or `audit-harness`.

Run:

```bash
forge test \
  --match-path test/price-provider/PriceProviderV1ScrollStaleness.t.sol \
  -vvv
```

Observed result:

```text
[PASS] test_EUsdRateAndCollateralValueRemainReadablePastConfiguredMaxStaleness()
[PASS] test_LiquidUsdRateAndCollateralValueRemainReadablePastConfiguredMaxStaleness()
2 passed; 0 failed
```

For each direct-USD token, the test:

1. Reads the live config, exchange rate, pause state, and update timestamp.
2. Records `getRate()`, `getRateSafe()`, `PriceProvider.price()`, and DebtManager
   collateral valuation.
3. Warps to `lastUpdateTimestamp + maxStaleness + 1` without an update.
4. Proves both accountant getters still succeed.
5. Proves `PriceProvider.price()` returns the same value.
6. Proves DebtManager still assigns the same USD collateral value.

This conclusively proves stale acceptance and downstream propagation. It does
not prove that the underlying fair value diverged or that funds can currently be
extracted.

## V1 versus V2

[`PriceProviderV2.sol`](../src/oracle/PriceProviderV2.sol) does not fix generic
oracle freshness. Its timestamp validation remains inside the Chainlink branch.
For generic `uint256` oracles it adds only a zero-value check.

The V2 tests explicitly state that `maxStaleness == 0` is acceptable for a
non-Chainlink oracle at
[`PriceProviderV2.t.sol`](../test/price-provider/PriceProviderV2.t.sol):

```solidity
// maxStaleness = 0 is fine for non-Chainlink oracles
```

This supports an expected design in which generic integrations must implement
their own freshness checks. The deployed Cash integration points directly to
`getRate()`, which does not do so.

Using `getRateSafe()` alone would reject paused accountants but would not solve
inactivity-based staleness. A complete fix requires an accountant-specific
adapter or direct `accountantState()` query that rejects:

```text
isPaused == true
exchangeRate == 0
block.timestamp > lastUpdateTimestamp + configuredMaximumAge
```

## Documentation, audit, and known-issue search

Veda documents that exchange rates are calculated off-chain, submitted by an
`UPDATE_EXCHANGE_RATE_ROLE`, and generally updated daily. The documentation does
not provide a maximum-age guarantee or automatic inactivity pause.

No matching stale-accountant issue was found in the searched EtherFi Certora and
public audit material. The Certora PriceProvider model abstracts raw prices and
does not model accountant update timestamps. The closest disclosed PriceProvider
issue concerned stable-price handling, not accountant freshness.

There is mixed evidence concerning sponsor intent:

- The live 180-day configuration was deliberately described as an "agreed
  target" in commit `968a889`.
- V2 explicitly allows zero `maxStaleness` for generic oracles.
- Cash nevertheless stores nonzero `maxStaleness` values for these integrations
  and consumes a timestamped accountant without checking its timestamp or pause
  flag.
- Other Veda/EtherFi integrations use freshness-aware adapters, showing that this
  check belongs in an adapter when generic calldata returns only a price.

The issue was not found as an explicit public known issue, but the intentional
180-day configuration and V2 test provide strong design-risk/invalidation
arguments.

## Attacker analysis

An untrusted attacker cannot:

- call `updateExchangeRate()`;
- stop the authorized Safe from submitting updates;
- pause or unpause an accountant;
- independently change the stored rate.

An attacker can:

- monitor `lastUpdateTimestamp` and update events;
- observe when updates have stopped;
- observe a market/NAV divergence;
- acquire collateral and use normal Cash flows if borrowing liquidity and account
  limits permit;
- call public liquidation when a stale-low valuation marks another account
  liquidatable.

No permissionless method of deliberately creating the stale condition was found.
Front-running or back-running an update can only exploit an already existing
price discrepancy and is further constrained by Scroll ordering and EtherFi's
wallet-mediated spending path.

## Severity and invalidation reasons

### Best severity supported by current evidence

**Low / configuration-design risk.** The stale state is proven, but no present
loss path is active and no attacker can create the prerequisite outage.

### Conditional severity

**Medium** is defensible if the program accepts an independent automation outage
as a reachable prerequisite and a PoC demonstrates an affected user operation.

**High** requires proof of all of the following:

1. A realistic non-malicious update interruption or paused-accountant state.
2. Material divergence between stored rate and economic value.
3. Available sound borrow-token liquidity or a liquidatable victim.
4. An untrusted actor completing excess borrowing, profitable liquidation, or
   another extraction.
5. Material bad debt or another explicitly in-scope impact.

### Likely invalidation arguments

1. No untrusted actor can stop or manipulate the updater.
2. Staleness alone causes no loss without an independent economic divergence.
3. Scroll deliberately accepts a 180-day staleness target.
4. Generic-oracle freshness is intentionally delegated to the integration.
5. Current rates are fresh and routine updates have not approached 180 days.
6. The Scroll DebtManager currently has no borrow-token liquidity.
7. liquidUSD borrowing and LP accounting are dormant.
8. A DEX discount does not necessarily prove incorrect NAV because Veda's
   accountant is the canonical off-chain vault valuation.

## Final verdict

The condition is technically valid and the fork PoC proves that EtherFi Cash
will use an accountant rate older than its configured deadline. It is not a
false positive at the code level.

It is not yet a strong bounty finding. Under the deployed state and trust model,
it is best reported as an oracle-liveness/configuration risk. Elevating it to a
security vulnerability requires a concrete, untrusted profit path during a
realistic stale-rate event rather than merely advancing time on a fork.


