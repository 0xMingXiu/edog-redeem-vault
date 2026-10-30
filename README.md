# edog-redeem-vault

BSC Flap Custom Vault: hardened 1:1 redeem (mapping token → real token).

> **Not a security audit certificate.** Source + forge tests for third-party review.

## Layout

- `flap-vault-example/src/RedeemVaultBeacon.sol` — vault + factory
- `flap-vault-example/test/RedeemVault.t.sol` — original forge tests (12 cases)
- `flap-vault-example/test/AuditRepro.t.sol` — six audit regression tests
- `AUDIT_CHECKLIST.md` — review checklist
- `TEST_REPORT.txt` — local test log
- `TESTNET_DEPLOY.md` — BSC testnet factory addresses

## Historical Testnet Factory (pass-2)

`0x5172c3fa1B6D5CcA2469e4EeAbFceD30ECc52fEE` (chainId 97)  
`factorySpecVersion` = `v2.3`, beacon upgrades locked at deploy.

**This address predates the fixes in this PR and is not a deployment of the patched source.** A fresh Factory/Beacon/implementation deployment and a real Portal end-to-end test are required. No on-chain deployment was performed for this patch.

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
