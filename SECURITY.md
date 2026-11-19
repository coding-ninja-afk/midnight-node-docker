# SECURITY: Key management for a Midnight validator (FNO)

Scope: a Founding Node Operator running a Midnight block producer in a production cloud.
Sources: the Midnight docs (signature schemes, node key env vars). Where the docs are silent
(registration and rotation procedure), this document says so and falls back on how Substrate
and partner chains generally work. Those parts should be confirmed with Midnight governance.

## 0. Key inventory: what we are protecting

| Key | Scheme | Used for | Where it must live | If compromised |
|-----|--------|----------|--------------------|----------------|
| AURA | sr25519 | authoring blocks in our slots | **hot**: node keystore, every 6 s | attacker can author blocks as us, including equivocating (two blocks per slot) |
| GRANDPA | ed25519 | finality votes | **hot**: node keystore | attacker can double-vote, which threatens finality |
| Cross-chain / BEEFY | ECDSA | partner-chain consensus messages, BEEFY proofs | **hot**: node keystore | forged bridge/committee signatures |
| Node key | ed25519 (libp2p) | P2P identity | node | peer impersonation. Low impact, but it should stay stable |
| Cardano cold / payment keys | ed25519 | signing the registration of the keys above on Cardano | **cold**: offline, never on the node | attacker can re-register our seat to their keys |
| DB / indexer secrets | password, 32-byte key | db-sync Postgres login, `APP__INFRA__SECRET` | secrets manager | data exposure, no consensus impact |

Design rule: **cold keys decide who the validator is, hot keys do the work.** If a hot key
leaks, rotate it. If a cold key leaks, the seat itself is lost. So the cold keys get the
strongest controls, and the hot keys get the strongest controls that still let them sign every 6 s.

## 1. Key storage

### Options and trade-offs

| Option | Strengths | Weaknesses for *this* workload |
|--------|-----------|--------------------------------|
| **HSM** (CloudHSM, Cloud HSM, Azure Managed HSM, or offline YubiHSM/Ledger) | key never leaves the device, FIPS 140-3 L3, strong audit | most HSMs don't support **sr25519**, and the Substrate keystore has no PKCS#11 backend, so AURA can't sign inside one without a custom remote signer. Costly (a dedicated cluster, ×2 for HA). Signing latency sits on the 6 s slot path |
| **KMS** (AWS KMS, GCP KMS) | cheap, IAM-scoped, every use logged, supports envelope encryption, some providers sign ECDSA natively | same algorithm gap: no sr25519, and ed25519 support varies by provider. Best used to **encrypt** key material, not to sign with it here |
| **Secrets manager** (AWS SM, GCP SM, Vault) | versioning, rotation hooks, fine-grained IAM, audit | the plaintext seed reaches the node's memory, so its security comes down to IAM and host hardening |
| Plain file on disk / env var / image | none | ends up in snapshots, backups, `docker inspect`, `/proc/*/environ` and CI logs. **Not acceptable** |

### Recommendation: split by key class

**Cold keys (Cardano registration and governance):**
- Generate them on an **air-gapped machine or hardware wallet/HSM**, never in the cloud.
  Store them encrypted, with Shamir/multi-party custody, in two separate locations.
- Sign registration transactions offline. The online side only builds the unsigned
  transaction and submits the signed one.
- Two-person rule: one person prepares, a second checks the public keys against the node's
  `author_rotateKeys` output before signing.

**Hot session keys (AURA / GRANDPA / cross-chain):**
- **Envelope-encrypt** the seeds with a KMS key in a dedicated security account. Only the
  validator's instance role may `Decrypt`, gated on the instance and VPC endpoint.
- Keep the ciphertext in the **secrets manager**. At boot, a small init step fetches and
  decrypts it into **tmpfs** (`/run/midnight-keys`, mode 0400, owned by the node UID) and
  passes `AURA_SEED_FILE` / `GRANDPA_SEED_FILE` / `CROSS_CHAIN_SEED_FILE`. Seeds never touch
  the persistent volume, so they are never in disk snapshots or chain-data backups.
