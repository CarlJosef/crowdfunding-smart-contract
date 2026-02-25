# 5. Roles & security

- The contract defines a single admin role in the constructor:
  - `admin` is set once at deployment (`admin = msg.sender`) and marked `immutable`.
- The `onlyAdmin` modifier ensures that only the admin can:
  - Pause a campaign (`pauseCampaign`)
  - Resume a paused campaign (`resumeCampaign`)
  - Force a campaign into a failed state (`forceFailCampaign`)
  - Manage the whitelist of verified recipients (`setVerifiedRecipient`)
- The `validCampaign` modifier ensures that any `campaignId` passed to a function refers to an existing campaign (`campaignId < campaignCount`).
- Security-related checks:
  - Invalid campaign IDs revert with the `InvalidCampaign` custom error.
  - Unauthorized access to admin-only functions reverts with `NotAdmin`.
  - Invalid state transitions (e.g. pausing a non-active campaign) revert with `InvalidState`.

---

# 6. Pause functionality

- The admin can pause an individual campaign using `pauseCampaign(campaignId)`:
  - Only campaigns with status `CampaignStatus.Active` can be paused.
  - After pausing, the status is set to `CampaignStatus.Paused`.
  - A `CampaignPaused` event is emitted.
- The admin can resume a paused campaign using `resumeCampaign(campaignId)`:
  - Only campaigns with status `CampaignStatus.Paused` can be resumed.
  - Status is set back to `CampaignStatus.Active`.
  - A `CampaignResumed` event is emitted.
- When a campaign is paused:
  - Donations are rejected in `donate` because the status is no longer `Active` (reverts with `InvalidState`).
- A paused or active campaign can be:
  - Finalized normally via `finalizeCampaign` (successful or failed depending on goal and deadline).
  - Forced into `Failed` by the admin using `forceFailCampaign` if there is suspected fraud or similar.
- Refund logic:
  - Refunds are only allowed when the campaign status is `Failed` (either due to deadline or `forceFailCampaign`).
  - Pause/resume does not break or bypass refund conditions.

---

# 7. Technical minimum requirements

The contract clearly meets the technical minimum requirements:

- **Struct / Enum**
  - `struct Campaign` holds creator, recipient, goal, deadline, totalRaised, status and `isVerifiedRecipient`.
  - `enum CampaignStatus { Active, Paused, Successful, Failed }` models the lifecycle of a campaign.
- **Mappings**
  - `mapping(uint256 => Campaign) public campaigns;`
  - `mapping(uint256 => mapping(address => uint256)) public contributions;`
  - `mapping(address => bool) public verifiedRecipients;`
- **Constructor**
  - Sets the `admin` address once at deployment.
- **Custom modifiers**
  - `onlyAdmin` restricts admin-only operations.
  - `validCampaign` ensures that a campaign ID is valid.
- **Events for important actions**
  - `CampaignCreated`
  - `DonationReceived`
  - `CampaignPaused`
  - `CampaignResumed`
  - `CampaignSuccessful`
  - `CampaignFailed`
  - `RefundIssued`

---

# 8. Test requirements

- Tests are implemented in `test/Crowdfunding.test.js` using Hardhat 3 and ethers v6.
- The test suite covers the core functionality of the contract, including:
  - **Campaign creation**
    - Successful creation with valid parameters.
    - Reverts on zero goal.
    - Reverts on deadline in the past.
  - **Donations**
    - Successful donation to an active campaign.
    - Reverts on zero-value donations.
    - Reverts on donations after the deadline.
    - Reverts on donations while the campaign is paused.
  - **Goal reaching and completion**
    - Finalizing a campaign where the goal has been reached sends funds to the recipient and sets status to `Successful`.
  - **Admin behaviour**
    - Admin can pause and resume campaigns.
    - Non-admin addresses cannot pause or resume campaigns.
    - Admin can force-fail a campaign; non-admin cannot.
  - **Failed campaigns and refunds**
    - Failed campaigns after the deadline (goal not reached).
    - Donors can claim refunds from failed campaigns.
    - Refunds cannot be claimed for non-failed campaigns.
    - Second refund attempts revert with `NothingToRefund`.
  - **Whitelist**
    - Admin can set and unset verified recipients.
    - Setting a zero address as verified recipient reverts.
  - **receive / fallback**
    - Direct ETH transfers to the contract revert with `"Direct ETH transfers not allowed"`.
    - Calls with invalid data (fallback) revert with `"Invalid call"`.
