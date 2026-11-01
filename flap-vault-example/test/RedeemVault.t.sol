// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {RedeemVaultV3Upgradeable} from "../src/RedeemVaultBeacon.sol";
import {MockERC20, MockBurnableERC20, MockFakeBurnERC20} from "./mocks/MockTokens.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

contract RedeemVaultTest is Test {
    RedeemVaultV3Upgradeable vault;
    MockBurnableERC20 tax18;
    MockERC20 redeem6;
    address op = address(0xA11CE);
    address user = address(0xB0B);

    function setUp() public {
        tax18 = new MockBurnableERC20("TAX", "TAX", 18);
        redeem6 = new MockERC20("REAL", "REAL", 6);
        RedeemVaultV3Upgradeable impl = new RedeemVaultV3Upgradeable();
        bytes memory init = abi.encodeCall(
            RedeemVaultV3Upgradeable.initialize, (address(tax18), address(0), op, address(redeem6))
        );
        vault = RedeemVaultV3Upgradeable(payable(address(new ERC1967Proxy(address(impl), init))));
        tax18.mint(user, 1000 ether);
        redeem6.mint(op, 1_000_000e6);
    }

    function _open(uint256 minRes, uint256 fundAmt) internal {
        vm.startPrank(op);
        vault.setMinReserve(minRes);
        redeem6.approve(address(vault), fundAmt);
        vault.fund(fundAmt);
        vault.setRedeemEnabled(true);
        vm.stopPrank();
    }

    function test_decimals_18_to_6_exact_and_dust_refund() public {
        _open(100e6, 100e6);
        uint256 amt = 1.5 ether + 1;
        vm.startPrank(user);
        tax18.approve(address(vault), amt);
        uint256 taxBefore = tax18.balanceOf(user);
        uint256 realBefore = redeem6.balanceOf(user);
        vault.redeem(amt, 1.5e6);
        vm.stopPrank();
        assertEq(redeem6.balanceOf(user) - realBefore, 1.5e6);
        assertEq(taxBefore - tax18.balanceOf(user), 1.5 ether);
        assertEq(vault.totalDustRefunded(), 1);
        assertEq(vault.totalBurnedTax(), 1.5 ether);
        assertEq(vault.totalDeadTax(), 0);
    }

    function test_zero_payout_reverts_and_refunds() public {
        _open(10e6, 10e6);
        uint256 dustOnly = 1e11;
        vm.startPrank(user);
        tax18.approve(address(vault), dustOnly);
        uint256 before = tax18.balanceOf(user);
        vm.expectRevert(RedeemVaultV3Upgradeable.ZeroPayout.selector);
        vault.redeem(dustOnly, 0);
        assertEq(tax18.balanceOf(user), before);
        vm.stopPrank();
    }

    function test_fake_burn_counts_as_dead_not_burned() public {
        MockFakeBurnERC20 fake = new MockFakeBurnERC20("F", "F", 18);
        MockERC20 real = new MockERC20("R", "R", 18);
        RedeemVaultV3Upgradeable impl = new RedeemVaultV3Upgradeable();
        bytes memory init =
            abi.encodeCall(RedeemVaultV3Upgradeable.initialize, (address(fake), address(0), op, address(real)));
        RedeemVaultV3Upgradeable v = RedeemVaultV3Upgradeable(payable(address(new ERC1967Proxy(address(impl), init))));
        fake.mint(user, 10 ether);
        real.mint(op, 10 ether);
        vm.startPrank(op);
        v.setMinReserve(5 ether);
        real.approve(address(v), 5 ether);
        v.fund(5 ether);
        v.setRedeemEnabled(true);
        vm.stopPrank();
        vm.startPrank(user);
        fake.approve(address(v), 1 ether);
        v.redeem(1 ether, 1 ether);
        vm.stopPrank();
        assertEq(v.totalBurnedTax(), 0);
        assertEq(v.totalDeadTax(), 1 ether);
        assertEq(fake.balanceOf(address(0xdead)), 1 ether);
    }

    function test_cannot_withdraw_after_lock() public {
        _open(50e6, 50e6);
        vm.prank(op);
        vm.expectRevert(RedeemVaultV3Upgradeable.ReservesAreLocked.selector);
        vault.withdrawRedeemToken(1);
    }

    function test_cannot_close_after_lock() public {
        _open(50e6, 50e6);
        vm.prank(op);
        vm.expectRevert(RedeemVaultV3Upgradeable.ReservesAreLocked.selector);
        vault.setRedeemEnabled(false);
    }

    function test_bad_redeem_token_self_and_tax() public {
        RedeemVaultV3Upgradeable impl = new RedeemVaultV3Upgradeable();
        bytes memory init =
            abi.encodeCall(RedeemVaultV3Upgradeable.initialize, (address(tax18), address(0), op, address(0)));
        RedeemVaultV3Upgradeable v = RedeemVaultV3Upgradeable(payable(address(new ERC1967Proxy(address(impl), init))));
        vm.startPrank(op);
        vm.expectRevert(RedeemVaultV3Upgradeable.BadRedeemToken.selector);
        v.setRedeemToken(address(0));
        vm.expectRevert(RedeemVaultV3Upgradeable.BadRedeemToken.selector);
        v.setRedeemToken(address(tax18));
        v.setRedeemToken(address(redeem6));
        vm.expectRevert(RedeemVaultV3Upgradeable.AlreadySet.selector);
        v.setRedeemToken(address(redeem6));
        vm.stopPrank();
    }

    function test_minReceive_guard() public {
        _open(10e6, 10e6);
        vm.startPrank(user);
        tax18.approve(address(vault), 1 ether);
        vm.expectRevert(RedeemVaultV3Upgradeable.MinReceive.selector);
        vault.redeem(1 ether, 2e6);
        vm.stopPrank();
    }

    function test_insufficient_reserve_refunds_tax() public {
        _open(1e6, 1e6);
        vm.startPrank(user);
        tax18.approve(address(vault), 2 ether);
        uint256 before = tax18.balanceOf(user);
        vm.expectRevert(RedeemVaultV3Upgradeable.InsufficientReserve.selector);
        vault.redeem(2 ether, 0);
        assertEq(tax18.balanceOf(user), before);
        vm.stopPrank();
    }

    function test_double_initialize_reverts() public {
        vm.expectRevert();
        vault.initialize(address(tax18), address(0), op, address(redeem6));
    }

    function test_preview_matches_split() public view {
        (uint256 exp, uint256 dust, uint256 conv) = vault.previewRedeem(1.5 ether + 1);
        assertEq(exp, 1.5e6);
        assertEq(dust, 1);
        assertEq(conv, 1.5 ether);
    }

    function test_coverage_bps() public {
        _open(100e6, 200e6);
        assertEq(vault.coverageBps(), 20_000);
    }

    function test_non_operator_cannot_fund() public {
        vm.prank(user);
        vm.expectRevert(RedeemVaultV3Upgradeable.NotOperator.selector);
        vault.setMinReserve(1);
    }
}