- **No env vars, no Terraform-managed secret values** (they end up in state). Terraform only
  creates the empty secret and the IAM wiring, and the value is set out of band.
- Harden the host: single-tenant VM, IMDSv2 with hop limit 1 so containers can't reach the
  role, no SSH (use SSM / IAP), read-only root FS, RPC bound to localhost with `--rpc-methods Safe`.
- Consider **confidential computing** (Nitro Enclaves, Confidential VMs) as the step up from
  this: it reduces exposure from host compromise without an HSM's algorithm limits.
- **Alert on every secret read**: a `GetSecretValue`/`Decrypt` outside a node boot pages
  on-call. Reads are rare, so any one is meaningful.

**One rule that outranks HA:** never let two machines hold the same AURA/GRANDPA keys and run
at the same time. Two signers produce equivocation (double blocks or votes), which can be
penalised and harms the network. Failover is **active/passive with fencing**: the standby has
no keys until the primary is proven down.

**Lesson from this repo:** on 2026-11-19 the only copy of the DB credentials was a git-ignored
local folder that got deleted (RUNBOOK section 10). Any secret that exists in only one place
is a liability. Keep it in the secrets manager, with versioning, from the start.

## 2. Key rotation (registered session keys)

> The Midnight docs read so far do not document the registration or rotation transaction.
> The flow below is the Substrate/partner-chains pattern. Confirm the governance steps and the
> activation boundary with Midnight before running it.

1. **Prepare (T-7d).** Rehearse the full flow on **Preview**. Announce the maintenance window
   to the other FNOs. Confirm monitoring shows "blocks authored" and "finality votes" for our
   validator, because those are the signals that confirm success.
2. **Generate new keys on the running node** (`author_rotateKeys`, from localhost only). The
   node now holds *both* old and new keys and keeps signing with the old ones. Back up the new
   seeds into a new secret version (encrypted, as in section 1).
3. **Register the new public keys** with the offline cold key (two-person check of the keys).
4. **Wait for activation** at the boundary governance defines (a session or epoch). Keep the
   old keys until then. Removing them early leaves a gap where we sign with nothing and miss slots.
5. **Verify** after activation: our validator authors blocks and votes with the **new** keys,
   and nothing is signed with the old ones.
6. **Retire the old keys**: delete them from the keystore and the secret store, and confirm no
   backup or snapshot holds a copy.

| Risk | Mitigation |
|------|------------|
| Gap: old key removed before the new one is active, so missed slots | step 4: keep both until verified |
| Two signers during the switch, so equivocation | rotate **in place** on the same node, never by bringing up a second node with new keys |
| Wrong public key registered, so the seat is lost or the node can't author | two-person check, Preview rehearsal |
| Registration tx fails or isn't included | watch for inclusion. The old keys stay valid until it lands |
| Old seed copies linger | step 6 plus snapshot hygiene (seeds only in tmpfs) |

## 3. Incident response: "my signing key may have been exposed"

1. **Escalate and coordinate.** Open an incident with one incident commander, and notify
   Midnight security/governance and the other FNOs right away. *Why first:* if the key really
   leaked, stopping our node doesn't stop the attacker signing. Only a registration change
   revokes the key, and other validators need to watch for equivocation signed with it.
2. **Contain and rotate.**
   - Snapshot the host and pull the logs before changing anything.
   - Revoke the access path the key may have leaked through (IAM role sessions, SSH or SSM
     access, CI tokens).
   - Generate new keys on a **clean** host and register them by the section 2 flow, fast-tracked.
   - Make sure only one instance can sign while this happens.

   *Why:* this shortens the window in which the stolen key is useful, without destroying
   evidence or causing equivocation ourselves.
3. **Scope and confirm.**
   - Check the audit trail (secret reads, KMS decrypts, host and session logs) to find what
     was accessed, when and by whom.
   - Check other keys sharing that blast radius (same secret store, host or CI).
   - Check the chain for blocks or votes signed with the key that did not come from our node.
     That is proof of compromise, versus a false alarm.

   *Why:* it decides whether this stays a hot-key rotation or becomes a cold-key or
   infrastructure-wide compromise, and it provides the facts for the post-mortem.
