// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAaveV4Spoke } from "../../../../../src/interfaces/IAaveV4Spoke.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";
import { IPriceFeed } from "aave-v4/spoke/interfaces/IPriceFeed.sol";

/// @notice Focused reproduction for a zero-balance collateral flag poisoning later Aave exits.
contract GhostCollateralOracleLockTest is CashGatewayTestSetup {
    function test_zeroBalanceStaleReserveBlocksWithdrawalOfAnotherAsset() public {
        // Use and fully exit weETH while its oracle is healthy.
        _supplyToGateway(address(safe), address(weETH), 1 ether);
        vm.prank(driver);
        gw.withdraw(address(safe), address(weETH), type(uint256).max, address(safe));

        assertEq(gw.suppliedOf(address(safe), address(weETH)), 0, "old reserve has no balance");
        (bool enabledAsCollateral,) = IAaveV4Spoke(address(spoke)).getUserReserveStatus(weethReserveId, address(safe));
        assertTrue(enabledAsCollateral, "full withdrawal leaves the old collateral flag set");

        // Model the old reserve's fail-closed feed becoming stale after the Safe has exited it.
        address oldSource = oracle.getReserveSource(weethReserveId);
        vm.mockCallRevert(oldSource, IPriceFeed.latestAnswer.selector, abi.encodeWithSignature("StalePrice()"));

        // Supplying a different reserve still succeeds: supply and collateral enablement do not
        // refresh the complete account or read the stale zero-balance reserve.
        _supplyToGateway(address(safe), address(usdc), 1_000e6);
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), 1_000e6, 2, "new funds entered Aave");

        // Withdrawing that unrelated reserve refreshes the complete account. Aave reads the old
        // reserve's oracle before checking that its supplied balance is zero, so the exit reverts.
        vm.prank(driver);
        vm.expectRevert(abi.encodeWithSignature("StalePrice()"));
        gw.withdraw(address(safe), address(usdc), type(uint256).max, address(safe));
        assertGt(gw.suppliedOf(address(safe), address(usdc)), 0, "new funds remain locked in Aave");

        // Clearing the stale reserve's flag is sufficient, but EtherFi exposes this operation only
        // to gateway drivers; Safe owners have no CashModule entry point that performs this cleanup.
        vm.prank(driver);
        gw.setUsingAsCollateral(address(safe), address(weETH), false);

        vm.prank(driver);
        gw.withdraw(address(safe), address(usdc), type(uint256).max, address(safe));
        assertEq(gw.suppliedOf(address(safe), address(usdc)), 0, "cleanup restores the exit");
    }
}
