// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Crowdfunding smart contract
/// @author You
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
