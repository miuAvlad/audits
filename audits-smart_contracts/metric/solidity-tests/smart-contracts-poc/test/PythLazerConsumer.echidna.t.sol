// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LazerConsumer} from "../contracts/oracles/utils/LazerConsumer.sol";
import {IOffchainOracle} from "../contracts/interfaces/IOffchainOracle.sol";
import {TimeMs} from "../contracts/oracles/utils/TimeMs.sol";

contract EchidnaMockPythLazer {
    bytes public payload;

    function setPayload(bytes memory newPayload) external {
        payload = newPayload;
    }

    function verifyUpdate(bytes calldata) external payable returns (bytes memory, address) {
        return (payload, address(0));
    }
}

contract EchidnaLazerConsumerHarness is LazerConsumer {
    mapping(bytes32 => IOffchainOracle.OracleData) internal store;

    constructor(address pythLazerAddress) LazerConsumer(pythLazerAddress, 60, _expectedProps()) {}

    receive() external payable {}

    function verifyAndStore(uint32[] memory feedIds, bytes memory priceUpdate) external payable {
        _verifyAndStore(store, feedIds, priceUpdate);
    }

    function get(uint32 feedId) external view returns (IOffchainOracle.OracleData memory) {
        return store[bytes32(uint256(feedId))];
    }

    function _expectedProps() internal pure returns (uint8[] memory props) {
        props = new uint8[](4);
        props[0] = 0;
        props[1] = 4;
        props[2] = 5;
        props[3] = 12;
    }
}

contract PythLazerConsumerEchidna {
    uint32 internal constant FORMAT_MAGIC = 0x93c7d375;
    uint32 internal constant FEED_ID = 1;
    uint64 internal constant BASE_TS_MICROS = 1_700_000_000_000_000;

    EchidnaMockPythLazer public immutable mock;
    EchidnaLazerConsumerHarness public immutable consumer;

    uint256 public lastTimestampMs;
    uint64 public lastPositivePrice;
    bool public timestampWentBackwards;
    bool public missingTimestampOverwrote;
    bool public newerInvalidPriceOverwrotePositiveFeed;

    constructor() payable {
        mock = new EchidnaMockPythLazer();
        consumer = new EchidnaLazerConsumerHarness(address(mock));
    }

    receive() external payable {}

    function pushValid(uint64 priceSeed, uint64 confSeed, uint32 tsStepSeed) external payable {
        uint64 priceU = uint64(1 + uint256(priceSeed) % uint256(uint64(type(int64).max)));
        int64 price = int64(priceU);
        uint64 conf = uint64(uint256(confSeed) % priceU);
        uint64 tsMicros = _timestampFromSeed(tsStepSeed);
        _push(_payload(price, -8, conf, _feedUpdateTsProp(tsMicros)));
        _observeAfterPush(false, false);
    }

    function pushOlderValid(uint64 priceSeed, uint64 confSeed) external payable {
        if (lastTimestampMs == 0) return;
        uint64 priceU = uint64(1 + uint256(priceSeed) % uint256(uint64(type(int64).max)));
        int64 price = int64(priceU);
        uint64 conf = uint64(uint256(confSeed) % priceU);
        uint64 tsMicros = uint64((lastTimestampMs - 1) * 1000);
        _push(_payload(price, -8, conf, _feedUpdateTsProp(tsMicros)));
        _observeAfterPush(false, false);
    }

    function pushMissingTimestamp(uint64 priceSeed, uint64 confSeed) external payable {
        uint64 priceU = uint64(1 + uint256(priceSeed) % uint256(uint64(type(int64).max)));
        int64 price = int64(priceU);
        uint64 conf = uint64(uint256(confSeed) % priceU);
        uint256 beforeTs = lastTimestampMs;
        uint64 beforePrice = lastPositivePrice;
        _push(_payload(price, -8, conf, _feedUpdateTsPropEmpty()));
        IOffchainOracle.OracleData memory d = consumer.get(FEED_ID);
        if (beforeTs != 0 && (TimeMs.unwrap(d.timestampMs) != beforeTs || d.price != beforePrice)) {
            missingTimestampOverwrote = true;
        }
    }

    function pushNewerInvalidPrice(uint32 tsStepSeed) external payable {
        if (lastPositivePrice == 0) return;
        uint64 tsMicros = _timestampFromSeed(tsStepSeed);
        uint256 beforeTs = lastTimestampMs;
        _push(_payload(-1, -8, 1, _feedUpdateTsProp(tsMicros)));
        IOffchainOracle.OracleData memory d = consumer.get(FEED_ID);
        if (beforeTs != 0 && TimeMs.unwrap(d.timestampMs) > beforeTs && d.price == 0 && d.spread0 == 0xFFFF) {
            newerInvalidPriceOverwrotePositiveFeed = true;
        }
    }

    function pushMalformed(bytes calldata rawPayload) external payable {
        mock.setPayload(rawPayload);
        uint32[] memory feedIds = new uint32[](1);
        feedIds[0] = FEED_ID;
        try consumer.verifyAndStore{value: _fee()}(feedIds, "") {
            _observeAfterPush(false, false);
        } catch {}
    }

    function echidna_pyth_timestamp_never_goes_backwards() external view returns (bool) {
        return !timestampWentBackwards;
    }

    function echidna_missing_timestamp_never_overwrites() external view returns (bool) {
        return !missingTimestampOverwrote;
    }

    function echidna_newer_invalid_price_never_stalls_existing_feed() external view returns (bool) {
        return !newerInvalidPriceOverwrotePositiveFeed;
    }

    function _push(bytes memory payload) internal {
        mock.setPayload(payload);
        uint32[] memory feedIds = new uint32[](1);
        feedIds[0] = FEED_ID;
        try consumer.verifyAndStore{value: _fee()}(feedIds, "") {} catch {}
    }

    function _observeAfterPush(bool, bool) internal {
        IOffchainOracle.OracleData memory d = consumer.get(FEED_ID);
        uint256 ts = TimeMs.unwrap(d.timestampMs);
        if (ts < lastTimestampMs) timestampWentBackwards = true;
        if (ts > lastTimestampMs) lastTimestampMs = ts;
        if (d.price > 0) lastPositivePrice = d.price;
    }

    function _payload(int64 price, int16 expo, uint64 conf, bytes memory tsProp) internal pure returns (bytes memory) {
        bytes memory feed = abi.encodePacked(
            FEED_ID,
            uint8(4),
            uint8(0), bytes8(uint64(price)),
            uint8(4), bytes2(uint16(expo)),
            uint8(5), bytes8(conf),
            tsProp
        );
        return abi.encodePacked(FORMAT_MAGIC, BASE_TS_MICROS, uint8(1), uint8(1), feed);
    }

    function _feedUpdateTsProp(uint64 ts) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(12), uint8(1), bytes8(ts));
    }

    function _feedUpdateTsPropEmpty() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(12), uint8(0));
    }

    function _timestampFromSeed(uint32 seed) internal view returns (uint64) {
        uint256 minTsMs = lastTimestampMs == 0 ? BASE_TS_MICROS / 1000 : lastTimestampMs + 1;
        return uint64((minTsMs + uint256(seed) % 1 days) * 1000);
    }

    function _fee() internal view returns (uint256) {
        return address(this).balance == 0 ? 0 : 1 wei;
    }
}
