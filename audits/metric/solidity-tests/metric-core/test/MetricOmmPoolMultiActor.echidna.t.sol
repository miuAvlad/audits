// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMetricOmmPool, PoolImmutables} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmModifyLiquidityCallback} from "../contracts/interfaces/callbacks/IMetricOmmModifyLiquidityCallback.sol";
import {IMetricOmmSwapCallback} from "../contracts/interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {LiquidityDelta} from "../contracts/types/PoolOperation.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {PoolExtensions, ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {EchidnaPriceProvider, EchidnaInspectableMetricOmmPool, ECHIDNA_Q64} from "./MetricOmmPool.echidna.t.sol";

contract MetricOmmEchidnaActor is IMetricOmmModifyLiquidityCallback, IMetricOmmSwapCallback {
  using SafeCast for int256;

  function addLiquidity(address pool, uint80 salt, LiquidityDelta memory delta) external returns (uint256, uint256) {
    return IMetricOmmPoolActions(pool).addLiquidity(address(this), salt, delta, "", "");
  }

  function removeLiquidity(address pool, uint80 salt, LiquidityDelta memory delta) external returns (uint256, uint256) {
    return IMetricOmmPoolActions(pool).removeLiquidity(address(this), salt, delta, "");
  }

  function swap(address pool, address recipient, bool zeroForOne, int128 amountSpecified, uint128 priceLimitX64)
    external
    returns (int128, int128)
  {
    return IMetricOmmPoolActions(pool).swap(recipient, zeroForOne, amountSpecified, priceLimitX64, "", "");
  }

  function metricOmmModifyLiquidityCallback(uint256 amount0Delta, uint256 amount1Delta, bytes calldata) external {
    PoolImmutables memory imm = IMetricOmmPool(msg.sender).getImmutables();
    if (amount0Delta > 0) require(IERC20(imm.token0).transfer(msg.sender, amount0Delta), "liq token0");
    if (amount1Delta > 0) require(IERC20(imm.token1).transfer(msg.sender, amount1Delta), "liq token1");
  }

  function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
    PoolImmutables memory imm = IMetricOmmPool(msg.sender).getImmutables();
    if (amount0Delta > 0) require(IERC20(imm.token0).transfer(msg.sender, amount0Delta.toUint256()), "swap token0");
    if (amount1Delta > 0) require(IERC20(imm.token1).transfer(msg.sender, amount1Delta.toUint256()), "swap token1");
  }
}

