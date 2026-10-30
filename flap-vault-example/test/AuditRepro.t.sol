// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import {Test} from "forge-std/Test.sol";
import {RedeemVaultV3Upgradeable, RedeemVaultBeaconFactory} from "../src/RedeemVaultBeacon.sol";
import {MockERC20, MockFeeOnTransferERC20} from "./mocks/MockTokens.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

contract AuditRegression is Test {
    function makeVault(address tax, address real) internal returns (RedeemVaultV3Upgradeable v) {
        RedeemVaultV3Upgradeable impl = new RedeemVaultV3Upgradeable();
        v = RedeemVaultV3Upgradeable(
            payable(address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(RedeemVaultV3Upgradeable.initialize, (tax, address(0), address(this), real))
                    )
                ))
        );
    }

    function open(RedeemVaultV3Upgradeable v, MockERC20 real) internal {
        real.mint(address(this), 100e6);
        real.approve(address(v), 100e6);
        v.setMinReserve(100e6);
        v.fund(100e6);
        v.setRedeemEnabled(true);
    }

    function test_PredictedTaxCreatedBeforeDeploymentAndOpenedAfter() public {
        vm.chainId(97);
        RedeemVaultBeaconFactory f = new RedeemVaultBeaconFactory();
        address predicted = address(0x123456);
        assertEq(predicted.code.length, 0);
        vm.prank(0x027e3704fC5C16522e9393d04C60A3ac5c0d775f);
        address created = f.newVault(predicted, address(0), address(this), abi.encode(address(0)));
        RedeemVaultV3Upgradeable v = RedeemVaultV3Upgradeable(payable(created));
        assertFalse(v.taxDecimalsInitialized());
        assertEq(v.coverableTaxUnits(), 0);
        (bool ok, bytes memory data) = address(v).staticcall(abi.encodeWithSelector(v.status.selector));
        assertTrue(ok);
        assertGt(data.length, 0);
        vm.expectRevert(RedeemVaultV3Upgradeable.TaxMetadataNotReady.selector);
        v.previewRedeem(1 ether);
        MockERC20 real = new MockERC20("R", "R", 6);
        v.setRedeemToken(address(real));
        v.setMinReserve(1);
        vm.expectRevert(RedeemVaultV3Upgradeable.TaxMetadataNotReady.selector);
        v.setRedeemEnabled(true);
        MockERC20 tax = new MockERC20("T", "T", 18);
        vm.etch(predicted, address(tax).code);
        open(v, real);
        assertTrue(v.taxDecimalsInitialized());
        MockERC20(predicted).mint(address(this), 1 ether);
        MockERC20(predicted).approve(created, 1 ether);
        v.redeem(1 ether, 1e6);
        assertEq(real.balanceOf(address(this)), 1e6);
        assertEq(MockERC20(predicted).balanceOf(v.DEAD()), 1 ether);
    }

    function test_TaxedDustRevertsAtomically() public {
        MockFeeOnTransferERC20 tax = new MockFeeOnTransferERC20("T", "T", 18, 1000);
        MockERC20 real = new MockERC20("R", "R", 6);
        RedeemVaultV3Upgradeable v = makeVault(address(tax), address(real));
        open(v, real);
        uint256 amount = 1 ether + 100;
        tax.mint(address(this), amount);
        tax.approve(address(v), amount);
        vm.expectRevert(RedeemVaultV3Upgradeable.SlippageTax.selector);
        v.redeem(amount, 900000);
        assertEq(real.balanceOf(address(this)), 0);
        assertEq(v.reserve(), 100e6);
        assertEq(v.totalDustRefunded(), 0);
        assertEq(v.totalRedeemedTax(), 0);
        assertEq(tax.balanceOf(address(this)), amount);
        assertEq(tax.allowance(address(this), address(v)), amount);
        assertEq(tax.balanceOf(v.DEAD()), 0);
    }

    function test_DeadFallbackPreservesUnrelatedTaxBalance() public {
        MockERC20 tax = new MockERC20("T", "T", 18);
        MockERC20 real = new MockERC20("R", "R", 6);
        RedeemVaultV3Upgradeable v = makeVault(address(tax), address(real));
        open(v, real);
        tax.mint(address(v), 7 ether);
        tax.mint(address(this), 1 ether);
        tax.approve(address(v), 1 ether);
        v.redeem(1 ether, 1e6);
        assertEq(v.totalDeadTax(), 1 ether);
        assertEq(tax.balanceOf(v.DEAD()), 1 ether);
        assertEq(tax.balanceOf(address(v)), 7 ether);
    }

    function assertBadBurn(MockERC20 tax) internal {
        MockERC20 real = new MockERC20("R", "R", 6);
        RedeemVaultV3Upgradeable v = makeVault(address(tax), address(real));
        open(v, real);
        tax.mint(address(this), 1 ether);
        tax.approve(address(v), 1 ether);
        vm.expectRevert(RedeemVaultV3Upgradeable.InvalidTaxDestruction.selector);
        v.redeem(1 ether, 1e6);
        assertEq(tax.balanceOf(address(this)), 1 ether);
        assertEq(tax.totalSupply(), 1 ether);
        assertEq(v.reserve(), 100e6);
        assertEq(v.totalBurnedTax(), 0);
        assertEq(v.totalDeadTax(), 0);
    }

    function test_PartialBurnReverts() public {
        assertBadBurn(new PartialBurnToken());
    }

    function test_TransferOnlyBurnReverts() public {
        assertBadBurn(new TransferBurnToken());
    }

    function test_ZeroDecimalsIsValid() public {
        MockERC20 tax = new MockERC20("T", "T", 0);
        MockERC20 real = new MockERC20("R", "R", 6);
        RedeemVaultV3Upgradeable v = makeVault(address(tax), address(real));
        open(v, real);
        assertTrue(v.taxDecimalsInitialized());
        tax.mint(address(this), 1);
        tax.approve(address(v), 1);
        v.redeem(1, 1e6);
        assertEq(real.balanceOf(address(this)), 1e6);
    }
}

contract PartialBurnToken is MockERC20 {
    constructor() MockERC20("Partial", "P", 18) {}

    function burn(uint256 amount) external {
        _burn(msg.sender, amount / 2);
    }
}

contract TransferBurnToken is MockERC20 {
    constructor() MockERC20("Transfer", "T", 18) {}

    function burn(uint256 amount) external {
        _transfer(msg.sender, address(0x123), amount);
    }
}
