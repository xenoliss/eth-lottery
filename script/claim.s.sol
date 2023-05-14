// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Lottery} from "../src/Lottery.sol";

import "forge-std/Script.sol";

contract ClaimScript is Script {
    function run() public {
        vm.startBroadcast();

        Lottery lottery = Lottery(0x2ba4f4929fB403091d9460489652415E98B905B8);
        lottery.claimJackpot({receiptId: 3});

        vm.stopBroadcast();
    }
}
