// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {IPriceProvider} from "@metric-core/interfaces/IPriceProvider/IPriceProvider.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {PoolExtensions, ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {PoolFeeConfig} from "@metric-core/types/FactoryStorage.sol";
import {MockERC20} from "@metric-core-test/mocks/MockERC20.sol";
import {MetricOmmSimpleRouter} from "../contracts/MetricOmmSimpleRouter.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {RouterTestFactory} from "./RouterTestFactory.sol";
import {LiquidityHelper} from "./helpers/LiquidityHelper.sol";

contract RouterEchidnaPriceProvider is IPriceProvider {
  uint128 public bidPrice;
  uint128 public askPrice;
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

contract MetricOmmRouterMultihopEchidna {
  uint256 internal constant Q64 = 2 ** 64;
  uint256 internal constant INITIAL_DENSITY = 1e18;
  uint256 internal constant MINIMAL_MINTABLE_LIQUIDITY = 1_000;
  uint24 internal constant PROTOCOL_FEE = 10_000;
  uint24 internal constant ADMIN_FEE = 5_000;

  MockERC20 public immutable token0;
  MockERC20 public immutable token1;
  MockERC20 public immutable token2;
  RouterEchidnaPriceProvider public immutable oracle;
  RouterTestFactory public immutable factory;
  MetricOmmSimpleRouter public immutable router;
  LiquidityHelper public immutable liquidityHelper;
  MetricOmmPool public immutable pool01;
  MetricOmmPool public immutable pool12;

  uint256 public exactInputSuccesses;
  uint256 public exactOutputSuccesses;
  bool public routerHeldFundsAfterSuccess;
  bool public badPathSucceeded;
  bool public impossibleFinalSlippageSucceeded;

  constructor() {
    token0 = new MockERC20("Router Token0", "RT0", 18);
    token1 = new MockERC20("Router Token1", "RT1", 18);
    token2 = new MockERC20("Router Token2", "RT2", 18);

    oracle = new RouterEchidnaPriceProvider();
    oracle.setTokens(address(token0), address(token1));
    oracle.setBidAndAskPrice(uint128(Q64), uint128(Q64 + 1));

    factory = new RouterTestFactory();
    router = new MetricOmmSimpleRouter(address(token0), address(factory));
    liquidityHelper = new LiquidityHelper();

    pool01 = _deployPool(address(token0), address(token1));
    pool12 = _deployPool(address(token1), address(token2));

    _seedLiquidity(pool01, token0, token1, 0);
    _seedLiquidity(pool12, token1, token2, 1);

    token0.mint(address(this), 1_000_000 ether);
    token1.mint(address(this), 1_000_000 ether);
    token2.mint(address(this), 1_000_000 ether);
    token0.approve(address(router), type(uint256).max);
    token1.approve(address(router), type(uint256).max);
    token2.approve(address(router), type(uint256).max);
  }

  function exactInputTwoHop(uint96 amountSeed, uint96 minOutSeed) external {
    uint128 amountIn = uint128(1 + uint256(amountSeed) % 1e21);
    uint128 minOut = uint128(uint256(minOutSeed) % 1e18);
    uint256 token2Before = token2.balanceOf(address(this));

    try router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: _goodTokens(),
        pools: _goodPools(),
        extensionDatas: _emptyExtensionDatas(),
        zeroForOneBitMap: 3,
        amountIn: amountIn,
        amountOutMinimum: minOut,
        recipient: address(this),
        deadline: type(uint256).max
      })
    ) returns (uint256 amountOut) {
      exactInputSuccesses++;
      if (token2.balanceOf(address(this)) - token2Before != amountOut) routerHeldFundsAfterSuccess = true;
      if (!_routerEmpty()) routerHeldFundsAfterSuccess = true;
    } catch {}
  }

  function exactOutputTwoHop(uint96 amountOutSeed, uint96 maxInSeed) external {
    uint128 amountOut = uint128(1 + uint256(amountOutSeed) % 1e18);
    uint128 amountInMaximum = amountOut + uint128(uint256(maxInSeed) % 1e21);
    uint256 token2Before = token2.balanceOf(address(this));

    try router.exactOutput(
      IMetricOmmSimpleRouter.ExactOutputParams({
        tokens: _goodTokens(),
        pools: _goodPools(),
        extensionDatas: _emptyExtensionDatas(),
        zeroForOneBitMap: 3,
        amountOut: amountOut,
        amountInMaximum: amountInMaximum,
        recipient: address(this),
        deadline: type(uint256).max
      })
    ) returns (uint256 amountIn) {
      exactOutputSuccesses++;
      if (amountIn > amountInMaximum) impossibleFinalSlippageSucceeded = true;
      if (token2.balanceOf(address(this)) - token2Before != amountOut) routerHeldFundsAfterSuccess = true;
      if (!_routerEmpty()) routerHeldFundsAfterSuccess = true;
    } catch {}
  }

  function disconnectedExactInput(uint96 amountSeed) external {
    address[] memory tokens = _goodTokens();
    tokens[1] = address(token0);

    try router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: _goodPools(),
        extensionDatas: _emptyExtensionDatas(),
        zeroForOneBitMap: 3,
        amountIn: uint128(1 + uint256(amountSeed) % 1e21),
        amountOutMinimum: 0,
        recipient: address(this),
        deadline: type(uint256).max
      })
    ) returns (uint256) {
      badPathSucceeded = true;
    } catch {}
  }

  function exactInputImpossibleFinalSlippage(uint96 amountSeed) external {
    try router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: _goodTokens(),
        pools: _goodPools(),
        extensionDatas: _emptyExtensionDatas(),
        zeroForOneBitMap: 3,
        amountIn: uint128(1 + uint256(amountSeed) % 1e21),
        amountOutMinimum: type(uint128).max,
        recipient: address(this),
        deadline: type(uint256).max
      })
    ) returns (uint256) {
      impossibleFinalSlippageSucceeded = true;
    } catch {}
  }

  function exactOutputImpossibleFinalSlippage(uint96 amountOutSeed) external {
    try router.exactOutput(
      IMetricOmmSimpleRouter.ExactOutputParams({
        tokens: _goodTokens(),
        pools: _goodPools(),
        extensionDatas: _emptyExtensionDatas(),
        zeroForOneBitMap: 3,
        amountOut: uint128(1 + uint256(amountOutSeed) % 1e18),
        amountInMaximum: 0,
        recipient: address(this),
        deadline: type(uint256).max
      })
    ) returns (uint256) {
      impossibleFinalSlippageSucceeded = true;
    } catch {}
  }

  function echidna_router_empty_after_successful_multihop() external view returns (bool) {
    return !routerHeldFundsAfterSuccess && _routerEmpty();
  }

  function echidna_disconnected_path_does_not_succeed() external view returns (bool) {
    return !badPathSucceeded;
  }

  function echidna_final_slippage_bounds_are_enforced() external view returns (bool) {
    return !impossibleFinalSlippageSucceeded;
  }

  function _deployPool(address token0Addr, address token1Addr) internal returns (MetricOmmPool deployed) {
    BinState[] memory nnStates = _binStates();
    BinState[] memory negStates = _binStates();
    PoolExtensions memory extensions;
    ExtensionOrders memory extensionOrders;

    deployed = new MetricOmmPool(
      address(factory),
      address(this),
      address(this),
      token0Addr,
      token1Addr,
      address(oracle),
      extensions,
      extensionOrders,
      true,
      1,
      1,
      INITIAL_DENSITY,
      INITIAL_DENSITY,
      MINIMAL_MINTABLE_LIQUIDITY,
      PROTOCOL_FEE + ADMIN_FEE,
      0,
      nnStates,
      negStates,
      0
    );

    factory.registerPool(
      address(deployed),
      PoolFeeConfig({
        protocolSpreadFeeE6: PROTOCOL_FEE,
        adminSpreadFeeE6: ADMIN_FEE,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0
      }),
      address(this),
      address(this)
    );
  }

  function _seedLiquidity(MetricOmmPool target, MockERC20 a, MockERC20 b, uint80 salt) internal {
    a.mint(address(liquidityHelper), 500_000 ether);
    b.mint(address(liquidityHelper), 500_000 ether);
    liquidityHelper.addLiquidityRange(address(target), salt, -4, 4, 100_000);
  }

  function _binStates() internal pure returns (BinState[] memory states) {
    states = new BinState[](5);
    for (uint256 i; i < 5; i++) {
      states[i] =
        BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: 100, addFeeBuyE6: 0, addFeeSellE6: 0});
    }
  }

  function _goodTokens() internal view returns (address[] memory tokens) {
    tokens = new address[](3);
    tokens[0] = address(token0);
    tokens[1] = address(token1);
    tokens[2] = address(token2);
  }

  function _goodPools() internal view returns (address[] memory pools) {
    pools = new address[](2);
    pools[0] = address(pool01);
    pools[1] = address(pool12);
  }

  function _emptyExtensionDatas() internal pure returns (bytes[] memory extensionDatas) {
    extensionDatas = new bytes[](2);
  }

  function _routerEmpty() internal view returns (bool) {
    return address(router).balance == 0 && token0.balanceOf(address(router)) == 0 && token1.balanceOf(address(router)) == 0
      && token2.balanceOf(address(router)) == 0;
  }
}
