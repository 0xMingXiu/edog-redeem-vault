// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {RedeemVaultBeaconFactory} from "src/RedeemVaultBeacon.sol";

/// @notice Deploys RedeemVaultBeaconFactory to BNB testnet (chainId 97).
contract DeployRedeemVaultBeacon is Script {
    function run() external {
        vm.startBroadcast();
        RedeemVaultBeaconFactory factory = new RedeemVaultBeaconFactory();
        console.log("RedeemVaultBeaconFactory:", address(factory));
        console.log("UpgradeableBeacon:      ", factory.beacon());
        console.log("Implementation:         ", factory.beaconImplementation());
        vm.stopBroadcast();
    }
}
