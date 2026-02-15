"use client";

import { useCallback, useEffect, useState } from "react";
import { Address } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { keccak256, toHex } from "viem";
import { useAccount } from "wagmi";
import { useScaffoldEventHistory } from "~~/hooks/scaffold-eth/useScaffoldEventHistory";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth/useScaffoldReadContract";
import { useScaffoldWriteContract } from "~~/hooks/scaffold-eth/useScaffoldWriteContract";
import { notification } from "~~/utils/scaffold-eth";

// localStorage helpers for persisting secret/salt across reloads
const STORAGE_KEY = "commit-reveal-pending";

function savePending(address: string, secret: string, salt: string) {
  try {
    localStorage.setItem(`${STORAGE_KEY}-${address}`, JSON.stringify({ secret, salt }));
  } catch {}
}

function loadPending(address: string): { secret: string; salt: string } | null {
  try {
    const raw = localStorage.getItem(`${STORAGE_KEY}-${address}`);
    if (!raw) return null;
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function clearPending(address: string) {
  try {
    localStorage.removeItem(`${STORAGE_KEY}-${address}`);
  } catch {}
}

// Parse revert reasons into human-readable messages
function parseError(e: unknown): string {
  const msg = (e as Error)?.message || String(e);
  if (msg.includes("user rejected") || msg.includes("User denied")) return "Transaction cancelled";
  if (msg.includes("Hash mismatch")) return "Your secret or salt doesn't match your commitment";
  if (msg.includes("Cannot reveal in same block")) return "Wait for at least one block before revealing";
  if (msg.includes("Commitment expired")) return "Your commitment expired (>256 blocks). Please re-commit.";
  if (msg.includes("Already revealed")) return "This commitment was already revealed";
  if (msg.includes("No commitment found")) return "No commitment found for your address";
  if (msg.includes("Empty hash")) return "Cannot commit an empty hash";
  return "Transaction failed";
}

const Home: NextPage = () => {
  const { address: connectedAddress } = useAccount();

  // Form state
  const [secretInput, setSecretInput] = useState("");
  const [saltInput, setSaltInput] = useState("");
  const [revealSecret, setRevealSecret] = useState("");
  const [revealSalt, setRevealSalt] = useState("");

  // Loading states (separate per button!)
  const [isCommitting, setIsCommitting] = useState(false);
  const [isRevealing, setIsRevealing] = useState(false);

  // Write hooks
  const { writeContractAsync: commitWrite } = useScaffoldWriteContract("CommitReveal");
  const { writeContractAsync: revealWrite } = useScaffoldWriteContract("CommitReveal");

  // Convert text secret to bytes32
  const secretBytes = secretInput ? keccak256(toHex(secretInput)) : undefined;
  const saltBytes = saltInput ? (("0x" + saltInput.replace("0x", "").padStart(64, "0")) as `0x${string}`) : undefined;

  // Use on-chain computeHash — single source of truth (#1)
  const { data: previewHash } = useScaffoldReadContract({
    contractName: "CommitReveal",
    functionName: "computeHash",
    args: [secretBytes, saltBytes],
    query: {
      enabled: !!secretBytes && !!saltBytes,
    },
  });

  // Read commitment for connected user
  const { data: commitment } = useScaffoldReadContract({
    contractName: "CommitReveal",
    functionName: "getCommitment",
    args: [connectedAddress],
  });

  const { data: blocksLeft } = useScaffoldReadContract({
    contractName: "CommitReveal",
    functionName: "blocksUntilExpiry",
    args: [connectedAddress],
  });

  // Event history
  const { data: commitEvents } = useScaffoldEventHistory({
    contractName: "CommitReveal",
    eventName: "Committed",
    fromBlock: 0n,
    watch: true,
  });

  const { data: revealEvents } = useScaffoldEventHistory({
    contractName: "CommitReveal",
    eventName: "Revealed",
    fromBlock: 0n,
    watch: true,
  });

  const hasCommitment =
    commitment && commitment[0] !== "0x0000000000000000000000000000000000000000000000000000000000000000";
  const isRevealed = commitment ? commitment[2] : false;

  // Load persisted secret/salt on mount or address change (#2)
  useEffect(() => {
    if (!connectedAddress) return;
    const pending = loadPending(connectedAddress);
    if (pending) {
      setRevealSecret(pending.secret);
      setRevealSalt(pending.salt);
    }
  }, [connectedAddress]);

  // Generate random salt
  const generateSalt = useCallback(() => {
    const bytes = crypto.getRandomValues(new Uint8Array(32));
    const hex = Array.from(bytes)
      .map(b => b.toString(16).padStart(2, "0"))
      .join("");
    setSaltInput(hex);
  }, []);

  const handleCommit = async () => {
    if (!previewHash || !connectedAddress) return;
    setIsCommitting(true);
    try {
      await commitWrite({
        functionName: "commit",
        args: [previewHash],
      });
      // Persist secret & salt for reveal (#2)
      savePending(connectedAddress, secretInput, saltInput);
      setRevealSecret(secretInput);
      setRevealSalt(saltInput);
      setSecretInput("");
      setSaltInput("");
      notification.success("Commitment submitted! Wait a block, then reveal.");
    } catch (e) {
      console.error("Commit failed:", e);
      notification.error(parseError(e));
    } finally {
      setIsCommitting(false);
    }
  };

  const handleReveal = async () => {
    if (!revealSecret || !revealSalt || !connectedAddress) return;
    setIsRevealing(true);
    try {
      const rSecretBytes = keccak256(toHex(revealSecret));
      const rSaltBytes = ("0x" + revealSalt.replace("0x", "").padStart(64, "0")) as `0x${string}`;
      await revealWrite({
        functionName: "reveal",
        args: [rSecretBytes, rSaltBytes],
      });
      clearPending(connectedAddress);
      notification.success("Secret revealed! Check the random seed below.");
    } catch (e) {
      console.error("Reveal failed:", e);
      notification.error(parseError(e));
    } finally {
      setIsRevealing(false);
    }
  };

  return (
    <div className="flex flex-col items-center gap-8 py-8 px-4">
      {/* Commit Section */}
      <div className="card bg-base-100 shadow-xl w-full max-w-lg">
        <div className="card-body">
          <h2 className="card-title text-2xl">🔒 Commit</h2>
          <p className="text-sm opacity-70">
            Enter a secret and salt. The hash is submitted on-chain — your secret stays hidden.
          </p>

          <div className="form-control gap-2 mt-4">
            <label className="label">
              <span className="label-text font-bold">Secret</span>
            </label>
            <input
              type="text"
              placeholder="Enter your secret message..."
              className="input input-bordered w-full"
              value={secretInput}
              onChange={e => setSecretInput(e.target.value)}
            />

            <label className="label">
              <span className="label-text font-bold">Salt</span>
            </label>
            <div className="flex gap-2">
              <input
                type="text"
                placeholder="Random salt (hex)"
                className="input input-bordered w-full font-mono text-xs"
                value={saltInput}
                onChange={e => setSaltInput(e.target.value)}
              />
              <button className="btn btn-outline btn-sm self-center" onClick={generateSalt}>
                🎲
              </button>
            </div>

            {previewHash && (
              <div className="mt-2 p-3 bg-base-200 rounded-lg">
                <p className="text-xs font-bold opacity-70">Commitment Hash (computed on-chain):</p>
                <p className="text-xs font-mono break-all">{previewHash}</p>
              </div>
            )}

            <button
              className="btn btn-primary mt-4"
              disabled={!previewHash || isCommitting || !connectedAddress}
              onClick={handleCommit}
            >
              {isCommitting ? <span className="loading loading-spinner loading-sm"></span> : null}
              {isCommitting ? "Committing..." : "Commit Hash"}
            </button>
          </div>
        </div>
      </div>

      {/* Current Commitment Status */}
      {hasCommitment && (
        <div className="card bg-base-100 shadow-xl w-full max-w-lg">
          <div className="card-body">
            <h2 className="card-title text-2xl">{isRevealed ? "✅ Revealed" : "⏳ Pending Reveal"}</h2>

            <div className="space-y-2">
              <div>
                <p className="text-xs font-bold opacity-70">Stored Hash:</p>
                <p className="text-xs font-mono break-all">{commitment[0]}</p>
              </div>
              <div>
                <p className="text-xs font-bold opacity-70">Commit Block:</p>
                <p className="font-mono">{commitment[1]?.toString()}</p>
              </div>
              {!isRevealed && blocksLeft !== undefined && (
                <div>
                  <p className="text-xs font-bold opacity-70">Blocks Until Expiry:</p>
                  <p className={`font-mono text-lg ${Number(blocksLeft) < 50 ? "text-error" : "text-success"}`}>
                    {blocksLeft.toString()}
                  </p>
                  {Number(blocksLeft) === 0 && (
                    <p className="text-error text-sm">⚠️ Commitment expired! You must re-commit.</p>
                  )}
                </div>
              )}
            </div>

            {/* Reveal Form */}
            {!isRevealed && Number(blocksLeft) > 0 && (
              <div className="mt-4 space-y-2">
                <label className="label">
                  <span className="label-text font-bold">Secret (to reveal)</span>
                </label>
                <input
                  type="text"
                  placeholder="Your original secret"
                  className="input input-bordered w-full"
                  value={revealSecret}
                  onChange={e => setRevealSecret(e.target.value)}
                />
                <label className="label">
                  <span className="label-text font-bold">Salt (to reveal)</span>
                </label>
                <input
                  type="text"
                  placeholder="Your original salt (hex)"
                  className="input input-bordered w-full font-mono text-xs"
                  value={revealSalt}
                  onChange={e => setRevealSalt(e.target.value)}
                />
                <button
                  className="btn btn-secondary w-full mt-2"
                  disabled={!revealSecret || !revealSalt || isRevealing}
                  onClick={handleReveal}
                >
                  {isRevealing ? <span className="loading loading-spinner loading-sm"></span> : null}
                  {isRevealing ? "Revealing..." : "🔓 Reveal Secret"}
                </button>
              </div>
            )}
          </div>
        </div>
      )}

      {/* Recent Events */}
      <div className="card bg-base-100 shadow-xl w-full max-w-lg">
        <div className="card-body">
          <h2 className="card-title text-2xl">📜 Recent Activity</h2>

          {(!commitEvents || commitEvents.length === 0) && (!revealEvents || revealEvents.length === 0) && (
            <p className="text-sm opacity-50">No commits or reveals yet. Be the first!</p>
          )}

          <div className="space-y-3 mt-2">
            {revealEvents?.slice(0, 5).map((event, i) => (
              <div key={`reveal-${i}`} className="p-3 bg-success/10 rounded-lg border border-success/30">
                <div className="flex items-center gap-2 mb-1">
                  <span className="badge badge-success badge-sm">REVEALED</span>
                  <Address address={event.args.user} />
                </div>
                <p className="text-xs font-mono opacity-70 break-all">Seed: {event.args.randomSeed}</p>
              </div>
            ))}

            {commitEvents?.slice(0, 5).map((event, i) => (
              <div key={`commit-${i}`} className="p-3 bg-info/10 rounded-lg border border-info/30">
                <div className="flex items-center gap-2 mb-1">
                  <span className="badge badge-info badge-sm">COMMITTED</span>
                  <Address address={event.args.user} />
                </div>
                <p className="text-xs font-mono opacity-70">Block: {event.args.commitBlock?.toString()}</p>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* How It Works */}
      <div className="card bg-base-100 shadow-xl w-full max-w-lg">
        <div className="card-body">
          <h2 className="card-title text-2xl">🧠 How It Works</h2>
          <div className="space-y-3 text-sm">
            <div className="flex gap-3">
              <span className="badge badge-primary badge-lg">1</span>
              <div>
                <p className="font-bold">Commit</p>
                <p className="opacity-70">Submit hash(secret, salt) on-chain. Nobody can see your secret.</p>
              </div>
            </div>
            <div className="flex gap-3">
              <span className="badge badge-primary badge-lg">2</span>
              <div>
                <p className="font-bold">Wait</p>
                <p className="opacity-70">
                  At least 1 block must pass. The blockhash of your commit block becomes part of the randomness.
                </p>
              </div>
            </div>
            <div className="flex gap-3">
              <span className="badge badge-primary badge-lg">3</span>
              <div>
                <p className="font-bold">Reveal</p>
                <p className="opacity-70">
                  Submit your secret + salt within 256 blocks. The contract verifies the hash and generates an
                  unpredictable random seed from your secret + the commit block&apos;s blockhash.
                </p>
              </div>
            </div>
            <div className="alert alert-warning mt-2">
              <span>
                ⚠️ You must reveal within 256 blocks (~12 min on Base). After that, blockhash returns zero and your
                commitment expires.
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default Home;
