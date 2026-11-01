# BSC Testnet Factory (audit pass-2)

| 项 | 值 |
|---|---|
| Factory | `0x5172c3fa1B6D5CcA2469e4EeAbFceD30ECc52fEE` |
| Tx | `0x8f7c9c87924a9dc9c44ebc6aee30ebfe5d6f0e8061521a02095ecf57096fbdbb` |
| Deployer | `0x721Bc63Ab6d452c98DD1d750146bCDf89c40A477` |
| Spec | v2.3, upgrades locked |

> Historical deployment only: this address is not the patched PR implementation. The beacon is documented as locked, so existing Vaults on this Factory do not receive later fixes.

BSC mainnet Factory: `0x6ca5994E7523A770558fB7FC66a581D578559b4b`. See `MAINNET_DEPLOY.md`.

## Guardian owner check

The new source transfers Beacon ownership to the chain Guardian instead of renouncing it. Check `beaconOwner()` and `UpgradeableBeacon.owner()` against the official address for the target chain. On BSC testnet (97): `0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950`; on BSC mainnet (56): `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b`.
