# Flap 规范对齐说明

依据：[Vault & VaultFactory Specification](https://docs.flap.sh/flap/developers/vault-developers/vault-and-vaultfactory-specification)。本次是源码修改和本地验证，没有链上部署，也不代表取得低风险认证或安全证明。

## 架构和权限

- 延续 VaultBaseV3 / Factory v2.3；只支持原生 quote（BSC 上为 BNB）。预检、Factory 创建和 Vault 初始化一致拒绝 ERC20 quote。
- 新 Factory 的 Beacon 构造时转给 `_getGuardian()`。部署人、operator、Factory 均不持有升级权。增加 `beaconOwner()` 查询；保留 `isVaultUpgradesLocked()` 的真实语义，新部署返回 false。
- Guardian 继续拥有业务权限。首次开兑后，当前实现拒绝任何人关兑和撤储备，包括 Guardian；但 Guardian 可升级实现，因此锁定并非永久不可变保证。Guardian 也可通过 Beacon 的 Ownable 接口变更所有权或自行放弃权限，应监控后续所有权变化。
- 此次没有改变 storage 字段排列。升级测试只证明本次测试升级的状态保持，不保证所有未来升级安全。
- 已 renounce 的历史 Beacon 无法迁移到此模式，须新部署；老 Vault 不自动修复。

## 自动 UI 与备货

Schema 现在提供 status、previewRedeem、redeem、fund、setRedeemEnabled、setRedeemToken、setMinReserve、withdrawRedeemToken、withdrawQuote、transferOperator、sync，以及 taxToken/redeemToken/operator/guardian 地址查询。

所有代币金额均使用最小单位（RAW units）；1 个 6 位精度真币应填 1000000，1 个 18 位税币应填 1000000000000000000。status 展示两种精度；不是把所有币统一当 18 位。

官方 schema 只明确标准识别 taxToken/lpToken，未知授权类型会被忽略。本次移除 fund 的非标准 redeemToken 自动授权声明，明确说明前置步骤：

1. 设置真实 redeemToken（仅一次），然后设置 minReserve（真币最小单位）。
2. 使用 operator 或 Guardian，在**真币合约**上调用 approve(Vault地址, amount)，再在 Vault 调用 fund(amount)。Vault 不能替用户授权；本次未增加任何无限授权。
3. 也可直接向 Vault 地址 transfer 真币，reserve() 读取实际余额，不需要 approve/fund；直接转账不触发 Funded 事件。
4. 核对 reserve 和配置后 setRedeemEnabled(true)。当前实现随即锁定撤货/关闭出口；先到先兑，不保证全流通覆盖。

用户 redeem 仍保留标准 taxToken 自动授权信息。BNB 收入可由 operator/Guardian 通过 withdrawQuote 提走，不用于自动购买真币；本 Vault 不另外抽取兑换手续费，不代表第三方税币或平台没有费用。

## 验证与边界

8 项新增测试覆盖：主/测网 Guardian 归属、越权升级/转移拒绝、Guardian 升级后状态保留、operator 变更后 Guardian 仍可管理且遵守储备锁、schema 的配置/授权/开兑流程和读接口解码、直接备货及兑付、收入延迟同步和支出基线、各入口拒绝不支持的 quote、仅 VaultPortal 可创建。

加上原 18 项共 26 项。Solidity 0.8.26、optimizer runs=1000、Cancun 未变。测试使用 mock token、prank、vm.deal/vm.etch，不是链上 Guardian 实际执行升级，也不是真实 Portal E2E 或官网前端验收。

部署前仍需：真实测网 Portal 发币和小额兑付、官网 schema 渲染/授权检查、对新合约源码和链上字节码验证、官方认证流程。未擅自部署、合并 PR 或申请认证。

## 独立审查残留

本次针对协议/权限/UI 对齐，没有宣称修复全部独立审查发现：极端金额精度乘法及 coverageBps 中间运算仍可能溢出；开兑前可撤货、FCFS、总供应量读取依赖、精度快照、误转税币无法取回和不兼容转账行为仍需评估。异常大额请求回滚不自动证明正常小额业务被全局阻断，应分别复现报价/status 和兑换路径。上线前要继续审查这些边界。
