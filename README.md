# edog-redeem-vault

BSC Flap Custom Vault: hardened 1:1 redeem (mapping token → real token).

> **Not a security audit certificate.** Source + forge tests for third-party review.

## Layout

- `flap-vault-example/src/RedeemVaultBeacon.sol` — vault + factory
- `flap-vault-example/test/RedeemVault.t.sol` — forge tests (12/12)
- `AUDIT_CHECKLIST.md` — review checklist
- `TEST_REPORT.txt` — local test log
- `TESTNET_DEPLOY.md` — BSC testnet factory addresses

## Testnet Factory (pass-2)

`0x5172c3fa1B6D5CcA2469e4EeAbFceD30ECc52fEE` (chainId 97)  
`factorySpecVersion` = `v2.3`, beacon upgrades locked at deploy.

## Build / test

```bash
cd flap-vault-example
forge install # if libs missing
forge test --match-path test/RedeemVault.t.sol -vv
```

## Spec

https://docs.flap.sh/flap/developers/vault-developers/vault-and-vaultfactory-specification