contract MetricOmmPoolMultiActorEchidna {
  uint256 internal constant TOKEN0_SCALE = 1e12;
  uint256 internal constant TOKEN1_SCALE = 1;
  uint256 internal constant MINIMAL_MINTABLE_LIQUIDITY = 1_000;
  uint256 internal constant MAX_LIQUIDITY_SHARES = 1e20;
  uint256 internal constant MAX_TOKEN0_SWAP_AMOUNT = 1e9;
  uint256 internal constant MAX_TOKEN1_SWAP_AMOUNT = 1e21;
  uint24 internal constant DEFAULT_SPREAD_FEE_E6 = 10_000;
  uint256 internal constant ACTOR_COUNT = 4;
  uint256 internal constant SALT_COUNT = 4;

  MockERC20 public immutable token0;
  MockERC20 public immutable token1;
  EchidnaPriceProvider public immutable priceProvider;
  EchidnaInspectableMetricOmmPool public immutable pool;

  MetricOmmEchidnaActor[] internal actors;

  uint256 public successfulAdds;
  uint256 public successfulRemoves;
  uint256 public successfulSwaps;
  bool public removeAllFailed;

  constructor() {
    token0 = new MockERC20("Echidna USDC", "eUSDC", 6);
    token1 = new MockERC20("Echidna WETH", "eWETH", 18);

    priceProvider = new EchidnaPriceProvider();
    priceProvider.setTokens(address(token0), address(token1));
    priceProvider.setBidAndAskPrice(uint128(ECHIDNA_Q64), uint128(ECHIDNA_Q64 + 1));

    BinState[] memory nonNegativeBinStates = new BinState[](3);
    BinState[] memory negativeBinStates = new BinState[](3);
    for (uint256 i; i < 3; i++) {
      nonNegativeBinStates[i] =
        BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: 1_000, addFeeBuyE6: 0, addFeeSellE6: 0});
      negativeBinStates[i] =
        BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: 1_000, addFeeBuyE6: 0, addFeeSellE6: 0});
    }

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
      0,
      nonNegativeBinStates,
      negativeBinStates,
      0
    );

    for (uint256 i; i < ACTOR_COUNT; i++) {
      MetricOmmEchidnaActor actor = new MetricOmmEchidnaActor();
      actors.push(actor);
      token0.mint(address(actor), 1_000_000_000_000);
      token1.mint(address(actor), 1_000_000 ether);
    }
  }

  function addLiquidity(uint8 actorSeed, uint8 binSeed, uint8 saltSeed, uint96 sharesSeed) external {
    MetricOmmEchidnaActor actor = _actor(actorSeed);
    LiquidityDelta memory delta =
      _singleLiquidityDelta(_binFromSeed(binSeed), MINIMAL_MINTABLE_LIQUIDITY + uint256(sharesSeed) % MAX_LIQUIDITY_SHARES);

    try actor.addLiquidity(address(pool), uint80(saltSeed % SALT_COUNT), delta) returns (uint256, uint256) {
      successfulAdds++;
    } catch {}
  }

  function removeLiquidity(uint8 actorSeed, uint8 binSeed, uint8 saltSeed, uint8 fractionSeed) external {
    MetricOmmEchidnaActor actor = _actor(actorSeed);
    uint80 salt = uint80(saltSeed % SALT_COUNT);
    int8 bin = _binFromSeed(binSeed);
    uint256 currentShares = pool.exposedPositionShares(address(actor), salt, bin);
    if (currentShares == 0) return;

    uint256 shares = currentShares * (uint256(fractionSeed) + 1) / 256;
    if (shares == 0) shares = 1;
    if (currentShares - shares > 0 && currentShares - shares < MINIMAL_MINTABLE_LIQUIDITY) shares = currentShares;

    try actor.removeLiquidity(address(pool), salt, _singleLiquidityDelta(bin, shares)) returns (uint256, uint256) {
      successfulRemoves++;
    } catch {}
  }

  function removeAllLiquidity(uint8 actorSeed, uint8 binSeed, uint8 saltSeed) external {
    MetricOmmEchidnaActor actor = _actor(actorSeed);
    uint80 salt = uint80(saltSeed % SALT_COUNT);
    int8 bin = _binFromSeed(binSeed);
    uint256 currentShares = pool.exposedPositionShares(address(actor), salt, bin);
    if (currentShares == 0) return;

    try actor.removeLiquidity(address(pool), salt, _singleLiquidityDelta(bin, currentShares)) returns (uint256, uint256) {
      successfulRemoves++;
    } catch {
      removeAllFailed = true;
    }
  }

  function swapExactIn(uint8 actorSeed, uint8 directionSeed, uint96 amountSeed) external {
    bool zeroForOne = directionSeed % 2 == 0;
    uint256 maxAmount = zeroForOne ? MAX_TOKEN0_SWAP_AMOUNT : MAX_TOKEN1_SWAP_AMOUNT;
    _swap(actorSeed, zeroForOne, int128(uint128(1 + uint256(amountSeed) % maxAmount)));
  }

  function swapExactOut(uint8 actorSeed, uint8 directionSeed, uint96 amountSeed) external {
    bool zeroForOne = directionSeed % 2 == 0;
    uint256 maxAmount = zeroForOne ? MAX_TOKEN1_SWAP_AMOUNT : MAX_TOKEN0_SWAP_AMOUNT;
    _swap(actorSeed, zeroForOne, -int128(uint128(1 + uint256(amountSeed) % maxAmount)));
  }

  function setValidOracleQuote(uint96 midSeed, uint96 spreadSeed) external {
    uint256 mid = ECHIDNA_Q64 + uint256(midSeed) % (ECHIDNA_Q64 / 10);
    uint256 halfSpread = 1 + uint256(spreadSeed) % (ECHIDNA_Q64 / 10_000);
    uint256 bid = mid > halfSpread ? mid - halfSpread : 1;
    uint256 ask = mid + halfSpread;
    if (ask <= type(uint128).max) priceProvider.setBidAndAskPrice(uint128(bid), uint128(ask));
  }

  function echidna_pool_solvency() external view returns (bool) {
    (bool solvent,,) = _currentSurplus();
    return solvent;
  }

  function echidna_lp_share_totals_match_all_actors() external view returns (bool) {
    return _sharesMatchForBin(-3) && _sharesMatchForBin(-2) && _sharesMatchForBin(-1) && _sharesMatchForBin(0)
      && _sharesMatchForBin(1) && _sharesMatchForBin(2);
  }

  function echidna_remove_all_does_not_fail() external view returns (bool) {
    return !removeAllFailed;
  }

  function _swap(uint8 actorSeed, bool zeroForOne, int128 amountSpecified) internal {
    MetricOmmEchidnaActor actor = _actor(actorSeed);
    uint128 priceLimitX64 = zeroForOne ? uint128(0) : type(uint128).max;
    try actor.swap(address(pool), address(actor), zeroForOne, amountSpecified, priceLimitX64) returns (int128, int128) {
      successfulSwaps++;
    } catch {}
  }

  function _sharesMatchForBin(int8 bin) internal view returns (bool) {
    uint256 totalShares = pool.exposedBinTotalShares(bin);
    uint256 positionShares;
    for (uint256 i; i < actors.length; i++) {
      for (uint80 salt; salt < SALT_COUNT; salt++) {
        positionShares += pool.exposedPositionShares(address(actors[i]), salt, bin);
      }
    }
    return totalShares == positionShares;
  }

  function _currentSurplus() internal view returns (bool solvent, uint256 surplus0Scaled, uint256 surplus1Scaled) {
    (uint128 total0Scaled, uint128 total1Scaled) = pool.exposedBinTotals();
    (uint128 notional0Scaled, uint128 notional1Scaled) = pool.exposedNotionalFees();
    uint256 claims0Scaled = uint256(total0Scaled) + uint256(notional0Scaled);
    uint256 claims1Scaled = uint256(total1Scaled) + uint256(notional1Scaled);
    uint256 balance0Scaled = token0.balanceOf(address(pool)) * TOKEN0_SCALE;
    uint256 balance1Scaled = token1.balanceOf(address(pool)) * TOKEN1_SCALE;
    if (balance0Scaled < claims0Scaled || balance1Scaled < claims1Scaled) return (false, 0, 0);
    return (true, balance0Scaled - claims0Scaled, balance1Scaled - claims1Scaled);
  }

  function _actor(uint8 seed) internal view returns (MetricOmmEchidnaActor) {
    return actors[uint256(seed) % actors.length];
  }

  function _singleLiquidityDelta(int8 bin, uint256 shares) internal pure returns (LiquidityDelta memory delta) {
    delta.binIdxs = new int256[](1);
    delta.shares = new uint256[](1);
    delta.binIdxs[0] = int256(bin);
    delta.shares[0] = shares;
  }

  function _binFromSeed(uint8 seed) internal pure returns (int8) {
    uint8 bin = seed % 6;
    if (bin == 0) return -3;
    if (bin == 1) return -2;
    if (bin == 2) return -1;
    if (bin == 3) return 0;
    if (bin == 4) return 1;
    return 2;
  }
}
