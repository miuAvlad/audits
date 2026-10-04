// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

interface IScrollPausedRatePriceProvider {
    function price(address token) external view returns (uint256);
}

interface IScrollPausedRateDebtManager {
    function convertCollateralTokenToUsd(address collateralToken, uint256 collateralAmount)
        external
        view
        returns (uint256);
}

interface IScrollAccountant {
    struct AccountantState {
        address payoutAddress;
        uint96 highwaterMark;
        uint128 feesOwedInBase;
        uint128 totalSharesLastUpdate;
        uint96 exchangeRate;
        uint16 allowedExchangeRateChangeUpper;
        uint16 allowedExchangeRateChangeLower;
        uint64 lastUpdateTimestamp;
        bool isPaused;
        uint24 minimumUpdateDelayInSeconds;
        uint16 platformFee;
        uint16 performanceFee;
    }

    function accountantState() external view returns (AccountantState memory);
    function updateExchangeRate(uint96 newExchangeRate) external;
    function getRate() external view returns (uint256);
    function getRateSafe() external view returns (uint256);
}

contract PriceProviderV1ScrollPausedRateTest is Test {
    error AccountantWithRateProviders__Paused();

    string private constant SCROLL_RPC = "https://rpc.scroll.io";

    uint256 private constant CURRENT_FORK_BLOCK = 34_613_218;

    address private constant PRICE_PROVIDER = 0x44dd2372FE7B97C4B4D6a7d4DeCf72466485BAcB;
    address private constant DEBT_MANAGER = 0x0078C5a459132e279056B2371fE8A8eC973A9553;
    address private constant AUTHORIZED_UPDATER_SAFE = 0x560441fA211AEd16Dd49f70c226380c9D4875225;

    address private constant LIQUID_ETH_ACCOUNTANT = 0x0d05D94a5F1E76C18fbeB7A13d17C8a314088198;
    address private constant LIQUID_BTC_ACCOUNTANT = 0xEa23aC6D7D11f6b181d6B98174D334478ADAe6b0;
    address private constant LIQUID_USD_ACCOUNTANT = 0xc315D6e14DDCDC7407784e2Caf815d131Bc1D3E7;
    address private constant E_USD_ACCOUNTANT = 0xEB440B36f61Bf62E0C54C622944545f159C3B790;

    address private constant LIQUID_USD = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;

    function test_LivePriceProviderConsumesNewRateThatTriggersAccountantPause() external {
        vm.createSelectFork(SCROLL_RPC, CURRENT_FORK_BLOCK);

        IScrollAccountant accountant = IScrollAccountant(LIQUID_USD_ACCOUNTANT);
        IScrollAccountant.AccountantState memory beforeState = accountant.accountantState();
        assertFalse(beforeState.isPaused);
        assertGe(
            block.timestamp,
            uint256(beforeState.lastUpdateTimestamp) + uint256(beforeState.minimumUpdateDelayInSeconds)
        );

        uint96 firstRateAboveUpperBound = uint96(
            uint256(beforeState.exchangeRate) * beforeState.allowedExchangeRateChangeUpper / 10_000 + 1
        );

        // The deployed RolesAuthority authorizes this 2-of-4 Safe as the rate updater.
        vm.prank(AUTHORIZED_UPDATER_SAFE);
        accountant.updateExchangeRate(firstRateAboveUpperBound);

        IScrollAccountant.AccountantState memory afterState = accountant.accountantState();
        assertTrue(afterState.isPaused);
        assertEq(afterState.exchangeRate, firstRateAboveUpperBound);
        assertEq(accountant.getRate(), firstRateAboveUpperBound);

        vm.expectRevert(AccountantWithRateProviders__Paused.selector);
        accountant.getRateSafe();

        // EtherFi configured the generic oracle call as getRate(), so the pause is ignored.
        assertEq(
            IScrollPausedRatePriceProvider(PRICE_PROVIDER).price(LIQUID_USD),
            firstRateAboveUpperBound
        );
        assertEq(
            IScrollPausedRateDebtManager(DEBT_MANAGER).convertCollateralTokenToUsd(LIQUID_USD, 1e6),
            firstRateAboveUpperBound
        );
    }

    function test_HistoricalUpdatesStoredOutOfBoundsRatesAndAutoPausedAllFourAccountants() external {
        _proveHistoricalAutoPause(
            LIQUID_ETH_ACCOUNTANT,
            14_052_291,
            100_000_000,
            1_048_974_799_398_492_415
        );
        _proveHistoricalAutoPause(
            LIQUID_BTC_ACCOUNTANT,
            14_107_745,
            100_000_000,
            101_423_242
        );
        _proveHistoricalAutoPause(
            LIQUID_USD_ACCOUNTANT,
            14_090_187,
            1_063_549,
            1_085_269
        );
        _proveHistoricalAutoPause(
            E_USD_ACCOUNTANT,
            14_108_040,
            1_032_917_217_867_783_877,
            1_045_066_585_449_073_893
        );
    }

    function _proveHistoricalAutoPause(
        address accountantAddress,
        uint256 updateBlock,
        uint96 expectedOldRate,
        uint96 expectedNewRate
    ) internal {
        vm.createSelectFork(SCROLL_RPC, updateBlock - 1);
        IScrollAccountant accountant = IScrollAccountant(accountantAddress);
        IScrollAccountant.AccountantState memory beforeState = accountant.accountantState();

        assertFalse(beforeState.isPaused);
        assertEq(beforeState.exchangeRate, expectedOldRate);

        uint256 upperLimit =
            uint256(expectedOldRate) * beforeState.allowedExchangeRateChangeUpper / 10_000;
        uint256 lowerLimit =
            uint256(expectedOldRate) * beforeState.allowedExchangeRateChangeLower / 10_000;
        assertTrue(uint256(expectedNewRate) > upperLimit || uint256(expectedNewRate) < lowerLimit);

        vm.createSelectFork(SCROLL_RPC, updateBlock);
        accountant = IScrollAccountant(accountantAddress);
        IScrollAccountant.AccountantState memory afterState = accountant.accountantState();

        assertTrue(afterState.isPaused);
        assertEq(afterState.exchangeRate, expectedNewRate);
        assertEq(accountant.getRate(), expectedNewRate);

        vm.expectRevert(AccountantWithRateProviders__Paused.selector);
        accountant.getRateSafe();

        // Cash's PriceProvider was deployed later at block 14,206,947. These events prove
        // natural reachability of the prerequisite, but were not historical Cash exposures.
        assertEq(PRICE_PROVIDER.code.length, 0);
    }
}
