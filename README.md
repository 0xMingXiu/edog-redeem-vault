# edog-redeem-vault

BSC Flap Custom Vault: hardened 1:1 redeem (mapping token → real token).

> **Not a security audit certificate.** Source + forge tests for third-party review.

## Layout

- `flap-vault-example/src/RedeemVaultBeacon.sol` — vault + factory
- `flap-vault-example/test/RedeemVault.t.sol` — original forge tests (12 cases)
- `flap-vault-example/test/AuditRepro.t.sol` — six audit regression tests
- `flap-vault-example/test/FlapSpec.t.sol` — eight protocol integration unit tests
- `SPEC_ALIGNMENT.md` — Guardian governance, UI and funding instructions
- `AUDIT_CHECKLIST.md` — review checklist
- `TEST_REPORT.txt` — local test log
- `TESTNET_DEPLOY.md` — BSC testnet factory addresses
- `MAINNET_DEPLOY.md` — BSC mainnet factory

## Current source

Beacon ownership is transferred exclusively to the chain-specific Flap Guardian at construction. The deployer/operator cannot upgrade. Guardian upgrades can change the current redemption/withdrawal rules; reserve locks are not immutable guarantees. This code has not received Flap verification.

26 local tests pass. Real Portal E2E and live frontend checks remain outstanding. Funding requires a separate approval on the real-token contract, or a direct token transfer to the vault; the standard schema does not guarantee automatic `redeemToken` approval.

## Historical Testnet Factory (pass-2)

`0x5172c3fa1B6D5CcA2469e4EeAbFceD30ECc52fEE` (chainId 97)  
`factorySpecVersion` = `v2.3`, beacon upgrades locked at deploy.

**This address predates the fixes in this PR and is not a deployment of the patched source.** BSC mainnet Factory `0x6ca5994E7523A770558fB7FC66a581D578559b4b` is recorded in `MAINNET_DEPLOY.md`.

See `FIX_GUIDE.md` for fixes, compatibility constraints and release steps.

## Build / test

```bash
cd flap-vault-example
forge install # if libs missing
forge test -vv
forge build --sizes
```

## Spec

https://docs.flap.sh/flap/developers/vault-developers/vault-and-vaultfactory-specification
