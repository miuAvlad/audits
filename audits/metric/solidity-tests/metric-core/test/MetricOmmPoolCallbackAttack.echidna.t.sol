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
import {MetricOmmEchidnaActor} from "./MetricOmmPoolMultiActor.echidna.t.sol";

contract MetricOmmCallbackAttacker is IMetricOmmModifyLiquidityCallback, IMetricOmmSwapCallback {
  using SafeCast for int256;

  uint8 public mode;
  bool public reentrantSwapSucceeded;
  bool public reentrantAddLiquiditySucceeded;
  bool public reentrantRemoveLiquiditySucceeded;

  function setMode(uint8 mode_) external {
    mode = mode_ % 6;
  }

  function addLiquidity(address pool, uint80 salt, LiquidityDelta memory delta) external returns (uint256, uint256) {
    return IMetricOmmPoolActions(pool).addLiquidity(address(this), salt, delta, "", "");
  }

  function removeLiquidity(address pool, uint80 salt, LiquidityDelta memory delta) external returns (uint256, uint256) {
    return IMetricOmmPoolActions(pool).removeLiquidity(address(this), salt, delta, "");
  }

  function swap(address pool, bool zeroForOne, int128 amountSpecified, uint128 priceLimitX64)
    external
    returns (int128, int128)
  {
    return IMetricOmmPoolActions(pool).swap(address(this), zeroForOne, amountSpecified, priceLimitX64, "", "");
  }

  function metricOmmModifyLiquidityCallback(uint256 amount0Delta, uint256 amount1Delta, bytes calldata) external {
    if (mode == 1) return;
    if (mode == 4) _tryReentrantSwap(msg.sender);
    if (mode == 5) _tryReentrantAddLiquidity(msg.sender);

    PoolImmutables memory imm = IMetricOmmPool(msg.sender).getImmutables();
    if (amount0Delta > 0) require(IERC20(imm.token0).transfer(msg.sender, amount0Delta + _overpay()), "liq token0");
    if (amount1Delta > 0) require(IERC20(imm.token1).transfer(msg.sender, amount1Delta + _overpay()), "liq token1");
  }

  function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
    if (mode == 1) return;
    if (mode == 2 && amount0Delta > 1) amount0Delta -= 1;
    if (mode == 2 && amount1Delta > 1) amount1Delta -= 1;
    if (mode == 3) _tryReentrantSwap(msg.sender);
    if (mode == 5) _tryReentrantRemoveLiquidity(msg.sender);

    PoolImmutables memory imm = IMetricOmmPool(msg.sender).getImmutables();
    if (amount0Delta > 0) {
      require(IERC20(imm.token0).transfer(msg.sender, amount0Delta.toUint256() + _overpay()), "swap token0");
    }
    if (amount1Delta > 0) {
      require(IERC20(imm.token1).transfer(msg.sender, amount1Delta.toUint256() + _overpay()), "swap token1");
    }
  }

  function _tryReentrantSwap(address pool) internal {
    try IMetricOmmPoolActions(pool).swap(address(this), true, int128(1), uint128(0), "", "") {
      reentrantSwapSucceeded = true;
    } catch {}
  }

  function _tryReentrantAddLiquidity(address pool) internal {
    LiquidityDelta memory delta = _singleLiquidityDelta(0, 1_000);
    try IMetricOmmPoolActions(pool).addLiquidity(address(this), 0, delta, "", "") {
      reentrantAddLiquiditySucceeded = true;
    } catch {}
  }

  function _tryReentrantRemoveLiquidity(address pool) internal {
    LiquidityDelta memory delta = _singleLiquidityDelta(0, 1);
    try IMetricOmmPoolActions(pool).removeLiquidity(address(this), 0, delta, "") {
      reentrantRemoveLiquiditySucceeded = true;
    } catch {}
  }

  function _singleLiquidityDelta(int8 bin, uint256 shares) internal pure returns (LiquidityDelta memory delta) {
    delta.binIdxs = new int256[](1);
    delta.shares = new uint256[](1);
    delta.binIdxs[0] = int256(bin);
    delta.shares[0] = shares;
  }

  function _overpay() internal view returns (uint256) {
    return mode == 0 ? 1 : 0;
  }
}

