// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

interface IScrollPriceProviderV1 {
    enum ReturnType {
        Int256,
        Uint256
    }

    struct Config {
        address oracle;
        bytes priceFunctionCalldata;
        bool isChainlinkType;
        uint8 oraclePriceDecimals;
        uint24 maxStaleness;
        ReturnType dataType;
        bool isBaseTokenEth;
        bool isStableToken;
        bool isBaseTokenBtc;
    }

    function tokenConfig(address token) external view returns (Config memory);
    function price(address token) external view returns (uint256);
}

interface IAccountantWithRateProviders {
    function getRate() external view returns (uint256);
    function getRateSafe() external view returns (uint256);

    function accountantState()
        external
        view
        returns (
            address payoutAddress,
            uint96 highwaterMark,
            uint128 feesOwedInBase,
            uint128 totalSharesLastUpdate,
            uint96 exchangeRate,
            uint16 allowedExchangeRateChangeUpper,
            uint16 allowedExchangeRateChangeLower,
            uint64 lastUpdateTimestamp,
            bool isPaused,
            uint24 minimumUpdateDelayInSeconds,
            uint16 platformFee,
            uint16 performanceFee
        );
}

interface IScrollDebtManager {
    function convertCollateralTokenToUsd(address collateralToken, uint256 collateralAmount)
        external
        view
        returns (uint256);
}

contract PriceProviderV1ScrollStalenessTest is Test {
    uint256 private constant SCROLL_FORK_BLOCK = 34_613_218;

    address private constant PRICE_PROVIDER = 0x44dd2372FE7B97C4B4D6a7d4DeCf72466485BAcB;
    address private constant DEBT_MANAGER = 0x0078C5a459132e279056B2371fE8A8eC973A9553;

    address private constant LIQUID_USD = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address private constant E_USD = 0x939778D83b46B456224A33Fb59630B11DEC56663;

    function setUp() external {
        vm.createSelectFork("https://rpc.scroll.io", SCROLL_FORK_BLOCK);
    }

    function test_LiquidUsdRateAndCollateralValueRemainReadablePastConfiguredMaxStaleness() external {
        _proveStaleRateRemainsUsable(LIQUID_USD, 1e6);
    }

    function test_EUsdRateAndCollateralValueRemainReadablePastConfiguredMaxStaleness() external {
        _proveStaleRateRemainsUsable(E_USD, 1e18);
    }

    function _proveStaleRateRemainsUsable(address token, uint256 oneToken) internal {
        IScrollPriceProviderV1 provider = IScrollPriceProviderV1(PRICE_PROVIDER);
        IScrollPriceProviderV1.Config memory config = provider.tokenConfig(token);
        IAccountantWithRateProviders accountant = IAccountantWithRateProviders(config.oracle);

        (,,,,,,, uint64 lastUpdateTimestamp, bool isPaused,,,) = accountant.accountantState();

        assertFalse(config.isChainlinkType);
        assertFalse(isPaused);
        assertGt(config.maxStaleness, 0);

        uint256 rateBefore = accountant.getRate();
        uint256 safeRateBefore = accountant.getRateSafe();
        uint256 priceBefore = provider.price(token);
        uint256 collateralValueBefore =
            IScrollDebtManager(DEBT_MANAGER).convertCollateralTokenToUsd(token, oneToken);

        vm.warp(uint256(lastUpdateTimestamp) + uint256(config.maxStaleness) + 1);
        assertGt(block.timestamp, uint256(lastUpdateTimestamp) + uint256(config.maxStaleness));

        // Both accountant getters have no age check. getRateSafe only checks the pause flag.
        assertEq(accountant.getRate(), rateBefore);
        assertEq(accountant.getRateSafe(), safeRateBefore);

        // V1 ignores maxStaleness for generic oracles and DebtManager consumes the stale value.
        assertEq(provider.price(token), priceBefore);
        assertEq(
            IScrollDebtManager(DEBT_MANAGER).convertCollateralTokenToUsd(token, oneToken),
            collateralValueBefore
        );
    }
}
