# 修复说明与上线步骤

本次代码修复和本地测试不是安全证明，未部署链上合约。

## 已修复

1. **Portal 创建顺序**：`initialize` 不再强制调用尚未部署税币的 `decimals()`。使用独立的 `taxDecimalsInitialized` 标记，避免把合法的 0 位精度当成未初始化。首次开兑前读取并校验精度；未就绪的预览明确回滚，覆盖数量返回 0。
2. **尾数退款**：抽出 `_refundDust`，同时校验用户增加量和 Vault 减少量等于 dust。不支持精确退款的收费转账整笔回滚，余额、授权和计数器全部恢复。
3. **销毁范围和真实性**：burn 必须余额与总供应量同时精确减少本笔 convertible；无变化才能 fallback。部分 burn、只转走余额以及 totalSupply 读取失败均拒绝。fallback 只把本笔数量送入 DEAD，校验两端差额，保留此前转入的余额。DEAD 锁定不等于减少总供应量。
4. **失败原子性**：不足储备、低于 minReceive、零兑付直接 revert，无需先转账退款。
5. **部署大小**：原 optimizer_runs=99999 下修复后 runtime 为 25084 bytes，超出 EIP-170。调整至 1000，runtime 为 20841 bytes，余量 3735 bytes；没有开启 viaIR 或修改 Solidity/EVM 版本。部署与源码验证必须使用相同参数。

## 验证

在仓库根目录执行：

```sh
git submodule update --init --recursive
cd flap-vault-example
forge test -vv
forge build --sizes
```

Solidity 0.8.26，optimizer=true/runs=1000，EVM=cancun；本地 Foundry 1.8.7。
原有 12 项测试加 6 项回归测试全部通过。新增覆盖：预测税币地址先建 Vault 后部署代币并开兑、收费 dust 的原子回滚、保留历史余额、部分 burn 拒绝、转账冒充 burn 拒绝、0 decimals。

预测地址测试使用 vm.etch 模拟部署顺序，**不是实际 Portal 主路径 E2E**。构建存在静态 lint 提示，不能据此声称零风险：原生 quote 允许零地址；burn 位于 nonReentrant 的 redeem 中；供应商抽象合约存在收款出口提示。

## 发布前必须完成

1. 复核改动并使用上述编译参数重新构建。
2. 测网重新部署 Factory、Beacon、implementation；已有锁定 Beacon 不能升级。旧 Vault 不会自动修好；本变更不提供存量迁移机制。
3. 通过真实 Flap testnet Portal 创建代币/Vault，验证 Factory 版本、BNB quote、预测地址流程、operator、税币地址、真币地址和精度。
4. 小额备货与真实兑付，核对实际到账、dust、reserve、计数器和事件；保留交易哈希。
5. 确认首次开兑会永久锁定储备出口，无法再关兑或撤出真币。当前储备只保障先到先兑，并非全量担保。
6. 完成后更新部署文档。主网需单独部署和复核，不得使用测网地址。

不承诺支持所有代币：重基准、扣费退款、异常 burn、黑名单、暂停、恶意余额/供应量报告等可能拒绝兑换或带来外部风险。严格校验偏向整笔回滚；第三方代币行为仍需逐个评估。