contract MetricOmmPoolCallbackAttackEchidna {
  uint256 internal constant TOKEN0_SCALE = 1e12;
  uint256 internal constant TOKEN1_SCALE = 1;
  uint256 internal constant MINIMAL_MINTABLE_LIQUIDITY = 1_000;
  uint256 internal constant MAX_TOKEN0_SWAP_AMOUNT = 1e9;
  uint256 internal constant MAX_TOKEN1_SWAP_AMOUNT = 1e21;
  uint24 internal constant DEFAULT_SPREAD_FEE_E6 = 10_000;

  MockERC20 public immutable token0;
  MockERC20 public immutable token1;
  EchidnaPriceProvider public immutable priceProvider;
  EchidnaInspectableMetricOmmPool public immutable pool;
  MetricOmmEchidnaActor public immutable honestActor;
  MetricOmmCallbackAttacker public immutable attacker;

  uint256 public attackerSwapSuccesses;
  uint256 public attackerAddSuccesses;
  uint256 public attackerRemoveSuccesses;
  uint256 public honestSwapSuccesses;

  constructor() {
    token0 = new MockERC20("Echidna USDC", "eUSDC", 6);
    token1 = new MockERC20("Echidna WETH", "eWETH", 18);

    priceProvider = new EchidnaPriceProvider();
    priceProvider.setTokens(address(token0), address(token1));
    priceProvider.setBidAndAskPrice(uint128(ECHIDNA_Q64), uint128(ECHIDNA_Q64 + 1));

    BinState[] memory nonNegativeBinStates = new BinState[](2);
    BinState[] memory negativeBinStates = new BinState[](2);
    for (uint256 i; i < 2; i++) {
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

    honestActor = new MetricOmmEchidnaActor();
    attacker = new MetricOmmCallbackAttacker();

    token0.mint(address(honestActor), 1_000_000_000_000);
    token1.mint(address(honestActor), 1_000_000 ether);
    token0.mint(address(attacker), 1_000_000_000_000);
    token1.mint(address(attacker), 1_000_000 ether);

    honestActor.addLiquidity(address(pool), 0, _rangeLiquidityDelta(-1, 1, 100_000));
  }

  function setAttackMode(uint8 modeSeed) external {
    attacker.setMode(modeSeed);
  }

  function attackerAddLiquidity(uint8 binSeed, uint96 sharesSeed) external {
    uint256 shares = MINIMAL_MINTABLE_LIQUIDITY + uint256(sharesSeed) % 1e20;
    try attacker.addLiquidity(address(pool), 0, _singleLiquidityDelta(_binFromSeed(binSeed), shares)) returns (uint256, uint256) {
      attackerAddSuccesses++;
    } catch {}
  }

  function attackerRemoveLiquidity(uint8 binSeed, uint8 fractionSeed) external {
    int8 bin = _binFromSeed(binSeed);
    uint256 currentShares = pool.exposedPositionShares(address(attacker), 0, bin);
    if (currentShares == 0) return;
    uint256 shares = currentShares * (uint256(fractionSeed) + 1) / 256;
    if (shares == 0) shares = 1;
    if (currentShares - shares > 0 && currentShares - shares < MINIMAL_MINTABLE_LIQUIDITY) shares = currentShares;
    try attacker.removeLiquidity(address(pool), 0, _singleLiquidityDelta(bin, shares)) returns (uint256, uint256) {
      attackerRemoveSuccesses++;
    } catch {}
  }

  function attackerSwap(uint8 directionSeed, uint96 amountSeed) external {
    bool zeroForOne = directionSeed % 2 == 0;
    uint256 maxAmount = zeroForOne ? MAX_TOKEN0_SWAP_AMOUNT : MAX_TOKEN1_SWAP_AMOUNT;
    try attacker.swap(
      address(pool),
      zeroForOne,
      int128(uint128(1 + uint256(amountSeed) % maxAmount)),
      zeroForOne ? uint128(0) : type(uint128).max
    ) returns (int128, int128) {
      attackerSwapSuccesses++;
    } catch {}
  }

  function honestSwap(uint8 directionSeed, uint96 amountSeed) external {
    bool zeroForOne = directionSeed % 2 == 0;
    uint256 maxAmount = zeroForOne ? MAX_TOKEN0_SWAP_AMOUNT : MAX_TOKEN1_SWAP_AMOUNT;
    try honestActor.swap(
      address(pool),
      address(honestActor),
      zeroForOne,
      int128(uint128(1 + uint256(amountSeed) % maxAmount)),
      zeroForOne ? uint128(0) : type(uint128).max
    ) returns (int128, int128) {
      honestSwapSuccesses++;
    } catch {}
  }

  function echidna_pool_solvency_after_callback_attacks() external view returns (bool) {
    (bool solvent,,) = _currentSurplus();
    return solvent;
  }

  function echidna_reentrant_swap_never_succeeds() external view returns (bool) {
    return !attacker.reentrantSwapSucceeded();
  }

  function echidna_reentrant_add_liquidity_never_succeeds() external view returns (bool) {
    return !attacker.reentrantAddLiquiditySucceeded();
  }

  function echidna_reentrant_remove_liquidity_never_succeeds() external view returns (bool) {
    return !attacker.reentrantRemoveLiquiditySucceeded();
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

  function _singleLiquidityDelta(int8 bin, uint256 shares) internal pure returns (LiquidityDelta memory delta) {
    delta.binIdxs = new int256[](1);
    delta.shares = new uint256[](1);
    delta.binIdxs[0] = int256(bin);
    delta.shares[0] = shares;
  }

  function _rangeLiquidityDelta(int8 low, int8 high, uint256 shares) internal pure returns (LiquidityDelta memory delta) {
    uint256 count = uint256(int256(high) - int256(low) + 1);
    delta.binIdxs = new int256[](count);
    delta.shares = new uint256[](count);
    for (uint256 i; i < count; i++) {
      delta.binIdxs[i] = int256(low) + int256(i);
      delta.shares[i] = shares;
    }
  }

  function _binFromSeed(uint8 seed) internal pure returns (int8) {
    uint8 bin = seed % 4;
    if (bin == 0) return -2;
    if (bin == 1) return -1;
    if (bin == 2) return 0;
    return 1;
  }
}
