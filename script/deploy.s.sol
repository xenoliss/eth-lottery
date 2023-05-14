// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Lottery} from "../src/Lottery.sol";

import "forge-std/Script.sol";

contract DeployScript is Script {
    function run() public {
        vm.startBroadcast();

        Lottery lottery = new Lottery({
            link: address(0x779877A7B0D9E8603169DdbD7836e478b4624789),
            vrfV2Wrapper: address(0xab18414CD93297B0d12ac29E63Ca20f515b3DB46),
            _vrfCallbackGasLimit: 30_000,
            _vrfRequestConfirmations: 3
        });

        console.log("Lottery deployed at %s", address(lottery));

        vm.stopBroadcast();
    }
}
