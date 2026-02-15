//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import { DeployCommitReveal } from "./DeployCommitReveal.s.sol";

contract DeployScript is ScaffoldETHDeploy {
    function run() external {
        DeployCommitReveal deployCommitReveal = new DeployCommitReveal();
        deployCommitReveal.run();
    }
}
