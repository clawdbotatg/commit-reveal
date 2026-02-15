// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DeployHelpers.s.sol";
import "../contracts/CommitReveal.sol";

contract DeployCommitReveal is ScaffoldETHDeploy {
    function run() external ScaffoldEthDeployerRunner {
        new CommitReveal();
    }
}
