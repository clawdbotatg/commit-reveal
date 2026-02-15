// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/CommitReveal.sol";

contract CommitRevealTest is Test {
    CommitReveal public cr;
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    bytes32 constant SECRET = keccak256("my-secret-value");
    bytes32 constant SALT = keccak256("random-salt-123");

    function setUp() public {
        cr = new CommitReveal();
    }

    function _computeHash(bytes32 secret, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(secret, salt));
    }

    // ==================== HAPPY PATH ====================

    function test_CommitAndReveal() public {
        bytes32 dataHash = _computeHash(SECRET, SALT);

        // Commit
        vm.prank(alice);
        cr.commit(dataHash);

        // Check commitment stored
        (bytes32 stored, uint256 commitBlock, bool revealed) = cr.getCommitment(alice);
        assertEq(stored, dataHash);
        assertEq(commitBlock, block.number);
        assertFalse(revealed);

        // Advance one block
        vm.roll(block.number + 1);

        // Reveal
        vm.prank(alice);
        bytes32 seed = cr.reveal(SECRET, SALT);

        // Verify revealed
        (, , bool isRevealed) = cr.getCommitment(alice);
        assertTrue(isRevealed);

        // Seed should be deterministic
        bytes32 expectedSeed = keccak256(abi.encodePacked(SECRET, blockhash(commitBlock)));
        assertEq(seed, expectedSeed);
    }

    function test_CommitEmitsEvent() public {
        bytes32 dataHash = _computeHash(SECRET, SALT);

        vm.expectEmit(true, false, false, true);
        emit CommitReveal.Committed(alice, dataHash, block.number);

        vm.prank(alice);
        cr.commit(dataHash);
    }

    function test_RevealEmitsEvent() public {
        bytes32 dataHash = _computeHash(SECRET, SALT);

        vm.prank(alice);
        cr.commit(dataHash);
        uint256 commitBlock = block.number;

        vm.roll(block.number + 1);

        bytes32 expectedSeed = keccak256(abi.encodePacked(SECRET, blockhash(commitBlock)));

        vm.expectEmit(true, false, false, true);
        emit CommitReveal.Revealed(alice, SECRET, SALT, expectedSeed);

        vm.prank(alice);
        cr.reveal(SECRET, SALT);
    }

    // ==================== FAILURE CASES ====================

    function test_RevertCommitEmptyHash() public {
        vm.prank(alice);
        vm.expectRevert("Empty hash");
        cr.commit(bytes32(0));
    }

    function test_RevertRevealNoCommitment() public {
        vm.prank(alice);
        vm.expectRevert("No commitment found");
        cr.reveal(SECRET, SALT);
    }

    function test_RevertRevealSameBlock() public {
        bytes32 dataHash = _computeHash(SECRET, SALT);

        vm.prank(alice);
        cr.commit(dataHash);

        // Try to reveal in the same block
        vm.prank(alice);
        vm.expectRevert("Cannot reveal in same block");
        cr.reveal(SECRET, SALT);
    }

    function test_RevertRevealWrongSecret() public {
        bytes32 dataHash = _computeHash(SECRET, SALT);

        vm.prank(alice);
        cr.commit(dataHash);
        vm.roll(block.number + 1);

        vm.prank(alice);
        vm.expectRevert("Hash mismatch");
        cr.reveal(keccak256("wrong-secret"), SALT);
    }

    function test_RevertRevealWrongSalt() public {
        bytes32 dataHash = _computeHash(SECRET, SALT);

        vm.prank(alice);
        cr.commit(dataHash);
        vm.roll(block.number + 1);

        vm.prank(alice);
        vm.expectRevert("Hash mismatch");
        cr.reveal(SECRET, keccak256("wrong-salt"));
    }

    function test_RevertDoubleReveal() public {
        bytes32 dataHash = _computeHash(SECRET, SALT);

        vm.prank(alice);
        cr.commit(dataHash);
        vm.roll(block.number + 1);

        vm.prank(alice);
        cr.reveal(SECRET, SALT);

        vm.prank(alice);
        vm.expectRevert("Already revealed");
        cr.reveal(SECRET, SALT);
    }

    function test_RevertRevealAfter256Blocks() public {
        bytes32 dataHash = _computeHash(SECRET, SALT);

        vm.prank(alice);
        cr.commit(dataHash);

        // Roll past the 256 block window
        vm.roll(block.number + 257);

        vm.prank(alice);
        vm.expectRevert("Commitment expired (>256 blocks)");
        cr.reveal(SECRET, SALT);
    }

    // ==================== EDGE CASES ====================

    function test_CommitOverwritesPrevious() public {
        bytes32 hash1 = _computeHash(SECRET, SALT);
        bytes32 secret2 = keccak256("second-secret");
        bytes32 salt2 = keccak256("second-salt");
        bytes32 hash2 = _computeHash(secret2, salt2);

        vm.prank(alice);
        cr.commit(hash1);

        vm.roll(block.number + 1);

        // Overwrite with new commitment
        vm.prank(alice);
        cr.commit(hash2);

        vm.roll(block.number + 1);

        // Old secret should fail
        vm.prank(alice);
        vm.expectRevert("Hash mismatch");
        cr.reveal(SECRET, SALT);

        // New secret should work
        vm.prank(alice);
        cr.reveal(secret2, salt2);
    }

    function test_MultipleUsersIndependent() public {
        bytes32 hashAlice = _computeHash(SECRET, SALT);
        bytes32 secretBob = keccak256("bob-secret");
        bytes32 saltBob = keccak256("bob-salt");
        bytes32 hashBob = _computeHash(secretBob, saltBob);

        vm.prank(alice);
        cr.commit(hashAlice);

        vm.prank(bob);
        cr.commit(hashBob);

        vm.roll(block.number + 1);

        // Both can reveal independently
        vm.prank(alice);
        cr.reveal(SECRET, SALT);

        vm.prank(bob);
        cr.reveal(secretBob, saltBob);
    }

    function test_BlocksUntilExpiry() public {
        // No commitment
        assertEq(cr.blocksUntilExpiry(alice), 0);

        bytes32 dataHash = _computeHash(SECRET, SALT);
        vm.prank(alice);
        cr.commit(dataHash);

        assertEq(cr.blocksUntilExpiry(alice), 256);

        vm.roll(block.number + 100);
        assertEq(cr.blocksUntilExpiry(alice), 156);

        vm.roll(block.number + 156);
        assertEq(cr.blocksUntilExpiry(alice), 0);
    }

    function test_RecommitAfterExpiry() public {
        bytes32 dataHash = _computeHash(SECRET, SALT);

        vm.prank(alice);
        cr.commit(dataHash);

        // Expire
        vm.roll(block.number + 257);

        // Re-commit works
        vm.prank(alice);
        cr.commit(dataHash);

        vm.roll(block.number + 1);

        // Reveal works on new commitment
        vm.prank(alice);
        cr.reveal(SECRET, SALT);
    }

    function test_ComputeHashMatchesManual() public view {
        bytes32 expected = _computeHash(SECRET, SALT);
        bytes32 onChain = cr.computeHash(SECRET, SALT);
        assertEq(onChain, expected);
    }

    function test_DifferentBlocksDifferentSeeds() public {
        // Commit at block N
        bytes32 dataHash = _computeHash(SECRET, SALT);
        vm.prank(alice);
        cr.commit(dataHash);
        vm.roll(block.number + 1);
        vm.prank(alice);
        bytes32 seed1 = cr.reveal(SECRET, SALT);

        // Commit same secret at block N+2
        vm.roll(block.number + 1);
        vm.prank(alice);
        cr.commit(dataHash);
        vm.roll(block.number + 1);
        vm.prank(alice);
        bytes32 seed2 = cr.reveal(SECRET, SALT);

        // Different blocks = different seeds (because different blockhashes)
        assertTrue(seed1 != seed2);
    }
}
