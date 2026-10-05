// SPDX-License-Identifier: MIT
// Copyright (c) 2026 IXS
pragma solidity 0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev ERC-7540 (https://eips.ethereum.org/EIPS/eip-7540) — not yet shipped by OpenZeppelin, so
///      declared locally, matching the EIP text.
interface IERC7540Operator {
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    function setOperator(address operator, bool approved) external returns (bool);
    function isOperator(address controller, address operator) external view returns (bool status);
}

interface IERC7540Deposit is IERC7540Operator {
    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );

    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 pendingAssets);
    function claimableDepositRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableAssets);
    // Claim-style overloads — required as part of this interface's type (not just standalone
    // functions) for `type(IERC7540Deposit).interfaceId` to compute the correct canonical value;
    // verified against the published EIP-7540 interfaceId (0xce3bbe50) before this was added.
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets);
}

interface IERC7540Redeem is IERC7540Operator {
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares);
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableShares);
}

/**
 * @title ERC7540OperatedVault
 * @custom:security-contact security@investax.io
 * @notice Regulated, single-asset, pass-through tokenization wrapper — NOT an actively managed fund.
 *   1 vault = 1 underlying asset that IXS does not manage (a listed equity, an ETF, a REIT, or any
 *   other RWA reachable through a broker-dealer/execution venue). A user sends stablecoin, IXS
 *   executes the real purchase off-chain, custody holds the actual asset, and this contract issues
 *   a receipt token for that position. IXS's value-add is the license, the KYC/compliance layer,
 *   and execution access — not portfolio management or asset selection.
 *
 *   Async on both sides (ERC-7540), execution-price settled:
 *     - Deposits and redemptions are both request → finalize/reject, two states each
 *       (Pending → Finalized/Rejected). No routine NAV cron, no fund-NAV pool.
 *     - finalizeDepositRequest/finalizeRedeemRequest each take an explicit `executionPrice` —
 *       the real, actual settlement price of that specific trade. This is the ONLY price that
 *       ever determines what a user pays or receives.
 *     - setNAV() is a RARE MANUAL OVERRIDE ONLY (out-of-band correction, in-kind distribution
 *       accrual). It is never called routinely and never prices a settlement — `pricePerShare`
 *       is always indicative (feeds view functions and the deviation-guard baseline only).
 *     - Deposit assets are forwarded to custody IMMEDIATELY on requestDeposit (the trade needs
 *       the cash up front). Rejecting a deposit therefore requires custody to have returned the
 *       funds to the vault first — the same precondition redeem finalization already has.
 *     - Redeem shares are escrowed in the vault on requestRedeem, unchanged in shape from
 *       ManagedVault's existing redeem queue.
 *
 *   Fees: `subscribeFeeBps` (deposit side, charged in shares) and `redeemFeeBps` (redeem side,
 *   charged in assets) — independent, each optional, defaulting to 0. Rounding always favors the
 *   protocol (fees round up, base conversions round down).
 *
 *   Controller-only, no redirect: every request requires `msg.sender == controller == owner`,
 *   matching strict ERC-7540 signatures exactly (no separate `receiver` parameter). Preserves
 *   blind interoperability with generic ERC-7540 tooling that calls by exact selector. Nothing is
 *   actually lost in practice — plain transfer() is never whitelist-gated, so redirecting an
 *   outcome to a different wallet is one extra, unrestricted transfer away.
 *
 *   Referral attribution: `requestDepositWithReferral` is `requestDeposit` plus a `bytes32`
 *   introducer/referrer code, recorded in the `DepositReferral` event only — no storage, no
 *   on-chain validation, no on-chain commission math. The standard `requestDeposit` selector is
 *   untouched, so ERC-7540 compliance holds; deposits made through it simply carry no code.
 *
 *   Whitelist gates subscription/redemption only (deposit/requestDeposit/requestRedeem), never
 *   plain transfer()/transferFrom() — deliberate, so the vault token stays freely composable as
 *   lending collateral (Morpho/Aave-style money markets) without breaking on liquidator transfers.
 *
 *   Distributions (dividends/coupons/REIT income/etc.) are handled entirely OFF this contract:
 *     - Real cash payouts → a separate Merkle-drop claim contract, pro-rata to holders at a
 *       snapshot. Not implemented here — this contract needs zero changes to support it.
 *     - Total-return/accumulating instruments → nothing to do, execution-price settlement already
 *       reflects it.
 *     - In-kind distributions (stock/scrip dividends, PIK interest, DRIP) → accumulate into
 *       custody holdings, reflected via an occasional setNAV() bump.
 *
 *   Sweep guard — vault asset and vault shares cannot be swept.
 *   UUPS upgradeable — upgrade authorised by DEFAULT_ADMIN_ROLE.
 *   Deployment — fresh implementation + plain ERC1967Proxy per instance, matching ManagedVault's
 *   existing deployment script pattern (no factory, no beacon proxy).
 */
