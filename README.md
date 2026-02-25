# Crowdfunding Smart Contract

A simple crowdfunding platform implemented in Solidity with:

- Campaign creation (recipient, goal, deadline)
- Donations with per-donor accounting
- Admin controls (pause/resume/force fail)
- Refunds for failed campaigns
- Verified recipient whitelist (live lookup)
- Test suite (Hardhat 3 + ethers v6)

---

## 1. Overview

Each campaign has a lifecycle modeled by an enum:

- `Active` → accepts donations until deadline
- `Paused` → donations blocked by admin
- `Successful` → goal reached and funds paid out to recipient
- `Failed` → goal not reached by deadline (or admin force-failed), donors can claim refunds

Key idea: **goal achievement is what makes a campaign successful**. The deadline stops donations, but does not invalidate reaching the goal.

---

## 2. Contract structure

### Structs / Enums

- `struct Campaign` includes:

  - `creator`
  - `recipient`
  - `goal`
  - `deadline`
  - `totalRaised` (current escrowed amount, set to `0` after successful payout)
  - `finalRaised` (snapshot of paid-out amount when campaign becomes successful)
  - `status` (`CampaignStatus`)

- `enum CampaignStatus { Active, Paused, Successful, Failed }`

### Storage

- `admin` (immutable)
- `campaignCount`
- `mapping(uint256 => Campaign) public campaigns`
- `mapping(uint256 => mapping(address => uint256)) public contributions`
- `mapping(address => bool) public verifiedRecipients`

---

## 3. Roles & access control

### Admin role

- `admin` is set once at deployment (`admin = msg.sender`) and marked `immutable`.
- `onlyAdmin` restricts the following functions:
  - `pauseCampaign(campaignId)`
  - `resumeCampaign(campaignId)`
  - `forceFailCampaign(campaignId)`
  - `setVerifiedRecipient(recipient, isVerified)`

### Campaign validation

- `validCampaign` ensures `campaignId < campaignCount`.

---

## 4. Core behavior

### Creating a campaign

`createCampaign(recipient, goal, deadline)`:

- Reverts if:
  - recipient is `address(0)` (`InvalidRecipient`)
  - goal is `0` (`ZeroValue`)
  - deadline is in the past (`DeadlinePassed`)
- Creates a new campaign in `Active` state.
- Emits `CampaignCreated` including a **snapshot** boolean for verification status at creation time.

### Donations

`donate(campaignId)`:

- Reverts if:
  - `msg.value == 0` (`ZeroValue`)
  - deadline has passed (`DeadlinePassed`)
  - campaign status is not `Active` (`InvalidState`)
- Updates:
  - `campaign.totalRaised += msg.value`
  - `contributions[campaignId][donor] += msg.value`
- Emits `DonationReceived`

### Finalizing a campaign

`finalizeCampaign(campaignId)`:

- Allowed only when status is `Active` or `Paused` (`InvalidState` otherwise)
- **Success rule (takes precedence):**
  - If `totalRaised >= goal`, campaign becomes `Successful`
  - Pays out to recipient
  - Sets:
    - `finalRaised = amount`
    - `totalRaised = 0`
  - Emits `CampaignSuccessful`
- **Failure rule:**
  - If goal is not met and deadline has passed, campaign becomes `Failed`
  - Emits `CampaignFailed`
- If deadline not reached and goal not met:
  - Reverts with `DeadlineNotReached`

### Refunds

`claimRefund(campaignId)`:

- Only allowed when campaign is `Failed` (`InvalidState` otherwise)
- Reverts if caller has no contribution (`NothingToRefund`)
- Uses checks-effects-interactions:
  - Zeroes out the donor contribution before transfer
- Transfers refund back to donor
- Emits `RefundIssued`

---

## 5. Verified recipients (whitelist)

- `verifiedRecipients[address]` is the **single source of truth**.
- `CampaignCreated` includes an emitted snapshot boolean for convenience, but frontend can always read:
  - `verifiedRecipients[campaign.recipient]`
- Helper:
  - `isRecipientVerified(campaignId)` returns current whitelist status for the campaign recipient.

---

## 6. Pause functionality

- `pauseCampaign(campaignId)` (admin only):

  - Only allowed when status is `Active`
  - Sets status to `Paused`
  - Emits `CampaignPaused`

- `resumeCampaign(campaignId)` (admin only):
  - Only allowed when status is `Paused`
  - Sets status to `Active`
  - Emits `CampaignResumed`

Paused campaigns:

- reject donations (`InvalidState`)
- can still be finalized (successful/failed depending on goal/deadline)
- can still be force-failed by admin

---

## 7. Safety & low-level controls

### Reentrancy guard

- `nonReentrant` is applied to:
  - `finalizeCampaign`
  - `claimRefund`

### ETH transfers

- Transfers are done via low-level `call`.
- Failures revert with custom errors:
  - `EthTransferFailed` (payout to recipient)
  - `RefundTransferFailed` (refund to donor)

### receive / fallback

- `receive()` reverts with custom error `DirectEthNotAllowed`
- `fallback()` reverts with custom error `InvalidCall`

---

## 8. Tests

- Tests are implemented in `test/Crowdfunding.test.js` using Hardhat 3 and ethers v6.
- The test suite covers:

  - Campaign creation (valid + invalid params)
  - Donations (happy path + deadline/paused/zero value)
  - Pause/resume permissions and behavior
  - Successful finalization (including finalize after deadline when goal reached)
  - Failed finalization (deadline passed without reaching goal) + refunds
  - Verified recipient whitelist changes (live lookup)
  - receive/fallback custom error behavior
  - forceFail admin-only behavior

  ***

Run tests:

```bash
npm install
npx hardhat test


```
