# 审查清单（pass-2）— 部署检查 ≠ 安全证明

## 源码位置（本包）

`flap-vault-example/src/RedeemVaultBeacon.sol`  
测试：`flap-vault-example/test/RedeemVault.t.sol`

## Factory

`0x5172c3fa1B6D5CcA2469e4EeAbFceD30ECc52fEE` (BSC testnet 97)

## 针对上轮意见的实现对照

| 意见 | 实现 |
|---|---|
| 截断尾数 | `_splitTax`：只销毁 convertible，dust 退回用户；pay==0 revert 并退款 |
| burn 空实现 | 必须 vault 余额减少 **且** totalSupply 同步减少才记 `burnedTax`，否则 DEAD + `deadTax` |
| minReserve 很小 | `coverageBps` + `coverableTaxUnits`；文案明确 FCFS，非全量担保 |
| 永久锁定出口 | lock 后无 withdrawRedeemToken；无 rescue/approve 出口；仅 redeem 出真币；`withdrawQuote` 只动 BNB 税收益 |
| approve 表述 | `previewRedeem` + `redeem(amount,minReceive)` |
| redeemToken 校验 | 非 0 / 非 tax / 非 this / 非 DEAD；set 仅一次 |
| 测试 | 12 项 forge 测试见 TEST_REPORT.txt |

## 仍非证明项

- 未跑 Portal 主路径 E2E（需 Flap testnet Portal）
- 真币外部风险（pause/blacklist）
- 开兑前 operator 仍可撤货
