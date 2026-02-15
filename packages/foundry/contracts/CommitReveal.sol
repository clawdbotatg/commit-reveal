// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title CommitReveal
 * @notice A starter kit demonstrating the commit-reveal pattern on Ethereum.
 *
 * How it works:
 * 1. COMMIT: User submits hash(secret, salt) — nobody can see the secret.
 * 2. WAIT: At least one block must pass (can't reveal in the same block).
 * 3. REVEAL: User reveals secret + salt. Contract verifies the hash matches
 *    and mixes the secret with the commit block's blockhash to produce
 *    an unpredictable random seed.
 *
 * Why blockhash matters:
 * - The user can't predict the blockhash when they commit
 * - Miners can't know the secret to manipulate the result
 * - blockhash(n) returns 0x0 after 256 blocks, so reveals must be timely
 *
 * The resulting "random seed" is useful for on-chain randomness that's
 * resistant to single-party manipulation (though not multi-party collusion).
 */
contract CommitReveal {
    struct Commitment {
        bytes32 dataHash;      // keccak256(abi.encodePacked(secret, salt))
        uint256 commitBlock;   // block.number when committed
        bool revealed;         // whether this commitment has been revealed
    }

    /// @notice All commitments by address
    mapping(address => Commitment) public commitments;

    /// @notice Emitted when a user commits a hash
    event Committed(address indexed user, bytes32 dataHash, uint256 commitBlock);

    /// @notice Emitted when a user reveals their secret
    event Revealed(
        address indexed user,
        bytes32 secret,
        bytes32 salt,
        bytes32 randomSeed
    );

    /// @notice Commit a hash of your secret + salt
    /// @param dataHash keccak256(abi.encodePacked(secret, salt))
    function commit(bytes32 dataHash) external {
        require(dataHash != bytes32(0), "Empty hash");

        commitments[msg.sender] = Commitment({
            dataHash: dataHash,
            commitBlock: block.number,
            revealed: false
        });

        emit Committed(msg.sender, dataHash, block.number);
    }

    /// @notice Reveal your secret and salt to generate a random seed
    /// @param secret The secret value you committed
    /// @param salt Random salt used to prevent rainbow table attacks
    /// @return randomSeed The unpredictable seed derived from secret + blockhash
    function reveal(bytes32 secret, bytes32 salt) external returns (bytes32 randomSeed) {
        Commitment storage c = commitments[msg.sender];

        require(c.commitBlock != 0, "No commitment found");
        require(!c.revealed, "Already revealed");
        require(block.number > c.commitBlock, "Cannot reveal in same block");

        // THIS IS THE CRITICAL CHECK:
        // blockhash() returns 0x0 for blocks older than 256 blocks.
        // If the user waits too long, they must re-commit.
        bytes32 commitBlockHash = blockhash(c.commitBlock);
        require(commitBlockHash != bytes32(0), "Commitment expired (>256 blocks)");

        // Verify the commitment matches
        bytes32 computedHash = keccak256(abi.encodePacked(secret, salt));
        require(computedHash == c.dataHash, "Hash mismatch");

        // Mark as revealed
        c.revealed = true;

        // Generate the random seed:
        // - secret: only the user knew this
        // - commitBlockHash: only the blockchain knew this at commit time
        // Neither party could predict both values, so the seed is unpredictable
        randomSeed = keccak256(abi.encodePacked(secret, commitBlockHash));

        emit Revealed(msg.sender, secret, salt, randomSeed);
    }

    /// @notice Compute the commitment hash for a given secret and salt
    /// @dev Single source of truth — use this instead of hashing off-chain
    function computeHash(bytes32 secret, bytes32 salt) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(secret, salt));
    }

    /// @notice View a user's commitment details
    function getCommitment(address user)
        external
        view
        returns (bytes32 dataHash, uint256 commitBlock, bool revealed)
    {
        Commitment memory c = commitments[user];
        return (c.dataHash, c.commitBlock, c.revealed);
    }

    /// @notice Check how many blocks remain before a commitment expires
    /// @return blocksLeft 0 if expired or no commitment, otherwise blocks remaining
    function blocksUntilExpiry(address user) external view returns (uint256 blocksLeft) {
        Commitment memory c = commitments[user];
        if (c.commitBlock == 0 || c.revealed) return 0;

        uint256 expiryBlock = c.commitBlock + 256;
        if (block.number >= expiryBlock) return 0;

        return expiryBlock - block.number;
    }
}
