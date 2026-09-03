// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ProtectedPriceProviderL2} from "../contracts/ProtectedPriceProviderL2.sol";
import {IOffchainOracle} from "../contracts/interfaces/IOffchainOracle.sol";
import {OracleBase} from "../contracts/oracles/providers/OracleBase.sol";
import {toTimeMs} from "../contracts/oracles/utils/TimeMs.sol";
import {MockPoolFactory} from "./mocks/MockPoolFactory.sol";

contract SequencerAuditOracle is OracleBase {
    constructor() OracleBase(msg.sender, 60) {}

    function setData(bytes32 feedId, uint64 price, uint16 spread, uint256 refTime) external {
        oracleData[feedId] = IOffchainOracle.OracleData({
            price: price,
            spread0: spread,
            spread1: type(uint16).max,
            timestampMs: toTimeMs(refTime * 1000)
        });
    }
}

contract MockSequencerUptimeFeed {
    int256 public answer;
    uint256 public startedAt;

    function setStatus(bool isDown) external {
        answer = isDown ? int256(1) : int256(0);
        startedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, block.timestamp, 1);
    }
}

/// @notice The in-scope L2 provider has no sequencer-feed input and never reads sequencer status.
/// These tests model the two states the README says must halt quoting: sequencer down and the
/// post-recovery grace period. The oracle observation itself is authentic/correct at publication.
contract ProtectedPriceProviderL2SequencerAuditTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant T0 = 1_000_000;
    uint256 private constant MAX_TIME_DELTA = 60;
    bytes32 private constant FEED_ID = keccak256("BTC/USD");

    address private constant TOKEN0 = address(0xB0);
    address private constant TOKEN1 = address(0xB1);

    SequencerAuditOracle private oracle;
    MockPoolFactory private poolFactory;
    MockSequencerUptimeFeed private sequencer;
    ProtectedPriceProviderL2 private provider;
    address private activeProvider;

    /// @dev OracleBase binds a read to a pool whose inSwap() reports the calling provider.
    function inSwap() external view returns (address) {
        return activeProvider;
    }

    function setUp() public {
        vm.warp(T0);
        vm.deal(address(this), 1 ether);

        oracle = new SequencerAuditOracle();
        poolFactory = new MockPoolFactory();
        sequencer = new MockSequencerUptimeFeed();

        oracle.addApprovedFactory(address(poolFactory));
        poolFactory.setPool(address(this), true);
        oracle.register{value: 1}(FEED_ID, address(this), address(poolFactory));

        // A 10 bps immutable margin keeps bid < ask independently of confidenceParam.
        provider = new ProtectedPriceProviderL2(
            address(this),
            address(oracle),
            FEED_ID,
            int256(1e15),
            MAX_TIME_DELTA,
            5,
            TOKEN0,
            TOKEN1
        );

        oracle.setData(FEED_ID, 100e8, 10, T0);
    }

    function test_quotesWhileSequencerFeedReportsDown() public {
        sequencer.setStatus(true);

        // Thirty seconds later the last pre-outage observation is still inside MAX_TIME_DELTA.
        // A 20% L1 market move is enough to make execution against this quote materially harmful.
        vm.warp(T0 + 30);
        (uint128 bid, uint128 ask) = _read();

        uint256 fairPriceX64 = 120 * Q64;
        uint256 discountE6 = (fairPriceX64 - uint256(ask)) * 1e6 / fairPriceX64;

        emit log_named_uint("provider ask while sequencer is down (Q64)", ask);
        emit log_named_uint("fair 120 quote (Q64)", fairPriceX64);
        emit log_named_uint("underpricing in ppm", discountE6);

        assertEq(sequencer.answer(), 1, "sequencer reports DOWN");
        assertGt(bid, 0, "provider still returns an executable bid");
        assertGt(ask, bid, "provider still returns an executable ask");
        assertGt(discountE6, 160_000, "quote is over 16% below the post-outage market");
    }

    function test_quotesImmediatelyAfterRecoveryWithoutGracePeriod() public {
        sequencer.setStatus(true);
        vm.warp(T0 + 30);
        sequencer.setStatus(false);

        // Even a fresh post-recovery oracle update does not help with fair-access risk: the
        // provider quotes in the exact recovery block instead of enforcing a grace period.
        oracle.setData(FEED_ID, 120e8, 10, block.timestamp);
        (uint128 bid, uint128 ask) = _read();

        assertEq(sequencer.answer(), 0, "sequencer reports UP");
        assertEq(sequencer.startedAt(), block.timestamp, "recovery happened this block");
        assertGt(bid, 0, "provider quotes before users receive a recovery grace period");
        assertGt(ask, bid);
    }

    function _read() private returns (uint128 bid, uint128 ask) {
        activeProvider = address(provider);
        return provider.getBidAndAskPrice();
    }
}
