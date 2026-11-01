# 审查清单（规范对齐版）— 部署检查 ≠ 安全证明

## 源码位置（本包）

`flap-vault-example/src/RedeemVaultBeacon.sol`  
测试：`flap-vault-example/test/RedeemVault.t.sol`

## 历史 Factory（不包含本次改动）

`0x5172c3fa1B6D5CcA2469e4EeAbFceD30ECc52fEE` (BSC testnet 97)

## 针对上轮意见的实现对照

| 意见 | 实现 |
|---|---|
| 截断尾数 | `_splitTax`：只销毁 convertible，dust 退回用户；pay==0 直接 revert，原转账随交易原子回滚 |
| burn 空实现 | 必须 vault 余额减少 **且** totalSupply 同步减少才记 `burnedTax`，无状态变化才尝试精确转入 DEAD；部分 burn 或仅转走余额必须回滚 |
| minReserve 很小 | `coverageBps` + `coverableTaxUnits`；文案明确 FCFS，非全量担保 |
| 当前实现的储备锁 | lock 后无 withdrawRedeemToken；无 rescue/approve 出口；仅 redeem 出真币；Guardian 升级能改变这些规则；`withdrawQuote` 只动 BNB 税收益 |
| approve 表述 | `previewRedeem` + `redeem(amount,minReceive)` |
| redeemToken 校验 | 非 0 / 非 tax / 非 this / 非 DEAD；set 仅一次 |
| 测试 | 26 项 forge 测试见 TEST_REPORT.txt |

## 仍非证明项

- 未跑 Portal 主路径 E2E（需 Flap testnet Portal）
- 真币外部风险（pause/blacklist）
- 开兑前 operator 仍可撤货

## 本次 PR 修复（尚未部署）

- 允许 Portal 传入尚未部署的税币地址；首次开兑读取 decimals，未就绪拒绝报价/开兑。
- dust 退款同时核对用户实际到账和 Vault 实际扣款；不精确则整笔回滚。
- DEAD 只转本笔 convertible，保留之前余额；部分 burn/转账冒充 burn 回滚。
- 原 12 项测试、6 项回归测试与 8 项规范测试通过；优化参数改为 1000 runs，合约大小检查通过。
- 上方地址是历史部署，不是本次源码；真实 Portal E2E、重新部署和链上验证仍未完成。
- 细节见 FIX_GUIDE.md。本清单和测试均不是安全证明。

## 新部署必验

- Beacon owner 必须等于目标链 Flap Guardian；部署人/operator 无升级权。isVaultUpgradesLocked() 应为 false。
- 官方认证仍需官方合作审计方审核，不因代码满足架构要求自动取得。
- UI schema 覆盖全部业务写操作；金额为原始最小单位，fund 必须外部先 approve 或直接 transfer 备货。
- 保留 Guardian 对受限业务函数的访问；其调用同样受当前 reservesLocked 检查约束。
- 只支持原生 quote；初始化、newVault、launch hook 均拒绝 ERC20 quote。
- 精度极端数值溢出等独立审查残留未在本次规范补丁内修复，见 SPEC_ALIGNMENT.md。