contract ERC7540OperatedVault is
    ERC20Upgradeable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IERC7540Deposit,
    IERC7540Redeem
{
    using Math for uint256;
    using SafeERC20 for IERC20;

    // =========================================================
    // Constants
    // =========================================================

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant NAV_MANAGER_ROLE = keccak256("NAV_MANAGER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant MAX_BPS = 10_000;

    /// @notice Default NAV staleness threshold: 48 hours. Informational/monitoring signal only —
    ///         does NOT gate finalizeDepositRequest/finalizeRedeemRequest (both are always priced
    ///         off a live, real executionPrice supplied at call time).
    uint256 public constant DEFAULT_NAV_STALENESS = 30 days;

    /// @notice Default max NAV change per price update: 50%. Applies uniformly to setNAV() and to
    ///         the implicit price update inside finalizeDepositRequest/finalizeRedeemRequest.
    uint256 public constant DEFAULT_MAX_NAV_CHANGE_BPS = 5_000;

    /// @notice Max accounts per setWhitelistedBatch call — bounds gas per tx.
    uint256 public constant MAX_BATCH_SIZE = 200;

    // =========================================================
    // Types
    // =========================================================

    enum RequestStatus {
        None,
        Pending,
        Finalized,
        Rejected
    }

    struct DepositRequestData {
        address controller; // == owner == msg.sender at request time
        uint256 assets;
        uint256 subscribeFeeBpsAtRequest; // frozen at request — immune to future fee changes
        uint256 requestedAt;
        uint256 processedAt;
        RequestStatus status;
    }

    struct RedeemRequestData {
        address controller; // == owner == msg.sender at request time
        uint256 shares;
        uint256 priceAtRequest; // indicative price at request — audit trail only; finalization uses real executionPrice
        uint256 redeemFeeBpsAtRequest; // frozen at request — immune to future fee changes
        uint256 requestedAt;
        uint256 processedAt;
        RequestStatus status;
    }

    // =========================================================
    // Errors
    // =========================================================

    error ERC7540OperatedVault__AssetAddressIsZero();
    error ERC7540OperatedVault__NameIsEmpty();
    error ERC7540OperatedVault__SymbolIsEmpty();
    error ERC7540OperatedVault__AdminIsZero();
    error ERC7540OperatedVault__CustodyIsZero();
    error ERC7540OperatedVault__AssetDecimalsTooHigh();
    error ERC7540OperatedVault__FeeBpsTooHigh();
    error ERC7540OperatedVault__FeeRecipientIsZero();
    error ERC7540OperatedVault__MaxNavChangeUnreasonablyHigh();
    error ERC7540OperatedVault__AccountIsZero();
    error ERC7540OperatedVault__BatchTooLarge();
    error ERC7540OperatedVault__PriceIsZero();
    error ERC7540OperatedVault__TokenIsZero();
    error ERC7540OperatedVault__CannotSweepVaultAsset();
    error ERC7540OperatedVault__CannotSweepVaultShares();
    error ERC7540OperatedVault__BelowMinSweep();
    error ERC7540OperatedVault__DepositAssetsIsZero();
    error ERC7540OperatedVault__BelowMinDeposit();
    error ERC7540OperatedVault__ControllerMustBeSender();
    error ERC7540OperatedVault__OwnerMustBeSender();
    error ERC7540OperatedVault__ReferralCodeIsZero();
    error ERC7540OperatedVault__DepositNotPending();
    error ERC7540OperatedVault__GrossSharesIsZero();
    error ERC7540OperatedVault__NetSharesIsZero();
    error ERC7540OperatedVault__InsufficientLiquidity();
    error ERC7540OperatedVault__SharesIsZero();
    error ERC7540OperatedVault__BelowMinRedeem();
    error ERC7540OperatedVault__RedeemNotPending();
    error ERC7540OperatedVault__GrossAssetsIsZero();
    error ERC7540OperatedVault__NetAssetsIsZero();
    error ERC7540OperatedVault__NotWhitelisted();
    error ERC7540OperatedVault__NavChangeTooLarge();
    error ERC7540OperatedVault__CustodyIsVault();
    error ERC7540OperatedVault__CustodyIsAsset();
    error ERC7540OperatedVault__NothingToClaim();
    error ERC7540OperatedVault__AsyncOnlyUseRequestDeposit();
    error ERC7540OperatedVault__AsyncOnlyUseRequestRedeem();

    // =========================================================
    // State — decimals offset (set once in initialize)
    // =========================================================

    uint8 private _decimalsOffsetVal;

    // =========================================================
    // State — custody & fees
    // =========================================================

    address public custody;
    address public feeRecipient;

    /// @notice Deposit-side (subscription) fee, in bps, charged in shares at deposit finalization.
    uint256 public subscribeFeeBps;
    /// @notice Redeem-side (redemption) fee, in bps, charged in assets at redeem finalization.
    uint256 public redeemFeeBps;

    uint256 public totalSubscribeFeesAccrued; // in shares
    uint256 public totalRedeemFeesAccrued; // in assets

    // =========================================================
    // State — NAV
    // =========================================================

    /// @notice Last recorded price of 1 vault share in asset units (asset decimals precision).
    ///         ALWAYS INDICATIVE — never itself used to price a deposit/redeem settlement. Feeds
    ///         view functions (totalAssets, previewDeposit/Redeem, convertToShares/Assets) and acts
    ///         as the deviation-guard baseline for the next price update, whichever path causes one.
    ///         0 = uninitialised.
    uint256 public pricePerShare;

    /// @notice Timestamp `pricePerShare` was last updated (by a finalize call or by setNAV()).
    uint256 public priceUpdatedAt;

    /// @notice Informational/monitoring threshold only — see DEFAULT_NAV_STALENESS.
    uint256 public navStalenessThreshold;

    /// @notice Max allowed price change (up or down) per price update, in BPS. Applies to setNAV()
    ///         and to the implicit update inside finalizeDepositRequest/finalizeRedeemRequest alike.
    uint256 public maxNavChangeBps;

    // =========================================================
    // State — whitelist
    // =========================================================

    /// @notice Gates requestDeposit/requestRedeem only. Never gates plain transfer()/transferFrom()
    ///         — deliberate, preserves composability as lending collateral (Morpho/Aave-style).
    bool public whitelistEnabled;
    mapping(address => bool) public whitelist;

    // =========================================================
    // State — deposit / redeem limits
    // =========================================================

    uint256 public minDepositAssets;
    uint256 public minRedeemAssets;

    // =========================================================
    // State — deposit queue
    // =========================================================

    mapping(uint256 => DepositRequestData) public depositRequests;
    /// @notice Also serves as the total deposit request count — 1-indexed, only ever incremented.
    uint256 public nextDepositRequestId;
    uint256 public pendingDepositCount;

    // =========================================================
    // State — redeem queue
    // =========================================================

    mapping(uint256 => RedeemRequestData) public redeemRequests;
    /// @notice Also serves as the total redeem request count — 1-indexed, only ever incremented.
    uint256 public nextRedeemRequestId;
    uint256 public pendingRedeemCount;

    // =========================================================
    // State — accounting totals
    // =========================================================

    uint256 public totalDepositFinalized;
    uint256 public totalDepositRejected;
    uint256 public totalRedeemFinalized;
    uint256 public totalRedeemRejected;
    uint256 public totalDepositedAssets;
    uint256 public totalMintedShares;
    uint256 public totalNetWithdrawnAssets;
    uint256 public totalRedeemedShares;

    // =========================================================
    // State — token metadata overrides
    // =========================================================

    string private _customName;
    string private _customSymbol;

    // =========================================================
    // Upgrade storage gap — reserve slots for future state vars
    // =========================================================

    uint256[50] private __gap;

    // =========================================================
    // Events
    // =========================================================

    event CustodyUpdated(address indexed previousCustody, address indexed newCustody);
    event AssetsForwardedToCustody(address indexed custody, uint256 assets);
    event SubscribeFeeBpsUpdated(uint256 previousFeeBps, uint256 newFeeBps);
    event RedeemFeeBpsUpdated(uint256 previousFeeBps, uint256 newFeeBps);
    event FeeRecipientUpdated(address indexed previousFeeRecipient, address indexed newFeeRecipient);
    event MinDepositAssetsUpdated(uint256 previousMin, uint256 newMin);
    event MinRedeemAssetsUpdated(uint256 previousMin, uint256 newMin);
    event TokenSweptToCustody(address indexed token, address indexed custody, uint256 amount);
    event NavStalenessThresholdUpdated(uint256 previousThreshold, uint256 newThreshold);
    event MaxNavChangeBpsUpdated(uint256 previousMax, uint256 newMax);

    event WhitelistEnabled();
    event WhitelistDisabled();
    event WhitelistUpdated(address indexed account, bool status);
    event TokenIdentifiersUpdated(string newName, string newSymbol);

    /// @notice Emitted on every pricePerShare update — whether from setNAV() or implicitly from a
    ///         finalize call. Always indicative; never itself the settlement price.
    event NavUpdated(uint256 previousPricePerShare, uint256 newPricePerShare);

    event DepositRequested(
        uint256 indexed id, address indexed controller, uint256 assets, uint256 subscribeFeeBpsAtRequest
    );
    /// @notice Introducer/referrer attribution — emitted only by requestDepositWithReferral, right
    ///         after the standard request events. All three fields indexed so off-chain
    ///         reconciliation can filter by code directly.
    event DepositReferral(uint256 indexed requestId, address indexed controller, bytes32 indexed referralCode);
    event DepositRequestFinalized(
        uint256 indexed id,
        address indexed controller,
        uint256 assets,
        uint256 grossShares,
        uint256 feeShares,
        uint256 netShares,
        uint256 executionPrice
    );
    event DepositRequestRejected(uint256 indexed id, address indexed controller, uint256 assets);

    event RedeemRequested(
        uint256 indexed id,
        address indexed controller,
        uint256 shares,
        uint256 priceAtRequest,
        uint256 redeemFeeBpsAtRequest
    );
    event RedeemRequestFinalized(
        uint256 indexed id,
        address indexed controller,
        uint256 shares,
        uint256 grossAssets,
        uint256 feeAssets,
        uint256 netAssets,
        uint256 executionPrice
    );
    event RedeemRequestRejected(uint256 indexed id, address indexed controller, uint256 shares);

    // =========================================================
    // Constructor — disable initializers on implementation contract
    // =========================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // =========================================================
    // Initializer — called once on proxy deployment
    // =========================================================

    /**
     * @param asset_             Underlying ERC-20 asset (e.g. USDC).
     * @param name_              Vault share token name.
     * @param symbol_            Vault share token symbol.
     * @param admin_             Address granted DEFAULT_ADMIN_ROLE and all sub-roles.
     * @param custody_           Address assets are forwarded to on deposit / instructed to fund on redeem.
     * @param enableWhitelist_   If true, requestDeposit/requestRedeem enforce whitelist from day one.
     */
    function initialize(
        IERC20 asset_,
        string calldata name_,
        string calldata symbol_,
        address admin_,
        address custody_,
        bool enableWhitelist_
    ) public initializer {
        if (address(asset_) == address(0)) revert ERC7540OperatedVault__AssetAddressIsZero();
        if (bytes(name_).length == 0) revert ERC7540OperatedVault__NameIsEmpty();
        if (bytes(symbol_).length == 0) revert ERC7540OperatedVault__SymbolIsEmpty();
        if (admin_ == address(0)) revert ERC7540OperatedVault__AdminIsZero();
        if (custody_ == address(0)) revert ERC7540OperatedVault__CustodyIsZero();

        uint8 assetDecimals = IERC20Metadata(address(asset_)).decimals();
        if (assetDecimals > 18) revert ERC7540OperatedVault__AssetDecimalsTooHigh();
        _validateCustody(custody_, asset_);

        // Must be set before __ERC4626_init so _decimalsOffset() returns correct value
        // when decimals() is first called. Gives vault shares 18 decimals regardless of asset.
        _decimalsOffsetVal = 18 - assetDecimals;

        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        custody = custody_;
        feeRecipient = custody_;
        minDepositAssets = 1;
        minRedeemAssets = 1;
        navStalenessThreshold = DEFAULT_NAV_STALENESS;
        maxNavChangeBps = DEFAULT_MAX_NAV_CHANGE_BPS;
        whitelistEnabled = enableWhitelist_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);
        _grantRole(NAV_MANAGER_ROLE, admin_);
        _grantRole(OPERATOR_ROLE, admin_);

        if (enableWhitelist_) emit WhitelistEnabled();
    }

    // =========================================================
    // UUPS — upgrade authorization
    // =========================================================

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // =========================================================
    // Admin — pause
    // =========================================================

    /// @notice Pause blocks: new requestDeposit, new requestRedeem.
    ///         Does NOT block: finalizeDepositRequest, rejectDepositRequest, finalizeRedeemRequest,
    ///         rejectRedeemRequest — existing queues must always be able to drain during a pause.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================
    // Admin — config
    // =========================================================

    function setCustody(address newCustody) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCustody == address(0)) revert ERC7540OperatedVault__CustodyIsZero();
        _validateCustody(newCustody, IERC20(asset()));
        address prev = custody;
        custody = newCustody;
        emit CustodyUpdated(prev, newCustody);
    }

    function setSubscribeFeeBps(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBps > MAX_BPS) revert ERC7540OperatedVault__FeeBpsTooHigh();
        uint256 prev = subscribeFeeBps;
        subscribeFeeBps = newFeeBps;
        emit SubscribeFeeBpsUpdated(prev, newFeeBps);
    }

    function setRedeemFeeBps(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBps > MAX_BPS) revert ERC7540OperatedVault__FeeBpsTooHigh();
        uint256 prev = redeemFeeBps;
        redeemFeeBps = newFeeBps;
        emit RedeemFeeBpsUpdated(prev, newFeeBps);
    }

    function setFeeRecipient(address newFeeRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeRecipient == address(0)) revert ERC7540OperatedVault__FeeRecipientIsZero();
        address prev = feeRecipient;
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(prev, newFeeRecipient);
    }

    function setMinDepositAssets(uint256 newMin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 prev = minDepositAssets;
        minDepositAssets = newMin;
        emit MinDepositAssetsUpdated(prev, newMin);
    }

    function setMinRedeemAssets(uint256 newMin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 prev = minRedeemAssets;
        minRedeemAssets = newMin;
        emit MinRedeemAssetsUpdated(prev, newMin);
    }

    function setNavStalenessThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 prev = navStalenessThreshold;
        navStalenessThreshold = newThreshold;
        emit NavStalenessThresholdUpdated(prev, newThreshold);
    }

    /// @notice Ceiling is MAX_BPS * 10 (1,000%) — a deliberate safety limit, not a mathematical
    ///         necessity. A genuine price increase bigger than 1,000% in one settlement needs more
    ///         than one step (raise, update, reset, update again) since no single call here can
    ///         authorize it in one shot. Decreases never need this — a price can only ever fall to
    ///         zero (100%), well under this ceiling.
    function setMaxNavChangeBps(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMax > MAX_BPS * 10) revert ERC7540OperatedVault__MaxNavChangeUnreasonablyHigh();
        uint256 prev = maxNavChangeBps;
        maxNavChangeBps = newMax;
        emit MaxNavChangeBpsUpdated(prev, newMax);
    }

    function setTokenIdentifiers(string calldata newName, string calldata newSymbol)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (bytes(newName).length == 0) revert ERC7540OperatedVault__NameIsEmpty();
        if (bytes(newSymbol).length == 0) revert ERC7540OperatedVault__SymbolIsEmpty();
        _customName = newName;
        _customSymbol = newSymbol;
        emit TokenIdentifiersUpdated(newName, newSymbol);
    }

    // =========================================================
    // Admin — whitelist toggle
    // =========================================================

    function setWhitelistEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        whitelistEnabled = enabled;
        if (enabled) emit WhitelistEnabled();
        else emit WhitelistDisabled();
    }

    // =========================================================
    // Operator — whitelist management
    // =========================================================

    function setWhitelisted(address account, bool status) external onlyRole(OPERATOR_ROLE) {
        if (account == address(0)) revert ERC7540OperatedVault__AccountIsZero();
        whitelist[account] = status;
        emit WhitelistUpdated(account, status);
    }

    function setWhitelistedBatch(address[] calldata accounts, bool status) external onlyRole(OPERATOR_ROLE) {
        if (accounts.length > MAX_BATCH_SIZE) revert ERC7540OperatedVault__BatchTooLarge();
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert ERC7540OperatedVault__AccountIsZero();
            whitelist[accounts[i]] = status;
            emit WhitelistUpdated(accounts[i], status);
        }
    }

    // =========================================================
    // NAV Manager — rare manual override
    // =========================================================

    /**
     * @notice Manually set the indicative pricePerShare. RARE — out-of-band corrections and
     *         in-kind distribution accruals only. NEVER routine, and NEVER the price a deposit or
     *         redeem settles at — that is always the executionPrice passed into
     *         finalizeDepositRequest/finalizeRedeemRequest directly.
     * @param newPricePerShare  Price of 1 vault share in asset units (asset decimals precision).
     */
    function setNAV(uint256 newPricePerShare) external onlyRole(NAV_MANAGER_ROLE) {
        if (newPricePerShare == 0) revert ERC7540OperatedVault__PriceIsZero();
        _updatePricePerShare(newPricePerShare);
    }

    // =========================================================
    // Admin — emergency sweep
    // =========================================================

    /**
     * @notice Sweep any third-party ERC-20 to custody.
     *
     * Blocked:
     *   - vault asset  — earmarked for pending deposit refunds / redemption settlements
     *   - vault shares — escrowed pending redeem requests live here
     */
    function sweepTokenToCustody(address token, uint256 minAmount) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ERC7540OperatedVault__TokenIsZero();
        if (token == asset()) revert ERC7540OperatedVault__CannotSweepVaultAsset();
        if (token == address(this)) revert ERC7540OperatedVault__CannotSweepVaultShares();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < minAmount) revert ERC7540OperatedVault__BelowMinSweep();
        IERC20(token).safeTransfer(custody, balance);
        emit TokenSweptToCustody(token, custody, balance);
    }

    // =========================================================
    // User — deposit queue
    // =========================================================

    /**
     * @notice Request an async deposit. Assets are forwarded to custody IMMEDIATELY — the trade
     *         needs the cash up front. Shares are NOT minted here; they mint later at
     *         finalizeDepositRequest, priced at that settlement's real executionPrice.
     *
     * @dev controller and owner MUST both equal msg.sender — strict ERC-7540 signature, no
     *      redirect to a different receiving address (see contract-level NatSpec).
     */
    function requestDeposit(uint256 assets, address controller, address owner)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        requestId = _requestDeposit(assets, controller, owner);
    }

    /**
     * @notice requestDeposit plus introducer/referrer attribution. Identical checks, transfers and
     *         request state — the only addition is the DepositReferral event.
     *
     * @dev Not part of IERC7540Deposit — a separate selector, so the standard interfaceId is
     *      unchanged. `referralCode` is not validated on-chain beyond nonzero; callers without a
     *      code use requestDeposit.
     */
    function requestDepositWithReferral(uint256 assets, address controller, address owner, bytes32 referralCode)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (referralCode == bytes32(0)) revert ERC7540OperatedVault__ReferralCodeIsZero();
        requestId = _requestDeposit(assets, controller, owner);
        emit DepositReferral(requestId, msg.sender, referralCode);
    }

    /// @dev Shared body of requestDeposit/requestDepositWithReferral. Callers apply nonReentrant
    ///      and whenNotPaused.
    function _requestDeposit(uint256 assets, address controller, address owner) internal returns (uint256 requestId) {
        if (assets == 0) revert ERC7540OperatedVault__DepositAssetsIsZero();
        if (controller != msg.sender) revert ERC7540OperatedVault__ControllerMustBeSender();
        if (owner != msg.sender) revert ERC7540OperatedVault__OwnerMustBeSender();
        if (assets < minDepositAssets) revert ERC7540OperatedVault__BelowMinDeposit();
        _checkWhitelist(msg.sender);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        requestId = ++nextDepositRequestId;
        pendingDepositCount += 1;

        depositRequests[requestId] = DepositRequestData({
            controller: msg.sender,
            assets: assets,
            subscribeFeeBpsAtRequest: subscribeFeeBps,
            requestedAt: block.timestamp,
            processedAt: 0,
            status: RequestStatus.Pending
        });

        IERC20(asset()).safeTransfer(custody, assets);
        emit AssetsForwardedToCustody(custody, assets);
        emit DepositRequested(requestId, msg.sender, assets, subscribeFeeBps);
        emit IERC7540Deposit.DepositRequest(msg.sender, msg.sender, requestId, msg.sender, assets);
    }

    // =========================================================
    // Operator — deposit finalize / reject
    // =========================================================

    /**
     * @notice Finalize a pending deposit. Mints net shares to the controller, fee shares to
     *         feeRecipient, priced at executionPrice — the real, actual price this specific
     *         settlement traded at.
     *
     * @dev Updates pricePerShare as a side effect (subject to the deviation guard). NOT gated by
     *      whenNotPaused — existing queue must always drain during a pause.
     *
     * @param requestId       Pending deposit request id.
     * @param executionPrice  Real settlement price of 1 vault share in asset units. NOT read from
     *                        storage — always the actual price this trade executed at.
     */
    function finalizeDepositRequest(uint256 requestId, uint256 executionPrice)
        external
        nonReentrant
        onlyRole(OPERATOR_ROLE)
    {
        if (executionPrice == 0) revert ERC7540OperatedVault__PriceIsZero();
        DepositRequestData storage request = depositRequests[requestId];
        if (request.status != RequestStatus.Pending) revert ERC7540OperatedVault__DepositNotPending();
        _checkWhitelist(request.controller);

        _updatePricePerShare(executionPrice);

        uint256 grossShares = request.assets.mulDiv(10 ** decimals(), executionPrice, Math.Rounding.Floor);
        if (grossShares == 0) revert ERC7540OperatedVault__GrossSharesIsZero();
        uint256 feeShares = _feeOnRaw(grossShares, request.subscribeFeeBpsAtRequest);
        uint256 netShares = grossShares - feeShares;
        // A nonzero fee bps always rounds up (Ceil) to at least 1 — on a small enough grossShares
        // this can consume the entire amount even though grossShares > 0. Assets are already
        // irrevocably at custody by this point, so this must hard-fail rather than silently mint 0.
        if (netShares == 0) revert ERC7540OperatedVault__NetSharesIsZero();

        request.processedAt = block.timestamp;
        request.status = RequestStatus.Finalized;
        pendingDepositCount -= 1;
        totalDepositFinalized += 1;
        totalDepositedAssets += request.assets;
        totalMintedShares += netShares;
        totalSubscribeFeesAccrued += feeShares;

        _mint(request.controller, netShares);
        if (feeShares > 0) _mint(feeRecipient, feeShares);

        emit DepositRequestFinalized(
            requestId, request.controller, request.assets, grossShares, feeShares, netShares, executionPrice
        );
        // ERC-4626/ERC-7575 Deposit event emits gross (pre-fee) shares per spec convention.
        emit Deposit(msg.sender, request.controller, request.assets, grossShares);
    }

    /**
     * @notice Reject a pending deposit. Requires custody has already returned the assets to this
     *         vault. Refunds them to the controller. NOT gated by whenNotPaused.
     */
    function rejectDepositRequest(uint256 requestId) external nonReentrant onlyRole(OPERATOR_ROLE) {
        DepositRequestData storage request = depositRequests[requestId];
        if (request.status != RequestStatus.Pending) revert ERC7540OperatedVault__DepositNotPending();
        if (IERC20(asset()).balanceOf(address(this)) < request.assets) {
            revert ERC7540OperatedVault__InsufficientLiquidity();
        }

        request.processedAt = block.timestamp;
        request.status = RequestStatus.Rejected;
        pendingDepositCount -= 1;
        totalDepositRejected += 1;

        IERC20(asset()).safeTransfer(request.controller, request.assets);
        emit DepositRequestRejected(requestId, request.controller, request.assets);
    }

    // =========================================================
    // User — redeem queue
    // =========================================================

    /**
     * @notice Queue a redemption. Shares escrowed until finalized or rejected.
     *
     * @dev priceAtRequest locked at request time — audit trail only, finalization uses the real
     *      executionPrice. redeemFeeBpsAtRequest frozen at request — immune to future fee changes.
     *      controller and owner MUST both equal msg.sender — strict ERC-7540 signature, no
     *      redirect (see contract-level NatSpec).
     *
     * @param shares      Vault shares to redeem.
     * @param controller  Must equal msg.sender.
     * @param owner       Must equal msg.sender.
     * @return requestId  Request id (1-indexed).
     */
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (shares == 0) revert ERC7540OperatedVault__SharesIsZero();
        if (controller != msg.sender) revert ERC7540OperatedVault__ControllerMustBeSender();
        if (owner != msg.sender) revert ERC7540OperatedVault__OwnerMustBeSender();
        if (previewRedeem(shares) < minRedeemAssets) revert ERC7540OperatedVault__BelowMinRedeem();
        _checkWhitelist(msg.sender);

        _transfer(msg.sender, address(this), shares);

        requestId = ++nextRedeemRequestId;
        pendingRedeemCount += 1;

        redeemRequests[requestId] = RedeemRequestData({
            controller: msg.sender,
            shares: shares,
            priceAtRequest: pricePerShare,
            redeemFeeBpsAtRequest: redeemFeeBps,
            requestedAt: block.timestamp,
            processedAt: 0,
            status: RequestStatus.Pending
        });

        emit RedeemRequested(requestId, msg.sender, shares, pricePerShare, redeemFeeBps);
        emit IERC7540Redeem.RedeemRequest(msg.sender, msg.sender, requestId, msg.sender, shares);
    }

    // =========================================================
    // Operator — redeem finalize / reject
    // =========================================================

    /**
     * @notice Finalize a pending redeem. Burns escrowed shares, sends net assets to the
     *         controller, priced at executionPrice — the real, actual price this specific sale
     *         executed at.
     *
     * @dev NOT gated by whenNotPaused — existing queue must drain during a pause.
     *      Custody must fund the vault (transfer assets to this contract) before this call,
     *      otherwise the liquidity check reverts. Updates pricePerShare as a side effect (subject
     *      to the deviation guard).
     *
     * @param requestId       Pending redeem request id.
     * @param executionPrice  Real settlement price of 1 vault share in asset units.
     */
    function finalizeRedeemRequest(uint256 requestId, uint256 executionPrice)
        external
        nonReentrant
        onlyRole(OPERATOR_ROLE)
    {
        if (executionPrice == 0) revert ERC7540OperatedVault__PriceIsZero();
        RedeemRequestData storage request = redeemRequests[requestId];
        if (request.status != RequestStatus.Pending) revert ERC7540OperatedVault__RedeemNotPending();
        _checkWhitelist(request.controller);

        _updatePricePerShare(executionPrice);

        uint256 grossAssets = request.shares.mulDiv(executionPrice, 10 ** decimals(), Math.Rounding.Floor);
        if (grossAssets == 0) revert ERC7540OperatedVault__GrossAssetsIsZero();
        uint256 feeAssets = _feeOnRaw(grossAssets, request.redeemFeeBpsAtRequest);
        uint256 netAssets = grossAssets - feeAssets;
        // Same rounding-floor rationale as finalizeDepositRequest — must hard-fail, not silently
        // burn shares for a zero payout.
        if (netAssets == 0) revert ERC7540OperatedVault__NetAssetsIsZero();
        if (availableAssets() < grossAssets) revert ERC7540OperatedVault__InsufficientLiquidity();

        request.processedAt = block.timestamp;
        request.status = RequestStatus.Finalized;
        pendingRedeemCount -= 1;
        totalRedeemFinalized += 1;
        totalRedeemFeesAccrued += feeAssets;
        totalNetWithdrawnAssets += netAssets;
        totalRedeemedShares += request.shares;

        _burn(address(this), request.shares);

        IERC20(asset()).safeTransfer(request.controller, netAssets);
        if (feeAssets > 0) IERC20(asset()).safeTransfer(feeRecipient, feeAssets);

        emit RedeemRequestFinalized(
            requestId, request.controller, request.shares, grossAssets, feeAssets, netAssets, executionPrice
        );
        // ERC-4626/ERC-7575 Withdraw event emits grossAssets per spec.
        emit Withdraw(msg.sender, request.controller, request.controller, grossAssets, request.shares);
    }

    /**
     * @notice Reject a pending redeem. Returns escrowed shares to the controller.
     * @dev NOT gated by whenNotPaused — queue must drain during a pause.
     */
    function rejectRedeemRequest(uint256 requestId) external nonReentrant onlyRole(OPERATOR_ROLE) {
        RedeemRequestData storage request = redeemRequests[requestId];
        if (request.status != RequestStatus.Pending) revert ERC7540OperatedVault__RedeemNotPending();

        request.processedAt = block.timestamp;
        request.status = RequestStatus.Rejected;
        pendingRedeemCount -= 1;
        totalRedeemRejected += 1;

        _transfer(address(this), request.controller, request.shares);
        emit RedeemRequestRejected(requestId, request.controller, request.shares);
    }

    // =========================================================
    // ERC-7540 — operator delegation (disabled, decision: owner-only, no delegation in v1)
    // =========================================================

    /// @notice Third-party operator delegation is not supported in v1. Returns `false` for a grant
    ///         attempt (rejected, per this function's own success/failure return convention) rather
    ///         than reverting, so generic ERC-7540 tooling that unconditionally calls this during
    ///         setup degrades gracefully instead of hard-failing. Revoking (`approved == false`) is
    ///         trivially valid — there was never an operator set — so it returns `true`.
    function setOperator(address, bool approved) external pure returns (bool) {
        return !approved;
    }

    /// @notice Always false — no operator delegation is ever configured.
    function isOperator(address, address) external pure returns (bool status) {
        return false;
    }

    // =========================================================
    // ERC-7540 — request state views
    // =========================================================

    function pendingDepositRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 pendingAssets)
    {
        DepositRequestData storage request = depositRequests[requestId];
        if (request.status == RequestStatus.Pending && request.controller == controller) {
            return request.assets;
        }
        return 0;
    }

    /// @notice Always 0 — push-model vault, shares mint directly at finalize, never held in a
    ///         separate claimable bucket.
    function claimableDepositRequest(uint256, address) external pure returns (uint256 claimableAssets) {
        return 0;
    }

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares) {
        RedeemRequestData storage request = redeemRequests[requestId];
        if (request.status == RequestStatus.Pending && request.controller == controller) {
            return request.shares;
        }
        return 0;
    }

    /// @notice Always 0 — push-model vault, assets pay out directly at finalize, never held in a
    ///         separate claimable bucket.
    function claimableRedeemRequest(uint256, address) external pure returns (uint256 claimableShares) {
        return 0;
    }

    /// @notice ERC-7540 claim-style deposit overload. Always reverts — nothing is ever claimable
    ///         in this push-model vault (shares mint directly at finalizeDepositRequest).
    function deposit(uint256, address, address) external pure returns (uint256) {
        revert ERC7540OperatedVault__NothingToClaim();
    }

    /// @notice ERC-7540 claim-style mint overload. Always reverts, same reason as deposit above.
    function mint(uint256, address, address) external pure returns (uint256) {
        revert ERC7540OperatedVault__NothingToClaim();
    }

    /// @notice ERC-7575 `share()` accessor — this vault is its own share token.
    function share() external view returns (address) {
        return address(this);
    }

    // =========================================================
    // ERC-165
    // =========================================================

    /// @dev `type(IERC7540Deposit/Redeem/Operator).interfaceId` verified by direct computation to
    ///      equal the published EIP-7540 constants (0xce3bbe50 / 0x620ee8e4 / 0xe3bc4e65) — this
    ///      required including the deposit/mint claim overloads directly in the `IERC7540Deposit`
    ///      interface body above, since Solidity excludes inherited-interface selectors from the
    ///      XOR otherwise. ERC-7575's constant (0x2f0a18c5, from the published EIP text) is
    ///      hardcoded rather than computed, since formally inheriting the full IERC7575 interface
    ///      conflicts with events ERC4626Upgradeable/ERC20Upgradeable already declare.
    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) {
        return interfaceId == type(IERC7540Deposit).interfaceId || interfaceId == type(IERC7540Redeem).interfaceId
            || interfaceId == type(IERC7540Operator).interfaceId || interfaceId == 0x2f0a18c5
            || super.supportsInterface(interfaceId);
    }

    // =========================================================
    // ERC-4626 overrides
    // =========================================================

    function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
        return super.decimals();
    }

    function name() public view override(ERC20Upgradeable, IERC20Metadata) returns (string memory) {
        return bytes(_customName).length > 0 ? _customName : super.name();
    }

    function symbol() public view override(ERC20Upgradeable, IERC20Metadata) returns (string memory) {
        return bytes(_customSymbol).length > 0 ? _customSymbol : super.symbol();
    }

    /**
     * @notice totalAssets = pricePerShare × totalSupply / 10^decimals.
     *         Pure read — no state written. pricePerShare is always indicative (see contract
     *         NatSpec) — this is an estimate, not a binding figure. Returns 0 when uninitialised.
     */
    function totalAssets() public view override returns (uint256) {
        if (pricePerShare == 0) return 0;
        return totalSupply().mulDiv(pricePerShare, 10 ** decimals(), Math.Rounding.Floor);
    }

    /// @notice Always 0 — synchronous deposit disabled, use requestDeposit.
    function maxDeposit(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Always 0 — synchronous mint disabled, use requestDeposit.
    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Always 0 — synchronous withdraw disabled, use requestRedeem.
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Always 0 — synchronous redeem disabled, use requestRedeem.
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Estimate only, net of subscribeFeeBps at the current indicative pricePerShare —
    ///         not binding, the real outcome is priced at finalizeDepositRequest's executionPrice.
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 grossShares = super.previewDeposit(assets);
        return grossShares - _feeOnRaw(grossShares, subscribeFeeBps);
    }

    /// @notice Estimate only, at the current indicative pricePerShare — not binding, the real
    ///         outcome is priced at finalizeRedeemRequest's executionPrice.
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 fee = _feeOnRaw(assets, redeemFeeBps);
        return super.previewWithdraw(assets + fee);
    }

    /// @notice Estimate only, at the current indicative pricePerShare — not binding.
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 assets = super.previewRedeem(shares);
        return assets - _feeOnRaw(assets, redeemFeeBps);
    }

    // =========================================================
    // Views
    // =========================================================

    /// @notice Asset balance held in this contract. Non-zero when custody has funded pending
    ///         redemptions or returned funds for a pending deposit rejection.
    function availableAssets() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice True if pricePerShare was updated within navStalenessThreshold. Informational only
    ///         — does not gate any deposit/redeem operation (see contract NatSpec).
    function isNavFresh() external view returns (bool) {
        if (priceUpdatedAt == 0) return false;
        if (navStalenessThreshold == 0) return true;
        return block.timestamp - priceUpdatedAt <= navStalenessThreshold;
    }

    // =========================================================
    // Internal overrides
    // =========================================================

    /// @notice Synchronous deposit/mint disabled — use requestDeposit. Disabling this one hook
    ///         disables both public deposit() and mint() (2-arg ERC-4626 forms).
    function _deposit(address, address, uint256, uint256) internal pure override {
        revert ERC7540OperatedVault__AsyncOnlyUseRequestDeposit();
    }

    /// @notice Synchronous withdraw/redeem disabled — use requestRedeem. Disabling this one hook
    ///         disables both public withdraw() and redeem() (3-arg ERC-4626 forms).
    function _withdraw(address, address, address, uint256, uint256) internal pure override {
        revert ERC7540OperatedVault__AsyncOnlyUseRequestRedeem();
    }

    /**
     * @dev Share → asset conversion using the last recorded (indicative) pricePerShare.
     *      shares × pricePerShare / 10^decimals. Returns 0 when uninitialised.
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        if (pricePerShare == 0) return 0;
        return shares.mulDiv(pricePerShare, 10 ** decimals(), rounding);
    }

    /**
     * @dev Asset → share conversion using the last recorded (indicative) pricePerShare.
     *      assets × 10^decimals / pricePerShare. Returns 0 when uninitialised.
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        if (pricePerShare == 0) return 0;
        return assets.mulDiv(10 ** decimals(), pricePerShare, rounding);
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return _decimalsOffsetVal;
    }

    // =========================================================
    // Internal — whitelist
    // =========================================================

    function _checkWhitelist(address account) internal view {
        if (whitelistEnabled && !whitelist[account]) revert ERC7540OperatedVault__NotWhitelisted();
    }

    // =========================================================
    // Internal — price update (shared by setNAV and every finalize call)
    // =========================================================

    /**
     * @dev The ONE place pricePerShare is ever written. Two callers:
     *        - finalizeDepositRequest/finalizeRedeemRequest, automatically, every settlement,
     *          passing that settlement's real executionPrice.
     *        - the public setNAV() (NAV_MANAGER_ROLE), rarely, for out-of-band corrections or
     *          in-kind distribution accruals.
     *      Deviation guard applies uniformly regardless of caller. Skipped on the very first call
     *      (pricePerShare == 0) — no genesis/bootstrap special-casing needed beyond this.
     */
    function _updatePricePerShare(uint256 newPricePerShare) internal {
        if (pricePerShare > 0) {
            uint256 changeBps;
            if (newPricePerShare >= pricePerShare) {
                changeBps = (newPricePerShare - pricePerShare).mulDiv(MAX_BPS, pricePerShare, Math.Rounding.Ceil);
            } else {
                changeBps = (pricePerShare - newPricePerShare).mulDiv(MAX_BPS, pricePerShare, Math.Rounding.Ceil);
            }
            if (changeBps > maxNavChangeBps) revert ERC7540OperatedVault__NavChangeTooLarge();
        }

        uint256 prev = pricePerShare;
        pricePerShare = newPricePerShare;
        priceUpdatedAt = block.timestamp;

        emit NavUpdated(prev, newPricePerShare);
    }

    // =========================================================
    // Internal — fee math (always rounds in the protocol's favor)
    // =========================================================

    function _feeOnRaw(uint256 amount, uint256 feeBpsValue) internal pure returns (uint256) {
        return amount.mulDiv(feeBpsValue, MAX_BPS, Math.Rounding.Ceil);
    }

    // =========================================================
    // Internal — validation
    // =========================================================

    function _validateCustody(address custody_, IERC20 asset_) private view {
        if (custody_ == address(this)) revert ERC7540OperatedVault__CustodyIsVault();
        if (custody_ == address(asset_)) revert ERC7540OperatedVault__CustodyIsAsset();
    }
}
