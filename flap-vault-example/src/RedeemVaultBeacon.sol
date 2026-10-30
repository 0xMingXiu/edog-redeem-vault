// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {VaultBaseV3} from "./flap/VaultBaseV3.sol";
import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactoryValidationV2} from "./flap/IVaultFactory.sol";
import {
    VaultUISchema,
    VaultMethodSchema,
    VaultDataSchema,
    FieldDescriptor,
    ApproveAction,
    FactoryPolicy
} from "./flap/IVaultSchemasV1.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

interface IERC20Burnable {
    function burn(uint256 amount) external;
}

interface IERC20Supply {
    function totalSupply() external view returns (uint256);
}

/// @title RedeemVaultV3Upgradeable — hardened 1:1 redeem vault (audit pass 2)
contract RedeemVaultV3Upgradeable is Initializable, VaultBaseV3, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    address public taxToken;
    address public redeemToken;
    address public operator;

    bool public redeemEnabled;
    bool public reservesLocked;

    uint256 public minReserve;

    uint256 public totalRedeemedTax;
    uint256 public totalPaidRedeem;
    uint256 public totalBurnedTax;
    uint256 public totalDeadTax;
    uint256 public totalDustRefunded;

    uint8 public taxDecimals;
    uint8 public redeemDecimals;

    address internal _quoteToken;
    uint256 public accountedQuote;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bool public taxDecimalsInitialized;

    event RedeemTokenSet(address indexed token, uint8 decimals);
    event MinReserveSet(uint256 minReserve);
    event Funded(address indexed from, uint256 amount);
    event RedeemEnabled(bool enabled);
    event ReservesLocked();
    event Redeemed(
        address indexed user,
        uint256 taxRequested,
        uint256 taxReceived,
        uint256 taxDestroyed,
        uint256 dustRefunded,
        uint256 redeemPaid,
        uint256 userReceived,
        bool supplyBurned
    );
    event OperatorTransferred(address indexed previous, address indexed next);
    event RedeemVaultRevenueRecognized(uint256 newRevenue, uint256 accountedTotal);

    error NotOperator();
    error RedeemTokenUnset();
    error AlreadySet();
    error Disabled();
    error BadAmount();
    error InsufficientReserve();
    error ReservesAreLocked();
    error MinReserveUnset();
    error DecimalReadFailed();
    error SlippageTax();
    error SlippageRedeem();
    error ZeroPayout();
    error BadRedeemToken();
    error MinReceive();
    error TaxMetadataNotReady();
    error InvalidTaxDestruction();

    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != _getGuardian()) revert NotOperator();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _taxToken, address quoteToken_, address _operator, address _redeemToken)
        external
        initializer
    {
        __ReentrancyGuard_init();
        require(_taxToken != address(0), "taxToken=0");
        require(_operator != address(0), "operator=0");
        taxToken = _taxToken;
        _quoteToken = quoteToken_;
        operator = _operator;
        // Portal supplies a predicted token address before deployment.
        if (_taxToken.code.length > 0) _ensureTaxDecimals();
        if (_redeemToken != address(0)) {
            _setRedeemToken(_redeemToken);
        }
    }

    function vaultQuoteToken() public view override returns (address) {
        return _quoteToken;
    }

    receive() external payable {
        _syncRevenue();
    }

    function sync() external {
        _syncRevenue();
    }

    function _syncRevenue() internal {
        uint256 bal = _quoteBalance();
        if (bal <= accountedQuote) return;
        uint256 newRevenue = bal - accountedQuote;
        accountedQuote = bal;
        emit RedeemVaultRevenueRecognized(newRevenue, bal);
    }

    function _quoteBalance() internal view returns (uint256) {
        address q = _quoteToken;
        return q == address(0) ? address(this).balance : IERC20(q).balanceOf(address(this));
    }

    function _safeDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            require(d <= 36, "dec");
            return d;
        } catch {
            revert DecimalReadFailed();
        }
    }

    function _ensureTaxDecimals() internal {
        if (taxDecimalsInitialized) return;
        if (taxToken.code.length == 0) revert TaxMetadataNotReady();
        taxDecimals = _safeDecimals(taxToken);
        taxDecimalsInitialized = true;
    }

    /// @dev Split taxReceived into exact convertible + dust. Never destroy dust.
    function _splitTax(uint256 taxReceived) internal view returns (uint256 convertible, uint256 pay, uint256 dust) {
        if (!taxDecimalsInitialized || redeemToken == address(0)) revert TaxMetadataNotReady();
        if (taxDecimals == redeemDecimals) {
            return (taxReceived, taxReceived, 0);
        }
        if (taxDecimals > redeemDecimals) {
            uint256 factor = 10 ** uint256(taxDecimals - redeemDecimals);
            dust = taxReceived % factor;
            convertible = taxReceived - dust;
            pay = convertible / factor;
            return (convertible, pay, dust);
        }
        pay = taxReceived * (10 ** uint256(redeemDecimals - taxDecimals));
        return (taxReceived, pay, 0);
    }

    function transferOperator(address next) external onlyOperator {
        require(next != address(0), "op=0");
        emit OperatorTransferred(operator, next);
        operator = next;
    }

    function setRedeemToken(address token) external onlyOperator {
        if (redeemToken != address(0)) revert AlreadySet();
        _setRedeemToken(token);
    }

    function _setRedeemToken(address token) internal {
        if (token == address(0) || token == taxToken || token == address(this) || token == DEAD) {
            revert BadRedeemToken();
        }
        // also reject quote token if ERC20 quote were used later
        if (token == _quoteToken && _quoteToken != address(0)) revert BadRedeemToken();
        redeemToken = token;
        redeemDecimals = _safeDecimals(token);
        emit RedeemTokenSet(token, redeemDecimals);
    }

    function setMinReserve(uint256 amount) external onlyOperator {
        if (reservesLocked) revert ReservesAreLocked();
        minReserve = amount;
        emit MinReserveSet(amount);
    }

    function fund(uint256 amount) external nonReentrant onlyOperator {
        if (redeemToken == address(0)) revert RedeemTokenUnset();
        if (amount == 0) revert BadAmount();
        uint256 beforeBal = IERC20(redeemToken).balanceOf(address(this));
        // forge-lint: disable-next-line(reentrancy-no-eth)
        IERC20(redeemToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(redeemToken).balanceOf(address(this)) - beforeBal;
        if (received == 0) revert SlippageRedeem();
        emit Funded(msg.sender, received);
    }

    function setRedeemEnabled(bool enabled) external onlyOperator {
        if (!enabled) {
            if (reservesLocked) revert ReservesAreLocked();
            redeemEnabled = false;
            emit RedeemEnabled(false);
            return;
        }
        if (redeemToken == address(0)) revert RedeemTokenUnset();
        _ensureTaxDecimals();
        if (minReserve == 0) revert MinReserveUnset();
        if (IERC20(redeemToken).balanceOf(address(this)) < minReserve) revert InsufficientReserve();

        redeemEnabled = true;
        if (!reservesLocked) {
            reservesLocked = true;
            emit ReservesLocked();
        }
        emit RedeemEnabled(true);
    }

    /// @param amount Tax units to pull (pre-fee intent).
    /// @param minReceive Minimum redeemToken units user must receive (slippage guard).
    function redeem(uint256 amount, uint256 minReceive) external nonReentrant {
        if (!redeemEnabled) revert Disabled();
        if (amount == 0) revert BadAmount();
        if (redeemToken == address(0)) revert RedeemTokenUnset();

        uint256 taxBefore = IERC20(taxToken).balanceOf(address(this));
        // forge-lint: disable-next-line(reentrancy-no-eth)
        IERC20(taxToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 taxReceived = IERC20(taxToken).balanceOf(address(this)) - taxBefore;
        if (taxReceived == 0) revert SlippageTax();

        (uint256 convertible, uint256 pay, uint256 dust) = _splitTax(taxReceived);
        if (pay == 0) revert ZeroPayout();
        if (pay < minReceive) revert MinReceive();
        if (IERC20(redeemToken).balanceOf(address(this)) < pay) revert InsufficientReserve();
        if (dust > 0) _refundDust(dust);

        bool supplyBurned = _destroyTax(convertible);

        uint256 userBefore = IERC20(redeemToken).balanceOf(msg.sender);
        // forge-lint: disable-next-line(reentrancy-no-eth)
        IERC20(redeemToken).safeTransfer(msg.sender, pay);
        uint256 userGot = IERC20(redeemToken).balanceOf(msg.sender) - userBefore;
        if (userGot != pay || userGot < minReceive) revert SlippageRedeem();

        unchecked {
            totalRedeemedTax += convertible;
            totalPaidRedeem += pay;
            if (supplyBurned) totalBurnedTax += convertible;
            else totalDeadTax += convertible;
        }

        // forge-lint: disable-next-line(reentrancy-events)
        emit Redeemed(msg.sender, amount, taxReceived, convertible, dust, pay, userGot, supplyBurned);
    }

    function _refundDust(uint256 dust) internal {
        uint256 userBeforeDust = IERC20(taxToken).balanceOf(msg.sender);
        uint256 vaultBeforeDust = IERC20(taxToken).balanceOf(address(this));
        IERC20(taxToken).safeTransfer(msg.sender, dust);
        uint256 userAfterDust = IERC20(taxToken).balanceOf(msg.sender);
        uint256 vaultAfterDust = IERC20(taxToken).balanceOf(address(this));
        if (
            userAfterDust < userBeforeDust || userAfterDust - userBeforeDust != dust || vaultAfterDust > vaultBeforeDust
                || vaultBeforeDust - vaultAfterDust != dust
        ) revert SlippageTax();
        totalDustRefunded += dust;
    }

    /// @dev Only count supplyBurned if vault balance drops AND totalSupply drops by the same amount.
    function _destroyTax(uint256 amt) internal returns (bool supplyBurned) {
        uint256 balBefore = IERC20(taxToken).balanceOf(address(this));
        require(balBefore >= amt, "bal");

        // A failed supply read is not evidence of destruction.
        uint256 supplyBefore = IERC20Supply(taxToken).totalSupply();
        try IERC20Burnable(taxToken).burn(amt) {} catch {}
        uint256 balAfterBurn = IERC20(taxToken).balanceOf(address(this));
        uint256 supplyAfterBurn = IERC20Supply(taxToken).totalSupply();
        if (
            balAfterBurn <= balBefore && balBefore - balAfterBurn == amt && supplyAfterBurn <= supplyBefore
                && supplyBefore - supplyAfterBurn == amt
        ) return true;
        // Reject ambiguous partial or transfer-only burns.
        if (balAfterBurn != balBefore || supplyAfterBurn != supplyBefore) revert InvalidTaxDestruction();
        uint256 deadBefore = IERC20(taxToken).balanceOf(DEAD);
        IERC20(taxToken).safeTransfer(DEAD, amt);
        uint256 deadAfter = IERC20(taxToken).balanceOf(DEAD);
        uint256 balAfter = IERC20(taxToken).balanceOf(address(this));
        if (
            deadAfter < deadBefore || deadAfter - deadBefore != amt || balAfter > balBefore
                || balBefore - balAfter != amt
        ) revert SlippageTax();
        return false;
    }

    /// @notice Only BEFORE first open. No other redeemToken exit exists.
    function withdrawRedeemToken(uint256 amount) external nonReentrant onlyOperator {
        if (reservesLocked) revert ReservesAreLocked();
        if (redeemToken == address(0)) revert RedeemTokenUnset();
        // forge-lint: disable-next-line(reentrancy-no-eth)
        IERC20(redeemToken).safeTransfer(msg.sender, amount);
    }

    /// @notice Tax revenue (quote) only — never touches redeemToken.
    function withdrawQuote(uint256 amount) external nonReentrant onlyOperator {
        _syncRevenue();
        require(amount > 0 && amount <= accountedQuote, "amt");
        accountedQuote -= amount;
        address q = _quoteToken;
        if (q == address(0)) {
            // forge-lint: disable-next-line(reentrancy-eth)
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            require(ok, "bnb");
        } else {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            IERC20(q).safeTransfer(msg.sender, amount);
        }
    }

    function reserve() public view returns (uint256) {
        if (redeemToken == address(0)) return 0;
        return IERC20(redeemToken).balanceOf(address(this));
    }

    function coverableTaxUnits() public view returns (uint256) {
        if (!taxDecimalsInitialized) return 0;
        uint256 r = reserve();
        if (r == 0 || redeemToken == address(0)) return 0;
        if (taxDecimals == redeemDecimals) return r;
        if (taxDecimals > redeemDecimals) {
            return r * (10 ** uint256(taxDecimals - redeemDecimals));
        }
        return r / (10 ** uint256(redeemDecimals - taxDecimals));
    }

    /// @notice reserve / minReserve in bps (10000 = 100%). minReserve is a self-declared floor, NOT full-float coverage.
    function coverageBps() public view returns (uint256) {
        if (minReserve == 0) return 0;
        return (reserve() * 10_000) / minReserve;
    }

    /// @notice Preview without state changes. `expectedReceive` uses post-fee `taxIn` if known; here assumes `amount` received.
    function previewRedeem(uint256 amount)
        external
        view
        returns (uint256 expectedReceive, uint256 dustRefund, uint256 convertible)
    {
        (convertible, expectedReceive, dustRefund) = _splitTax(amount);
    }

    function status()
        external
        view
        returns (
            bool enabled,
            bool locked,
            address redeemTok,
            uint256 reserveAmt,
            uint256 minRes,
            uint256 coverableTax,
            uint256 covBps,
            uint256 redeemedTax,
            uint256 paidRedeem,
            uint256 burnedTax,
            uint256 deadTax,
            uint256 dustRefunded,
            uint8 taxDec,
            uint8 redeemDec
        )
    {
        enabled = redeemEnabled;
        locked = reservesLocked;
        redeemTok = redeemToken;
        reserveAmt = reserve();
        minRes = minReserve;
        coverableTax = coverableTaxUnits();
        covBps = coverageBps();
        redeemedTax = totalRedeemedTax;
        paidRedeem = totalPaidRedeem;
        burnedTax = totalBurnedTax;
        deadTax = totalDeadTax;
        dustRefunded = totalDustRefunded;
        taxDec = taxDecimals;
        redeemDec = redeemDecimals;
    }

    function description() public view override returns (string memory) {
        if (redeemToken == address(0)) {
            return unicode"RedeemVault: redeem unset. First-come redeem once open; minReserve is floor not full-float guarantee.";
        }
        if (!redeemEnabled) {
            return unicode"RedeemVault: CLOSED. Open is one-way; then FCFS against reserve.";
        }
        return unicode"RedeemVault: OPEN+LOCKED. Whole-token 1:1, FCFS vs reserve — not full circulating guarantee.";
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "RedeemVault";
        schema.description =
            unicode"Hardened V3 vault: dust refund, proven supply-burn or DEAD, minReceive, one-way lock. FCFS vs reserve.";

        schema.methods = new VaultMethodSchema[](5);
        schema.methods[0].name = "status";
        schema.methods[0].description = unicode"On-chain proof + coverageBps (vs minReserve floor).";
        schema.methods[0].inputs = new FieldDescriptor[](0);
        schema.methods[0].outputs = new FieldDescriptor[](14);
        schema.methods[0].outputs[0] = FieldDescriptor("enabled", "bool", "", 0);
        schema.methods[0].outputs[1] = FieldDescriptor("locked", "bool", "", 0);
        schema.methods[0].outputs[2] = FieldDescriptor("redeemTok", "address", "", 0);
        schema.methods[0].outputs[3] = FieldDescriptor("reserveAmt", "uint256", "", 0);
        schema.methods[0].outputs[4] = FieldDescriptor("minRes", "uint256", "", 0);
        schema.methods[0].outputs[5] = FieldDescriptor("coverableTax", "uint256", "", 0);
        schema.methods[0].outputs[6] = FieldDescriptor("covBps", "uint256", "reserve/minReserve bps", 0);
        schema.methods[0].outputs[7] = FieldDescriptor("redeemedTax", "uint256", "", 0);
        schema.methods[0].outputs[8] = FieldDescriptor("paidRedeem", "uint256", "", 0);
        schema.methods[0].outputs[9] = FieldDescriptor("burnedTax", "uint256", "proven supply burn", 0);
        schema.methods[0].outputs[10] = FieldDescriptor("deadTax", "uint256", "DEAD locked", 0);
        schema.methods[0].outputs[11] = FieldDescriptor("dustRefunded", "uint256", "", 0);
        schema.methods[0].outputs[12] = FieldDescriptor("taxDec", "uint8", "", 0);
        schema.methods[0].outputs[13] = FieldDescriptor("redeemDec", "uint8", "", 0);
        schema.methods[0].approvals = new ApproveAction[](0);

        schema.methods[1].name = "previewRedeem";
        schema.methods[1].description = unicode"Preview payout + dust (assumes amount fully received).";
        schema.methods[1].inputs = new FieldDescriptor[](1);
        schema.methods[1].inputs[0] = FieldDescriptor("amount", "uint256", "", 0);
        schema.methods[1].outputs = new FieldDescriptor[](3);
        schema.methods[1].outputs[0] = FieldDescriptor("expectedReceive", "uint256", "", 0);
        schema.methods[1].outputs[1] = FieldDescriptor("dustRefund", "uint256", "", 0);
        schema.methods[1].outputs[2] = FieldDescriptor("convertible", "uint256", "", 0);
        schema.methods[1].approvals = new ApproveAction[](0);

        schema.methods[2].name = "redeem";
        schema.methods[2].description = unicode"Redeem with minReceive slippage guard.";
        schema.methods[2].inputs = new FieldDescriptor[](2);
        schema.methods[2].inputs[0] = FieldDescriptor("amount", "uint256", "tax amount to pull", 0);
        schema.methods[2].inputs[1] = FieldDescriptor("minReceive", "uint256", "min redeemToken out", 0);
        schema.methods[2].outputs = new FieldDescriptor[](0);
        schema.methods[2].approvals = new ApproveAction[](1);
        schema.methods[2].approvals[0] = ApproveAction("taxToken", "amount");
        schema.methods[2].isWriteMethod = true;

        schema.methods[3].name = "fund";
        schema.methods[3].description = unicode"Operator fund redeemToken.";
        schema.methods[3].inputs = new FieldDescriptor[](1);
        schema.methods[3].inputs[0] = FieldDescriptor("amount", "uint256", "", 0);
        schema.methods[3].outputs = new FieldDescriptor[](0);
        schema.methods[3].approvals = new ApproveAction[](1);
        schema.methods[3].approvals[0] = ApproveAction("redeemToken", "amount");
        schema.methods[3].isWriteMethod = true;

        schema.methods[4].name = "setRedeemEnabled";
        schema.methods[4].description = unicode"Open (one-way). Cannot close after lock.";
        schema.methods[4].inputs = new FieldDescriptor[](1);
        schema.methods[4].inputs[0] = FieldDescriptor("enabled", "bool", "", 0);
        schema.methods[4].outputs = new FieldDescriptor[](0);
        schema.methods[4].approvals = new ApproveAction[](0);
        schema.methods[4].isWriteMethod = true;
    }
}

contract RedeemVaultBeaconFactory is VaultFactoryBaseV2 {
    address public immutable beacon;

    constructor() {
        RedeemVaultV3Upgradeable impl = new RedeemVaultV3Upgradeable();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl));
        beacon = address(b);
        b.renounceOwnership();
    }

    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        require(msg.sender == _getVaultPortal(), unicode"Only VaultPortal");
        address redeemTok = address(0);
        if (vaultData.length > 0) {
            redeemTok = abi.decode(vaultData, (address));
        }
        vault = address(
            new BeaconProxy(
                beacon, abi.encodeCall(RedeemVaultV3Upgradeable.initialize, (taxToken, quoteToken, creator, redeemTok))
            )
        );
    }

    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool) {
        return quoteToken == address(0);
    }

    function factorySpecVersion() public pure override returns (string memory) {
        return "v2.3";
    }

    function tokenCreationPolicies() public pure override returns (FactoryPolicy[] memory policies) {
        policies = new FactoryPolicy[](1);
        policies[0] = FactoryPolicy({
            target: "quoteToken", operator: "eq", value: abi.encode(address(0)), description: "Native BNB quote only."
        });
    }

    function isVaultUpgradesLocked() external view returns (bool) {
        return UpgradeableBeacon(beacon).owner() == address(0);
    }

    function beaconImplementation() external view returns (address) {
        return UpgradeableBeacon(beacon).implementation();
    }

    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory data)
        internal
        pure
        override
        returns (bool success, string memory reason)
    {
        if (data.quoteToken != address(0)) return (false, "BNB quote only");
        return (true, "");
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = unicode"Hardened RedeemVault V3; upgrades locked; FCFS redeem vs reserve.";
        schema.fields = new FieldDescriptor[](1);
        schema.fields[0] = FieldDescriptor("redeemToken", "address", "Real token or 0x0", 0);
        schema.isArray = false;
    }
}
