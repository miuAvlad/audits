// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {IPriceProvider} from "../contracts/interfaces/IPriceProvider/IPriceProvider.sol";
import {
  IMetricOmmModifyLiquidityCallback
} from "../contracts/interfaces/callbacks/IMetricOmmModifyLiquidityCallback.sol";
import {IMetricOmmSwapCallback} from "../contracts/interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {LiquidityDelta} from "../contracts/types/PoolOperation.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {PoolExtensions, ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

uint256 constant ECHIDNA_Q64 = 2 ** 64;

contract EchidnaPriceProvider is IPriceProvider {
  uint128 internal bidPrice;
  uint128 internal askPrice;
  address internal token0_;
  address internal token1_;

  function setTokens(address token0__, address token1__) external {
    token0_ = token0__;
    token1_ = token1__;
  }

  function setBidAndAskPrice(uint128 bidPrice_, uint128 askPrice_) external {
    bidPrice = bidPrice_;
    askPrice = askPrice_;
  }

  function getBidAndAskPrice() external view returns (uint128, uint128) {
    return (bidPrice, askPrice);
  }

  function token0() external view returns (address) {
    return token0_;
  }

  function token1() external view returns (address) {
    return token1_;
  }
}

contract EchidnaInspectableMetricOmmPool is MetricOmmPool {
  constructor(
    address factory,
    address admin,
    address adminFeeDestination,
    address token0,
    address token1,
    address priceProvider,
    PoolExtensions memory extensions,
    ExtensionOrders memory extensionOrders,
    uint256 token0ScaleMultiplier,
    uint256 token1ScaleMultiplier,
    uint256 initialScaledToken0PerShareE18,
    uint256 initialScaledToken1PerShareE18,
    uint256 minimalMintableLiquidity,
    uint24 spreadFeeE6,
    int24 initialCurBinDistFromProvidedPriceE6,
    BinState[] memory nonNegativeBinStates,
    BinState[] memory negativeBinStates,
    uint24 notionalFeeE8
  )
    MetricOmmPool(
      factory,
      admin,
      adminFeeDestination,
      token0,
      token1,
      priceProvider,
      extensions,
      extensionOrders,
      true,
      token0ScaleMultiplier,
      token1ScaleMultiplier,
      initialScaledToken0PerShareE18,
      initialScaledToken1PerShareE18,
      minimalMintableLiquidity,
      spreadFeeE6,
      initialCurBinDistFromProvidedPriceE6,
      nonNegativeBinStates,
      negativeBinStates,
      notionalFeeE8
    )
  {}

  function exposedBinTotals() external view returns (uint128 total0Scaled, uint128 total1Scaled) {
    total0Scaled = binTotals.scaledToken0;
    total1Scaled = binTotals.scaledToken1;
  }

  function exposedNotionalFees() external view returns (uint128 fee0Scaled, uint128 fee1Scaled) {
    fee0Scaled = notionalFeeToken0Scaled;
    fee1Scaled = notionalFeeToken1Scaled;
  }

  function exposedSlot0()
    external
    view
    returns (
      uint8 pauseLevel_,
      int8 curBinIdx_,
      uint104 curPosInBin_,
      int24 curBinDistFromProvidedPriceE6_,
      uint24 spreadFeeE6_,
      uint24 notionalFeeE8_
    )
  {
    return (pauseLevel, curBinIdx, curPosInBin, curBinDistFromProvidedPriceE6, spreadFeeE6, notionalFeeE8);
  }

  function exposedBinTotalShares(int8 bin) external view returns (uint256) {
    return _binTotalShares[int256(bin)];
  }

  function exposedPositionShares(address owner, uint80 salt, int8 bin) external view returns (uint256) {
    return _positionBinShares[keccak256(abi.encode(owner, salt, bin))];
  }

  function exposedLowestAndHighestBins() external view returns (int256 lowestBin, int256 highestBin) {
    return (LOWEST_BIN, HIGHEST_BIN);
  }

  function exposedBinLength(int8 bin) external view returns (uint16) {
    return _binStates[int256(bin)].lengthE6;
  }

  function exposedScaleMultipliers() external view returns (uint256 scale0, uint256 scale1) {
    return (TOKEN_0_SCALE_MULTIPLIER, TOKEN_1_SCALE_MULTIPLIER);
  }
}

contract MetricOmmPoolEchidna is IMetricOmmModifyLiquidityCallback, IMetricOmmSwapCallback {
  uint256 internal constant TOKEN0_SCALE = 1e12;
  uint256 internal constant TOKEN1_SCALE = 1;
  uint256 internal constant MINIMAL_MINTABLE_LIQUIDITY = 1_000;
  uint256 internal constant MAX_LIQUIDITY_SHARES = 1e22;
  uint256 internal constant MAX_TOKEN0_SWAP_AMOUNT = 1e10;
  uint256 internal constant MAX_TOKEN1_SWAP_AMOUNT = 1e22;
  uint24 internal constant DEFAULT_SPREAD_FEE_E6 = 10_000;
  uint24 internal constant MAX_SPREAD_FEE_E6 = 200_000;
  uint16 internal constant MAX_BIN_ADDITIONAL_FEE_E6 = 50_000;
  int24 internal constant INITIAL_CUR_BIN_DISTANCE_E6 = -12_347;

  MockERC20 public immutable token0;
  MockERC20 public immutable token1;
  EchidnaPriceProvider public immutable priceProvider;
  EchidnaInspectableMetricOmmPool public immutable pool;

  uint256 public surplusBudget0Scaled;
  uint256 public surplusBudget1Scaled;
  uint256 public feesCollected0Scaled;
  uint256 public feesCollected1Scaled;
  bool public removeAllFailed;

  constructor() {
    token0 = new MockERC20("Echidna USDC", "eUSDC", 6);
    token1 = new MockERC20("Echidna WETH", "eWETH", 18);

    priceProvider = new EchidnaPriceProvider();
    priceProvider.setTokens(address(token0), address(token1));
    priceProvider.setBidAndAskPrice(uint128(ECHIDNA_Q64), uint128(ECHIDNA_Q64 + 1));

    BinState[] memory nonNegativeBinStates = new BinState[](2);
    BinState[] memory negativeBinStates = new BinState[](2);
    nonNegativeBinStates[0] = _emptyBin(997);
    nonNegativeBinStates[1] = _emptyBin(3_001);
    negativeBinStates[0] = _emptyBin(2_003);
    negativeBinStates[1] = _emptyBin(5_009);

    PoolExtensions memory extensions;
    ExtensionOrders memory extensionOrders;
    pool = new EchidnaInspectableMetricOmmPool(
      address(this),
      address(this),
      address(this),
      address(token0),
      address(token1),
      address(priceProvider),
      extensions,
      extensionOrders,
      TOKEN0_SCALE,
      TOKEN1_SCALE,
      1e18,
      1e18,
      MINIMAL_MINTABLE_LIQUIDITY,
      DEFAULT_SPREAD_FEE_E6,
      INITIAL_CUR_BIN_DISTANCE_E6,
      nonNegativeBinStates,
      negativeBinStates,
      0
    );

    token0.mint(address(this), 1_000_000_000_000_000);
    token1.mint(address(this), 1_000_000_000 ether);
  }

  function addLiquidity(uint8 binSeed, uint8 saltSeed, uint96 sharesSeed) external {
    uint256 shares = MINIMAL_MINTABLE_LIQUIDITY + (uint256(sharesSeed) % MAX_LIQUIDITY_SHARES);
    uint80 salt = uint80(saltSeed % 4);
    LiquidityDelta memory delta = _singleLiquidityDelta(_binFromSeed(binSeed), shares);
    (bool solventBefore, uint256 surplus0Before, uint256 surplus1Before) = _currentSurplus();
    if (!solventBefore) return;

    try pool.addLiquidity(address(this), salt, delta, "", "") returns (uint256, uint256) {
      _recordSurplusIncrease(surplus0Before, surplus1Before);
    } catch {}
  }

  function removeLiquidity(uint8 binSeed, uint8 saltSeed, uint8 fractionSeed) external {
    uint80 salt = uint80(saltSeed % 4);
    int8 bin = _binFromSeed(binSeed);
    uint256 currentShares = pool.exposedPositionShares(address(this), salt, bin);
    if (currentShares == 0) return;

    uint256 shares = (currentShares * (uint256(fractionSeed) + 1)) / 256;
    if (shares == 0) shares = 1;
    if (currentShares - shares > 0 && currentShares - shares < MINIMAL_MINTABLE_LIQUIDITY) {
      shares = currentShares;
    }

    LiquidityDelta memory delta = _singleLiquidityDelta(bin, shares);
    (bool solventBefore, uint256 surplus0Before, uint256 surplus1Before) = _currentSurplus();
    if (!solventBefore) return;

    try pool.removeLiquidity(address(this), salt, delta, "") returns (uint256, uint256) {
      _recordSurplusIncrease(surplus0Before, surplus1Before);
    } catch {}
  }

  function removeAllLiquidity(uint8 binSeed, uint8 saltSeed) external {
    uint80 salt = uint80(saltSeed % 4);
    int8 bin = _binFromSeed(binSeed);
    uint256 currentShares = pool.exposedPositionShares(address(this), salt, bin);
    if (currentShares == 0) return;

    LiquidityDelta memory delta = _singleLiquidityDelta(bin, currentShares);
    (bool solventBefore, uint256 surplus0Before, uint256 surplus1Before) = _currentSurplus();
    if (!solventBefore) return;

    try pool.removeLiquidity(address(this), salt, delta, "") returns (uint256, uint256) {
      _recordSurplusIncrease(surplus0Before, surplus1Before);
    } catch {
      removeAllFailed = true;
    }
  }

  function swapExactIn(uint8 directionSeed, uint96 amountSeed) external {
    bool zeroForOne = directionSeed % 2 == 0;
    uint256 maxAmount = zeroForOne ? MAX_TOKEN0_SWAP_AMOUNT : MAX_TOKEN1_SWAP_AMOUNT;
    uint256 amount = 1 + (uint256(amountSeed) % maxAmount);
    _swap(zeroForOne, int128(uint128(amount)));
  }

  function swapExactOut(uint8 directionSeed, uint96 amountSeed) external {
    bool zeroForOne = directionSeed % 2 == 0;
    uint256 maxAmount = zeroForOne ? MAX_TOKEN1_SWAP_AMOUNT : MAX_TOKEN0_SWAP_AMOUNT;
    uint256 amount = 1 + (uint256(amountSeed) % maxAmount);
    _swap(zeroForOne, -int128(uint128(amount)));
  }

  function tinySwapToken0ForToken1() external {
    _swap(true, 1);
  }

  function tinySwapToken1ForToken0() external {
    _swap(false, 1);
  }

  function collectFees() external {
    (uint24 spreadFeeE6,,) = _feesAndPause();
    if (spreadFeeE6 == 0) return;

    uint256 balance0Before = token0.balanceOf(address(this));
    uint256 balance1Before = token1.balanceOf(address(this));

    try pool.collectFees(0, spreadFeeE6, 0, 0, address(this)) {
      uint256 balance0After = token0.balanceOf(address(this));
      uint256 balance1After = token1.balanceOf(address(this));
      if (balance0After > balance0Before) {
        feesCollected0Scaled += (balance0After - balance0Before) * TOKEN0_SCALE;
      }
      if (balance1After > balance1Before) {
        feesCollected1Scaled += balance1After - balance1Before;
      }
    } catch {}
  }

  function setPoolSpreadFee(uint24 feeSeed) external {
    uint24 newSpreadFeeE6 = uint24(uint256(feeSeed) % (MAX_SPREAD_FEE_E6 + 1));
    try pool.setPoolFees(newSpreadFeeE6, 0) {} catch {}
  }

  function setBinAdditionalFees(uint8 binSeed, uint16 buyFeeSeed, uint16 sellFeeSeed) external {
    uint16 buyFeeE6 = uint16(uint256(buyFeeSeed) % (MAX_BIN_ADDITIONAL_FEE_E6 + 1));
    uint16 sellFeeE6 = uint16(uint256(sellFeeSeed) % (MAX_BIN_ADDITIONAL_FEE_E6 + 1));
    try pool.setBinAdditionalFees(_binFromSeed(binSeed), buyFeeE6, sellFeeE6) {} catch {}
  }

  function setPauseLevel(uint8 pauseSeed) external {
    try pool.setPause(pauseSeed % 3) {} catch {}
  }

  function setValidOracleQuote(uint96 midSeed, uint96 spreadSeed) external {
    uint256 mid = ECHIDNA_Q64 + (uint256(midSeed) % (ECHIDNA_Q64 / 10));
    uint256 halfSpread = 1 + (uint256(spreadSeed) % (ECHIDNA_Q64 / 10_000));
    uint256 bid = mid > halfSpread ? mid - halfSpread : 1;
    uint256 ask = mid + halfSpread;
    if (ask > type(uint128).max) return;
    priceProvider.setBidAndAskPrice(uint128(bid), uint128(ask));
  }

  function metricOmmModifyLiquidityCallback(uint256 amount0Delta, uint256 amount1Delta, bytes calldata) external {
    require(msg.sender == address(pool), "bad liquidity callback");
    if (amount0Delta > 0) require(token0.transfer(msg.sender, amount0Delta), "liquidity token0 transfer failed");
    if (amount1Delta > 0) require(token1.transfer(msg.sender, amount1Delta), "liquidity token1 transfer failed");
  }

  function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
    require(msg.sender == address(pool), "bad swap callback");
    if (amount0Delta > 0) require(token0.transfer(msg.sender, uint256(amount0Delta)), "swap token0 transfer failed");
    if (amount1Delta > 0) require(token1.transfer(msg.sender, uint256(amount1Delta)), "swap token1 transfer failed");
  }

  function echidna_pool_solvency() external view returns (bool) {
    (bool solvent,,) = _currentSurplus();
    return solvent;
  }

  function echidna_cursor_stays_in_configured_range() external view returns (bool) {
    (, int8 curBinIdx,,,,) = pool.exposedSlot0();
    (int256 lowestBin, int256 highestBin) = pool.exposedLowestAndHighestBins();
    return int256(curBinIdx) >= lowestBin && int256(curBinIdx) <= highestBin;
  }

  function echidna_cursor_distance_matches_bin_index() external view returns (bool) {
    (, int8 curBinIdx,, int24 storedDistanceE6,,) = pool.exposedSlot0();
    int256 expectedDistanceE6 = int256(INITIAL_CUR_BIN_DISTANCE_E6);

    for (int256 bin = -2; bin <= 1; bin++) {
      int8 binIdx = int8(bin);
      if (pool.exposedBinLength(binIdx) != _configuredBinLength(binIdx)) return false;
    }

    if (curBinIdx > 0) {
      for (int256 bin; bin < int256(curBinIdx); bin++) {
        expectedDistanceE6 += int256(uint256(_configuredBinLength(int8(bin))));
      }
    } else {
      for (int256 bin = -1; bin >= int256(curBinIdx); bin--) {
        expectedDistanceE6 -= int256(uint256(_configuredBinLength(int8(bin))));
      }
    }

    return int256(storedDistanceE6) == expectedDistanceE6;
  }

  function echidna_lp_share_totals_match_positions() external view returns (bool) {
    return _sharesMatchForBin(-2) && _sharesMatchForBin(-1) && _sharesMatchForBin(0) && _sharesMatchForBin(1);
  }

  function echidna_remove_all_for_owner_does_not_fail() external view returns (bool) {
    return !removeAllFailed;
  }

  function echidna_fee_collection_is_bounded_by_generated_surplus() external view returns (bool) {
    (bool solvent, uint256 surplus0Scaled, uint256 surplus1Scaled) = _currentSurplus();
    if (!solvent) return false;
    return feesCollected0Scaled + surplus0Scaled <= surplusBudget0Scaled
      && feesCollected1Scaled + surplus1Scaled <= surplusBudget1Scaled;
  }

  function _swap(bool zeroForOne, int128 amountSpecified) internal {
    (bool solventBefore, uint256 surplus0Before, uint256 surplus1Before) = _currentSurplus();
    if (!solventBefore) return;

    uint128 priceLimitX64 = zeroForOne ? uint128(0) : type(uint128).max;
    try pool.swap(address(this), zeroForOne, amountSpecified, priceLimitX64, "", "") returns (int128, int128) {
      _recordSurplusIncrease(surplus0Before, surplus1Before);
    } catch {}
  }

  function _singleLiquidityDelta(int8 bin, uint256 shares) internal pure returns (LiquidityDelta memory delta) {
    delta.binIdxs = new int256[](1);
    delta.shares = new uint256[](1);
    delta.binIdxs[0] = int256(bin);
    delta.shares[0] = shares;
  }

  function _emptyBin(uint16 lengthE6) internal pure returns (BinState memory) {
    return
      BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: lengthE6, addFeeBuyE6: 0, addFeeSellE6: 0});
  }

  function _configuredBinLength(int8 bin) internal pure returns (uint16) {
    if (bin == -2) return 5_009;
    if (bin == -1) return 2_003;
    if (bin == 0) return 997;
    if (bin == 1) return 3_001;
    revert("unconfigured bin");
  }

  function _binFromSeed(uint8 seed) internal pure returns (int8) {
    uint8 bin = seed % 4;
    if (bin == 0) return -2;
    if (bin == 1) return -1;
    if (bin == 2) return 0;
    return 1;
  }

  function _feesAndPause() internal view returns (uint24 spreadFeeE6, uint24 notionalFeeE8, uint8 pauseLevel) {
    (uint8 pauseLevel_,,,, uint24 spreadFeeE6_, uint24 notionalFeeE8_) = pool.exposedSlot0();
    return (spreadFeeE6_, notionalFeeE8_, pauseLevel_);
  }

  function _sharesMatchForBin(int8 bin) internal view returns (bool) {
    uint256 totalShares = pool.exposedBinTotalShares(bin);
    uint256 positionShares;
    for (uint80 salt = 0; salt < 4; salt++) {
      positionShares += pool.exposedPositionShares(address(this), salt, bin);
    }
    return totalShares == positionShares;
  }

  function _currentSurplus() internal view returns (bool solvent, uint256 surplus0Scaled, uint256 surplus1Scaled) {
    (uint128 total0Scaled, uint128 total1Scaled) = pool.exposedBinTotals();
    (uint128 notional0Scaled, uint128 notional1Scaled) = pool.exposedNotionalFees();
    uint256 claims0Scaled = uint256(total0Scaled) + uint256(notional0Scaled);
    uint256 claims1Scaled = uint256(total1Scaled) + uint256(notional1Scaled);
    uint256 balance0Scaled = IERC20(address(token0)).balanceOf(address(pool)) * TOKEN0_SCALE;
    uint256 balance1Scaled = IERC20(address(token1)).balanceOf(address(pool)) * TOKEN1_SCALE;
    if (balance0Scaled < claims0Scaled || balance1Scaled < claims1Scaled) return (false, 0, 0);
    return (true, balance0Scaled - claims0Scaled, balance1Scaled - claims1Scaled);
  }

  function _recordSurplusIncrease(uint256 surplus0Before, uint256 surplus1Before) internal {
    (bool solventAfter, uint256 surplus0After, uint256 surplus1After) = _currentSurplus();
    if (!solventAfter) return;
    if (surplus0After > surplus0Before) surplusBudget0Scaled += surplus0After - surplus0Before;
    if (surplus1After > surplus1Before) surplusBudget1Scaled += surplus1After - surplus1Before;
  }
}
