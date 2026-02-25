// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Crowdfunding smart contract
/// @author Carl Josef Nasralla
/// @notice Crowdfunding platform with admin control, refunds and verified recipients
/// @dev This contract uses a simple state machine per campaign: Active -> (Successful | Failed), with optional Paused.
/// @dev Uses a lightweight reentrancy guard for functions that perform external ETH transfers.
contract Crowdfunding {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAdmin();
    error InvalidCampaign();
    error InvalidRecipient();
    error InvalidState();
    error DeadlineNotReached();
    error DeadlinePassed();
    error ZeroValue();
    error NothingToRefund();
    error EthTransferFailed();
    error RefundTransferFailed();
    error DirectEthNotAllowed();
    error InvalidCall();
    error Reentrancy();

    /*//////////////////////////////////////////////////////////////
                                ENUMS
    //////////////////////////////////////////////////////////////*/

    enum CampaignStatus {
        Active,
        Paused,
        Successful,
        Failed
    }

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Campaign {
        address creator;
        address recipient;
        uint256 goal;
        uint256 deadline;
        /// @dev Current escrowed amount (can be 0 after a successful payout).
        uint256 totalRaised;
        /// @dev Snapshot of the amount paid out when campaign becomes successful.
        uint256 finalRaised;
        CampaignStatus status;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public immutable admin;

    uint256 public campaignCount;

    mapping(uint256 => Campaign) public campaigns;

    /// @dev campaignId => donor => amount contributed (used for refunds on Failed campaigns).
    mapping(uint256 => mapping(address => uint256)) public contributions;

    /// @dev Whitelist for verified recipients (single source of truth).
    mapping(address => bool) public verifiedRecipients;

    // Simple reentrancy guard (single global lock)
    uint256 private _locked = 1;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event CampaignCreated(
        uint256 indexed campaignId,
        address indexed creator,
        address indexed recipient,
        uint256 goal,
        uint256 deadline,
        bool isVerifiedRecipient
    );

    event DonationReceived(
        uint256 indexed campaignId,
        address indexed donor,
        uint256 amount
    );

    event CampaignPaused(uint256 indexed campaignId);
    event CampaignResumed(uint256 indexed campaignId);

    event CampaignSuccessful(uint256 indexed campaignId);
    event CampaignFailed(uint256 indexed campaignId);

    event RefundIssued(
        uint256 indexed campaignId,
        address indexed donor,
        uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier validCampaign(uint256 campaignId) {
        if (campaignId >= campaignCount) revert InvalidCampaign();
        _;
    }

    /// @dev Prevents reentrancy into functions that perform external calls.
    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        admin = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a new crowdfunding campaign
    /// @param recipient Address that will receive funds if successful
    /// @param goal Target amount in wei
    /// @param deadline Unix timestamp when campaign ends
    /// @return campaignId The ID of the newly created campaign
    function createCampaign(
        address recipient,
        uint256 goal,
        uint256 deadline
    ) external returns (uint256) {
        if (recipient == address(0)) revert InvalidRecipient();
        if (goal == 0) revert ZeroValue();
        if (deadline < block.timestamp) revert DeadlinePassed();

        uint256 campaignId = campaignCount;

        campaigns[campaignId] = Campaign({
            creator: msg.sender,
            recipient: recipient,
            goal: goal,
            deadline: deadline,
            totalRaised: 0,
            finalRaised: 0,
            status: CampaignStatus.Active
        });

        campaignCount++;

        // Event includes a snapshot for convenience; live truth is verifiedRecipients[recipient].
        emit CampaignCreated(
            campaignId,
            msg.sender,
            recipient,
            goal,
            deadline,
            verifiedRecipients[recipient]
        );

        return campaignId;
    }

    /// @notice Donate ETH to an active crowdfunding campaign
    /// @param campaignId ID of the campaign to donate to
    function donate(
        uint256 campaignId
    ) external payable validCampaign(campaignId) {
        Campaign storage campaign = campaigns[campaignId];

        if (msg.value == 0) revert ZeroValue();
        if (block.timestamp > campaign.deadline) revert DeadlinePassed();
        if (campaign.status != CampaignStatus.Active) revert InvalidState();

        // Effects
        campaign.totalRaised += msg.value;
        contributions[campaignId][msg.sender] += msg.value;

        emit DonationReceived(campaignId, msg.sender, msg.value);
    }

    /// @notice Finalizes a campaign when it becomes successful (goal reached) or failed (deadline passed)
    /// @param campaignId ID of the campaign to finalize
    function finalizeCampaign(
        uint256 campaignId
    ) external validCampaign(campaignId) nonReentrant {
        Campaign storage campaign = campaigns[campaignId];

        if (
            campaign.status != CampaignStatus.Active &&
            campaign.status != CampaignStatus.Paused
        ) {
            revert InvalidState();
        }

        // Success takes precedence: if goal is reached, campaign is successful even if finalize happens after deadline.
        if (campaign.totalRaised >= campaign.goal) {
            campaign.status = CampaignStatus.Successful;

            uint256 amount = campaign.totalRaised;

            // Effects before interaction
            campaign.totalRaised = 0;
            campaign.finalRaised = amount;

            (bool success, ) = campaign.recipient.call{value: amount}("");
            if (!success) revert EthTransferFailed();

            emit CampaignSuccessful(campaignId);
            return;
        }

        // If goal isn't met, the campaign can only fail after the deadline.
        if (block.timestamp > campaign.deadline) {
            campaign.status = CampaignStatus.Failed;
            emit CampaignFailed(campaignId);
            return;
        }

        // Too early to finalize: still active and goal not met.
        revert DeadlineNotReached();
    }

    /// @notice Claim a refund for a failed campaign
    /// @param campaignId ID of the campaign to claim refund from
    function claimRefund(
        uint256 campaignId
    ) external validCampaign(campaignId) nonReentrant {
        Campaign storage campaign = campaigns[campaignId];

        if (campaign.status != CampaignStatus.Failed) revert InvalidState();

        uint256 amount = contributions[campaignId][msg.sender];
        if (amount == 0) revert NothingToRefund();

        // Effects
        contributions[campaignId][msg.sender] = 0;

        // Interaction
        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert RefundTransferFailed();

        emit RefundIssued(campaignId, msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause an active campaign (admin only)
    /// @param campaignId ID of the campaign to pause
    function pauseCampaign(
        uint256 campaignId
    ) external onlyAdmin validCampaign(campaignId) {
        Campaign storage campaign = campaigns[campaignId];

        if (campaign.status != CampaignStatus.Active) revert InvalidState();

        campaign.status = CampaignStatus.Paused;
        emit CampaignPaused(campaignId);
    }

    /// @notice Resume a paused campaign (admin only)
    /// @param campaignId ID of the campaign to resume
    function resumeCampaign(
        uint256 campaignId
    ) external onlyAdmin validCampaign(campaignId) {
        Campaign storage campaign = campaigns[campaignId];

        if (campaign.status != CampaignStatus.Paused) revert InvalidState();

        campaign.status = CampaignStatus.Active;
        emit CampaignResumed(campaignId);
    }

    /// @notice Force a campaign to fail, e.g. due to suspected fraud (admin only)
    /// @param campaignId ID of the campaign to force fail
    function forceFailCampaign(
        uint256 campaignId
    ) external onlyAdmin validCampaign(campaignId) {
        Campaign storage campaign = campaigns[campaignId];

        if (
            campaign.status != CampaignStatus.Active &&
            campaign.status != CampaignStatus.Paused
        ) {
            revert InvalidState();
        }

        campaign.status = CampaignStatus.Failed;
        emit CampaignFailed(campaignId);
    }

    /// @notice Set or unset a recipient as verified (admin only)
    /// @param recipient Address of the charity/recipient
    /// @param isVerified True to mark as verified, false to unmark
    function setVerifiedRecipient(
        address recipient,
        bool isVerified
    ) external onlyAdmin {
        if (recipient == address(0)) revert InvalidRecipient();
        verifiedRecipients[recipient] = isVerified;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the current verification status of the campaign recipient.
    /// @dev This reads the live whitelist mapping (single source of truth).
    function isRecipientVerified(
        uint256 campaignId
    ) external view validCampaign(campaignId) returns (bool) {
        return verifiedRecipients[campaigns[campaignId].recipient];
    }

    /// @notice Convenience getter for UI/testing: campaign + caller's contribution.
    function getCampaignWithMyContribution(
        uint256 campaignId
    )
        external
        view
        validCampaign(campaignId)
        returns (Campaign memory campaign, uint256 myContribution)
    {
        campaign = campaigns[campaignId];
        myContribution = contributions[campaignId][msg.sender];
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE / FALLBACK
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        revert DirectEthNotAllowed();
    }

    fallback() external payable {
        revert InvalidCall();
    }
}
