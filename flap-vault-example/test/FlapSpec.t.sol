// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {RedeemVaultV3Upgradeable, RedeemVaultBeaconFactory} from "../src/RedeemVaultBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import {VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";
import {IVaultFactoryValidationV2} from "../src/flap/IVaultFactory.sol";
import {MockERC20} from "./mocks/MockTokens.sol";

contract FlapSpecTest is Test {
    address constant GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    address constant PORTAL = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    RedeemVaultBeaconFactory factory;
    RedeemVaultV3Upgradeable vault;
    MockERC20 tax;
    MockERC20 real;

    receive() external payable {}

    function setUp() public {
        vm.chainId(97);
        factory = new RedeemVaultBeaconFactory();
        tax = new MockERC20("T", "T", 18);
        real = new MockERC20("R", "R", 6);
        vm.prank(PORTAL);
        vault = RedeemVaultV3Upgradeable(payable(factory.newVault(address(tax), address(0), address(this), "")));
    }

    function test_OnlyGuardianCanUpgradeAndStateSurvives() public {
        assertEq(factory.beaconOwner(), GUARDIAN);
        assertFalse(factory.isVaultUpgradesLocked());
        vault.setRedeemToken(address(real));
        vault.setMinReserve(17);
        SpecUpgrade next = new SpecUpgrade();
        UpgradeableBeacon beacon = UpgradeableBeacon(factory.beacon());
        vm.expectRevert("Ownable: caller is not the owner");
        beacon.upgradeTo(address(next));
        vm.prank(address(0xBAD));
        vm.expectRevert("Ownable: caller is not the owner");
        beacon.transferOwnership(address(0xBAD));
        vm.prank(GUARDIAN);
        beacon.upgradeTo(address(next));
        assertEq(factory.beaconImplementation(), address(next));
        assertEq(SpecUpgrade(payable(address(vault))).revision(), 2);
        assertEq(vault.redeemToken(), address(real));
        assertEq(vault.taxToken(), address(tax));
        assertEq(vault.minReserve(), 17);
        assertEq(vault.operator(), address(this));
    }

    function test_BscMainnetGuardianAssignment() public {
        vm.chainId(56);
        RedeemVaultBeaconFactory mainnetFactory = new RedeemVaultBeaconFactory();
        assertEq(mainnetFactory.beaconOwner(), 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
    }

    function test_GuardianRemainsPrivilegedAfterOperatorChangeButHonorsLock() public {
        vault.transferOperator(address(0xA11CE));
        vm.startPrank(GUARDIAN);
        vault.setRedeemToken(address(real));
        vault.setMinReserve(1);
        vm.stopPrank();
        real.mint(address(vault), 1);
        vm.startPrank(GUARDIAN);
        vault.setRedeemEnabled(true);
        vm.expectRevert(RedeemVaultV3Upgradeable.ReservesAreLocked.selector);
        vault.withdrawRedeemToken(1);
        vm.expectRevert(RedeemVaultV3Upgradeable.ReservesAreLocked.selector);
        vault.setRedeemEnabled(false);
        vault.transferOperator(address(this));
        vm.stopPrank();
        assertEq(vault.guardian(), GUARDIAN);
        assertEq(vault.operator(), address(this));
    }

    function test_SchemaWorkflowUsesExplicitApprovalAndRawUnits() public {
        VaultUISchema memory schema = vault.vaultUISchema();
        assertEq(schema.methods.length, 15);
        assertEq(schema.methods[3].name, "fund");
        assertEq(schema.methods[3].approvals.length, 0);
        assertEq(schema.methods[2].approvals[0].tokenType, "taxToken");
        assertEq(schema.methods[3].inputs[0].decimals, 0);
        _uiCall(schema.methods[5].name, "(address)", abi.encode(address(real)));
        _uiCall(schema.methods[6].name, "(uint256)", abi.encode(uint256(1e6)));
        real.mint(address(this), 1e6);
        vm.expectRevert("ERC20: insufficient allowance");
        vault.fund(1e6);
        real.approve(address(vault), 1e6);
        _uiCall(schema.methods[3].name, "(uint256)", abi.encode(uint256(1e6)));
        _uiCall(schema.methods[4].name, "(bool)", abi.encode(true));
        assertTrue(vault.redeemEnabled());
        assertEq(vault.reserve(), 1e6);
        // Every no-input read advertised in the schema is callable and decodes to the declared number of ABI words.
        for (uint256 i; i < schema.methods.length; ++i) {
            if (!schema.methods[i].isWriteMethod && schema.methods[i].inputs.length == 0) {
                (bool ok, bytes memory result) =
                    address(vault).staticcall(abi.encodeWithSignature(string.concat(schema.methods[i].name, "()")));
                assertTrue(ok);
                assertEq(result.length, schema.methods[i].outputs.length * 32);
            }
        }
    }

    function _uiCall(string memory name, string memory signature, bytes memory arguments) internal {
        (bool ok,) =
            address(vault).call(bytes.concat(bytes4(keccak256(bytes(string.concat(name, signature)))), arguments));
        assertTrue(ok, name);
    }

    function test_DirectFundingNeedsNoApproval() public {
        vault.setRedeemToken(address(real));
        vault.setMinReserve(1e6);
        real.mint(address(this), 1e6);
        real.transfer(address(vault), 1e6);
        assertEq(real.allowance(address(this), address(vault)), 0);
        assertEq(vault.reserve(), 1e6);
        vault.setRedeemEnabled(true);
        tax.mint(address(this), 1 ether);
        tax.approve(address(vault), 1 ether);
        vault.redeem(1 ether, 1e6);
        assertEq(real.balanceOf(address(this)), 1e6);
    }

    function test_QuoteDeltaSyncAndOutflow() public {
        vm.deal(address(vault), 3 ether); // funds arriving without receive()
        vault.withdrawQuote(1 ether); // must sync before spending
        assertEq(vault.accountedQuote(), 2 ether);
        assertEq(address(vault).balance, 2 ether);
        vm.recordLogs();
        vault.sync();
        assertEq(vm.getRecordedLogs().length, 0);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.accountedQuote(), 3 ether);
        vault.withdrawQuote(3 ether);
        assertEq(vault.accountedQuote(), 0);
        assertEq(address(vault).balance, 0);
    }

    function test_RejectUnsupportedQuoteAtAllEntryPoints() public {
        assertTrue(factory.isQuoteTokenSupported(address(0)));
        assertFalse(factory.isQuoteTokenSupported(address(real)));
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data;
        data.quoteToken = address(real);
        (bool ok,) = factory.onBeforeLaunch(abi.encode(data));
        assertFalse(ok);
        vm.prank(PORTAL);
        vm.expectRevert("BNB quote only");
        factory.newVault(address(tax), address(real), address(this), "");
        RedeemVaultV3Upgradeable impl = new RedeemVaultV3Upgradeable();
        vm.expectRevert(RedeemVaultV3Upgradeable.UnsupportedQuote.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                RedeemVaultV3Upgradeable.initialize, (address(tax), address(real), address(this), address(0))
            )
        );
    }

    function test_OnlyPortalCanCreate() public {
        vm.expectRevert("Only VaultPortal");
        factory.newVault(address(tax), address(0), address(this), "");
    }
}

contract SpecUpgrade is RedeemVaultV3Upgradeable {
    function revision() external pure returns (uint256) {
        return 2;
    }
}