- The tests exercise both happy paths and revert paths and provide broad coverage over the most important functions and states in the contract.

---

# 9. Language & low-level control

- **Custom errors**
  - The contract defines multiple custom errors for clearer and cheaper error handling:
    - `NotAdmin`
    - `InvalidCampaign`
    - `InvalidState`
    - `DeadlineNotReached` (reserved for potential use)
    - `DeadlinePassed`
    - `ZeroValue`
    - `NothingToRefund`
- **require / assert / revert**
  - `require` is used to assert successful ETH transfers:
    - In `finalizeCampaign` when sending funds to the recipient.
    - In `claimRefund` when sending refunds to donors.
  - `assert` is used in `claimRefund` to ensure that the refund amount is strictly positive (`assert(amount > 0);`) before performing the transfer.
  - Explicit `revert` is used together with custom errors to abort execution with clear reasons (e.g. `revert NotAdmin();`, `revert InvalidState();`).
- **receive / fallback**
  - `receive()` is implemented and always reverts with `"Direct ETH transfers not allowed"` to prevent accidental or uncontrolled transfers.
  - `fallback()` is implemented and always reverts with `"Invalid call"` to prevent invalid function calls or unexpected data.
- These low-level controls improve clarity, gas efficiency and safety, and they make the behaviour of the contract explicit in error scenarios.

---

# 10. Submission

- The project is organized as a Hardhat 3 ESM-based project with:
  - Contract source in `contracts/Crowdfunding.sol`
  - Tests in `test/Crowdfunding.test.js`
  - Configuration in `hardhat.config.js`
  - Dependencies defined in `package.json`
- The repository is pushed to GitHub so that the examiner can:
  - Clone the repository.
  - Install dependencies with:
    - `npm install`
  - Run the full test suite with:
    - `npx hardhat test`
- The submitted material consists of:
  - Solidity contract file(s)
  - Test file(s)
  - Hardhat configuration and package configuration
  - A short written report describing how the implementation maps to the assignment requirements and reflecting on the delays and environment issues encountered.

---

# 10.1 Version notes (Crowdfunding @2.0+)

This contract has been improved after initial grading to make behavior more consistent and easier to test.

### Behavioral changes

- **Finalize semantics:** A campaign is finalized as **Successful** whenever `totalRaised >= goal`, even if `finalizeCampaign()` is called _after_ the deadline.
  The deadline stops donations, but does not invalidate reaching the goal.
- **Recipient verification:** Recipient verification is a **live lookup** via `verifiedRecipients[campaign.recipient]` (single source of truth).
  `CampaignCreated` still emits a snapshot boolean for convenience.

### Data model changes

- Added `finalRaised` to keep an on-chain snapshot of the paid-out amount after a successful finalize.
- `totalRaised` represents the current escrowed amount (set to `0` after a successful payout).

### Safety / robustness

- Added a simple `nonReentrant` guard for functions performing external ETH transfers (`finalizeCampaign`, `claimRefund`).
- `receive()` / `fallback()` now revert using custom errors instead of revert strings.

---

# 11. Summary

- The `Crowdfunding` contract implements:
  - Creation of campaigns with recipient, goal and deadline.
  - Secure donation handling with per-donor accounting.
  - Goal-based completion that pays out to the recipient.
  - Failure handling with per-donor refunds.
  - An admin role with pause/resume and force-fail capabilities.
  - A whitelist of verified recipients and visibility of verification status per campaign.
- The implementation uses:
  - Structs, enums, mappings, modifiers and events.
  - Custom errors, `require`, `assert`, explicit `revert`, `receive` and `fallback`.
- The accompanying test suite covers the core behaviour and key failure paths of the contract and can be executed with `npx hardhat test`.
- Overall, the implementation is aligned with the assignment’s functional and technical requirements, with additional safety and clarity built into the design.
