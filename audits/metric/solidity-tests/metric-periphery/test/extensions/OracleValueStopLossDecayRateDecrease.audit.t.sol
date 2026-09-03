// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Extsload} from "@metric-core/Extsload.sol";
import {PoolImmutables} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {Slot0Library} from "@metric-core/libraries/Slot0Library.sol";
import {AllowlistFactoryStub} from "../AllowlistFactoryStub.sol";
import {IOracleValueStopLossExtension} from "../../contracts/interfaces/extensions/IOracleValueStopLossExtension.sol";
import {OracleValueStopLossExtension} from "../../contracts/extensions/OracleValueStopLossExtension.sol";

contract DecayRateTransitionMockPool is Extsload {
  address public immutable factory;
  uint256 public immutable minimalMintableLiquidity;

  constructor(address factory_, uint256 minimalMintableLiquidity_) {
    factory = factory_;
    minimalMintableLiquidity = minimalMintableLiquidity_;
  }

  function getImmutables() external view returns (PoolImmutables memory immutables) {
    immutables.factory = factory;
    immutables.minimalMintableLiquidity = minimalMintableLiquidity;
  }
}

/// @notice Lowering the decay rate retroactively resurrects already-decayed HWM value. With
/// a new zero rate, the resulting false directional stop can persist without further decay.
contract OracleValueStopLossDecayRateDecreaseAuditTest is Test {
  uint256 private constant Q64 = 1 << 64;
  uint256 private constant E6 = 1e6;
  uint32 private constant DRAWDOWN_E6 = 50_000; // 5%
  uint32 private constant OLD_DECAY_E8 = 58; // Approximately 5% per day.
  uint32 private constant TIMELOCK = 1 days;
  uint256 private constant SHARES = 10_000;

  AllowlistFactoryStub private factoryStub;
  OracleValueStopLossExtension private stopLoss;
  DecayRateTransitionMockPool private mockPool;
  address private admin;

  function setUp() public {
    vm.warp(1_000_000);
    admin = makeAddr("pool admin");
    factoryStub = new AllowlistFactoryStub();
    mockPool = new DecayRateTransitionMockPool(address(factoryStub), 1_000);
    factoryStub.setPoolAdmin(address(mockPool), admin);
    stopLoss = new OracleValueStopLossExtension(address(factoryStub));

    vm.prank(address(factoryStub));
    stopLoss.initialize(address(mockPool), abi.encode(DRAWDOWN_E6, OLD_DECAY_E8, TIMELOCK));

    _storeBin(0, 10_000); // At a 1:1 oracle, metricToken0 = 1,000,000.
    _touch(uint128(Q64), true);
  }

  function test_rateDecreaseResurrectsDecayedValueAndCreatesIndefiniteFalseStop() public {
    // The old 5%-per-day policy remains active for two days before the proposal.
    vm.warp(block.timestamp + 2 days);
    vm.prank(admin);
    stopLoss.proposeOracleStopLossDecay(address(mockPool), 0);

    // It remains active for the one-day timelock as well. At execution, the live HWM has
    // naturally decayed by about 15%.
    vm.warp(block.timestamp + TIMELOCK);
    (uint256 correctlyDecayedHwm,) = stopLoss.currentHighWatermarks(address(mockPool), 0);

    // A correct 20% oracle move reduces the token0-marked value of this token1-only bin
    // to 833,300. Oracle updates do not invoke the extension, so the old HWM remains lazy.
    uint128 repricedMid = uint128((Q64 * 12) / 10);
    uint256 metric = 833_300;
    uint256 oldPolicyFloor = correctlyDecayedHwm * (E6 - DRAWDOWN_E6) / E6;

    emit log_named_uint("HWM under the still-active old rate", correctlyDecayedHwm);
    emit log_named_uint("old policy 5% floor", oldPolicyFloor);
    emit log_named_uint("live metric after the correct 20% oracle move", metric);
    assertGe(metric, oldPolicyFloor, "the live metric is valid under the elapsed old policy");

    vm.prank(admin);
    stopLoss.executeOracleStopLossDecay(address(mockPool));

    // The implementation now recalculates the entire three-day interval with rate zero.
    // The HWM jumps back to its original value instead of freezing the already-decayed value.
    (uint256 resurrectedHwm,) = stopLoss.currentHighWatermarks(address(mockPool), 0);
    uint256 resurrectedFloor = resurrectedHwm * (E6 - DRAWDOWN_E6) / E6;
    emit log_named_uint("HWM immediately after setting rate to zero", resurrectedHwm);
    emit log_named_uint("resurrected 5% floor", resurrectedFloor);

    assertEq(resurrectedHwm, 1_000_000, "the pre-decay HWM was resurrected");
    assertLt(metric, resurrectedFloor, "the same metric is now treated as a breach");

    vm.expectPartialRevert(IOracleValueStopLossExtension.OracleStopLossTriggered.selector);
    _touch(repricedMid, true);

    // The new rate is zero, so time alone cannot clear the false barrier.
    vm.warp(block.timestamp + 365 days);
    (uint256 hwmOneYearLater,) = stopLoss.currentHighWatermarks(address(mockPool), 0);
    assertEq(hwmOneYearLater, resurrectedHwm, "zero decay makes the resurrected barrier persistent");
  }

  function _touch(uint128 midPriceX64, bool zeroForOne) private {
    uint256 packed = Slot0Library.pack(0, 0, 0, 0, 0, 0);
    vm.prank(address(mockPool));
    stopLoss.afterSwap(
      address(0), address(0), zeroForOne, 0, 0, packed, packed, midPriceX64, midPriceX64, 0, 0, 0, ""
    );
  }

  function _storeBin(uint104 token0, uint104 token1) private {
    uint256 packed = uint256(token0) | uint256(token1) << 104 | uint256(10_000) << 208;
    vm.store(address(mockPool), _binStateSlot(), bytes32(packed));
    vm.store(address(mockPool), _binTotalSharesSlot(), bytes32(SHARES));
  }

  function _binStateSlot() private pure returns (bytes32 slot) {
    uint256 baseSlot = PoolStateLibrary.MAPPING_BIN_STATES;
    assembly {
      mstore(0x00, 0)
      mstore(0x20, baseSlot)
      slot := keccak256(0x00, 0x40)
    }
  }

  function _binTotalSharesSlot() private pure returns (bytes32 slot) {
    uint256 baseSlot = PoolStateLibrary.MAPPING_BIN_TOTAL_SHARES;
    assembly {
      mstore(0x00, 0)
      mstore(0x20, baseSlot)
      slot := keccak256(0x00, 0x40)
    }
  }
}
