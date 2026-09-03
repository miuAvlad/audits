// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOffchainOracle} from "../../contracts/interfaces/IOffchainOracle.sol";
import {AnchoredPriceProvider} from "../../contracts/AnchoredPriceProvider.sol";
import {TimeMs} from "../../contracts/oracles/utils/TimeMs.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockPool} from "../mocks/MockPool.sol";
import {LazerTestPayload} from "../utils/LazerTestPayload.sol";
import {PythOracleTest} from "./PythOracle.t.sol";

/// @notice Complements the PriceVelocity pool PoC by proving that Metric's real Pyth Lazer
/// verification/storage path accepts many correctly signed, newer observations in one EVM block.
contract PythOracleSequentialSameBlockAuditTest is PythOracleTest {
    uint32 private constant FEED_ID = 777;
    uint256 private constant STEPS = 12;
    uint256 private constant MAX_CHANGE_PER_BLOCK_E18 = 1e15; // 10 bps.

    function test_verifiedSequentialObservationsCanAllLandInOneBlock() public {
        uint256 initialBlock = block.number;
        int64 price = 100_000_000; // 1.00 at exponent -8.
        uint64 firstTsMicros = uint64(block.timestamp * 1_000_000);
        uint256 gasBefore = gasleft();

        for (uint256 i; i < STEPS; ++i) {
            price = int64(int256(price) * 10_009 / 10_000); // Correctly signed 9 bps step.
            uint64 observationTs = firstTsMicros + uint64((i + 1) * 50_000); // 50 ms cadence.

            bool ok = _pushSingleFeed(FEED_ID, price, observationTs);
            assertTrue(ok, "verified Pyth observation was rejected");
            assertEq(block.number, initialBlock, "all observations must be stored in one EVM block");
        }

        IOffchainOracle.OracleData memory stored = _read(bytes32(uint256(FEED_ID)));
        emit log_named_uint("verified observations stored in one block", STEPS);
        emit log_named_uint("final normalized Pyth price", stored.price);
        emit log_named_uint("Pyth verification and storage gas", gasBefore - gasleft());

        assertEq(stored.price, uint64(price), "latest strictly newer observation must win");
        assertEq(
            TimeMs.unwrap(stored.timestampMs) / 1000,
            block.timestamp,
            "every sub-second observation remains fresh in the current provider second"
        );
    }

    function test_permissionlessSignedUpdatesReachTheProviderAtEveryRatchetStep() public {
        address attacker = makeAddr("permissionless relayer");
        uint64 firstTsMicros = uint64(block.timestamp * 1_000_000);
        int64 price = 100_000_000; // 1.00 at exponent -8.

        AnchoredPriceProvider provider = new AnchoredPriceProvider(
            address(this),
            address(oracle),
            bytes32(uint256(FEED_ID)),
            bytes32(0),
            1e14, // 1 bps immutable provider margin.
            60,
            100,
            false,
            0,
            address(0xA11CE),
            address(0xB0B)
        );
        MockPool providerPool = new MockPool(address(provider));
        factory.setPool(address(providerPool), true);
        oracle.register{value: 1}(bytes32(uint256(FEED_ID)), address(providerPool), address(factory));

        assertTrue(_pushSingleFeedAs(attacker, FEED_ID, price, firstTsMicros));
        (uint128 initialBid, uint128 initialAsk) = providerPool.getBidAndAskPrice();
        uint256 initialMid = Math.sqrt(uint256(initialBid) * uint256(initialAsk));
        uint256 previousMid = initialMid;
        uint256 initialBlock = block.number;
        uint256 gasBefore = gasleft();

        for (uint256 i; i < STEPS; ++i) {
            price = int64(int256(price) * 10_009 / 10_000);
            uint64 observationTs = firstTsMicros + uint64((i + 1) * 50_000);

            assertTrue(_pushSingleFeedAs(attacker, FEED_ID, price, observationTs));
            (uint128 bid, uint128 ask) = providerPool.getBidAndAskPrice();
            uint256 currentMid = Math.sqrt(uint256(bid) * uint256(ask));
            uint256 adjacentChangeE18 = (currentMid - previousMid) * 1e18 / previousMid;

            assertLt(adjacentChangeE18, MAX_CHANGE_PER_BLOCK_E18, "each provider step is below 10 bps");
            assertEq(block.number, initialBlock, "update and provider read remain in one EVM block");
            previousMid = currentMid;
        }

        uint256 cumulativeChangeE18 = (previousMid - initialMid) * 1e18 / initialMid;
        emit log_named_uint("permissionless relayer", uint256(uint160(attacker)));
        emit log_named_uint("provider-visible cumulative same-block move E18", cumulativeChangeE18);
        emit log_named_uint("signed Pyth plus provider-read gas", gasBefore - gasleft());

        assertGt(cumulativeChangeE18, 1e16, "real provider exposes more than 10x the configured cap");
    }

    function _pushSingleFeedAs(address relayer, uint32 feedId, int64 price, uint64 tsMicros) private returns (bool ok) {
        bytes[] memory feeds = new bytes[](1);
        feeds[0] = LazerTestPayload.buildFeed(feedId, price, -8, 100_000, tsMicros);
        bytes memory update = LazerTestPayload.signAndWrap(LazerTestPayload.buildPayload(tsMicros, 1, feeds));

        _fundOracle();
        vm.prank(relayer);
        (ok,) = address(oracle).call(abi.encodePacked(uint16(1), feedId, update));
    }
}
