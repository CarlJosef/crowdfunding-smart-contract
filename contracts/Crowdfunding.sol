// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Crowdfunding smart contract
/// @author Carl Josef Nasralla
/// @notice Crowdfunding platform with admin control, refunds and verified recipients
contract Crowdfunding {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAdmin();
    error InvalidCampaign();
    error InvalidState();
    error DeadlineNotReached();
    error DeadlinePassed();
    error ZeroValue();
    error NothingToRefund();

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
        uint256 totalRaised;
        CampaignStatus status;
        bool isVerifiedRecipient;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public immutable admin;

    uint256 public campaignCount;

    mapping(uint256 => Campaign) public campaigns;

    // campaignId => donor => amount
    mapping(uint256 => mapping(address => uint256)) public contributions;

    // whitelist for verified charities
    mapping(address => bool) public verifiedRecipients;

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

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        admin = msg.sender;
    }

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
        if (recipient == address(0)) revert InvalidCampaign();
        if (goal == 0) revert ZeroValue();
        if (deadline <= block.timestamp) revert DeadlinePassed();

        uint256 campaignId = campaignCount;

        campaigns[campaignId] = Campaign({
            creator: msg.sender,
            recipient: recipient,
            goal: goal,
            deadline: deadline,
            totalRaised: 0,
            status: CampaignStatus.Active,
            isVerifiedRecipient: verifiedRecipients[recipient]
        });

        campaignCount++;

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

        // Basic validation
        if (msg.value == 0) revert ZeroValue();
        if (block.timestamp > campaign.deadline) revert DeadlinePassed();
        if (campaign.status != CampaignStatus.Active) revert InvalidState();

        // Effects: update state before any external interaction
        campaign.totalRaised += msg.value;
        contributions[campaignId][msg.sender] += msg.value;

        emit DonationReceived(campaignId, msg.sender, msg.value);
    }

    /// @notice Finalizes a campaign after deadline or when goal is reached
    /// @param campaignId ID of the campaign to finalize
    function finalizeCampaign(
        uint256 campaignId
    ) external validCampaign(campaignId) {
        Campaign storage campaign = campaigns[campaignId];

        // Only active or paused campaigns can be finalized
        if (
            campaign.status != CampaignStatus.Active &&
            campaign.status != CampaignStatus.Paused
        ) {
            revert InvalidState();
        }

        // Case 1: Campaign successful (goal reached before deadline)
        if (
            campaign.totalRaised >= campaign.goal &&
            block.timestamp <= campaign.deadline
        ) {
            campaign.status = CampaignStatus.Successful;

            uint256 amount = campaign.totalRaised;

            // Effects before interaction
            campaign.totalRaised = 0;

            // Interaction: transfer ETH to recipient
            (bool success, ) = campaign.recipient.call{value: amount}("");
            require(success, "ETH transfer failed");

            emit CampaignSuccessful(campaignId);
            return;
        }

        // Case 2: Campaign failed (deadline passed without reaching goal)
        if (block.timestamp > campaign.deadline) {
            campaign.status = CampaignStatus.Failed;

            emit CampaignFailed(campaignId);
            return;
        }

        // Any other path is invalid
        revert InvalidState();
    }

    /// @notice Claim a refund for a failed campaign
    /// @param campaignId ID of the campaign to claim refund from
    function claimRefund(
        uint256 campaignId
    ) external validCampaign(campaignId) {
        Campaign storage campaign = campaigns[campaignId];

        // Refunds are only allowed for failed campaigns
        if (campaign.status != CampaignStatus.Failed) revert InvalidState();

        uint256 amount = contributions[campaignId][msg.sender];
        if (amount == 0) revert NothingToRefund();

        // Effects: prevent reentrancy and double refunds
        contributions[campaignId][msg.sender] = 0;

        // Invariant: refund amount must be positive before transfer
        assert(amount > 0);

        // Interaction: transfer ETH back to donor
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Refund transfer failed");

        emit RefundIssued(campaignId, msg.sender, amount);
    }

    /// @notice Pause an active campaign (admin only)
    /// @param campaignId ID of the campaign to pause
    function pauseCampaign(
        uint256 campaignId
    ) external onlyAdmin validCampaign(campaignId) {
        Campaign storage campaign = campaigns[campaignId];

        // Only active campaigns can be paused
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
        if (recipient == address(0)) revert InvalidCampaign();

        verifiedRecipients[recipient] = isVerified;
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE / FALLBACK (VG)
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        revert("Direct ETH transfers not allowed");
    }

    fallback() external payable {
        revert("Invalid call");
    }
}
