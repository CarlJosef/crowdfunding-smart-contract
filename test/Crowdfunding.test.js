import { expect } from "chai";
import hre from "hardhat";

const { ethers, networkHelpers } = await hre.network.connect();

describe("Crowdfunding", function () {
  let crowdfunding;
  let admin, creator, donor1, donor2, recipient, other;
  const ONE_ETH = ethers.parseEther("1");

  beforeEach(async function () {
    [admin, creator, donor1, donor2, recipient, other] =
      await ethers.getSigners();

    const Crowdfunding = await ethers.getContractFactory("Crowdfunding", admin);
    crowdfunding = await Crowdfunding.deploy();
    await crowdfunding.waitForDeployment();
  });

  async function createBasicCampaign(goal = ONE_ETH, durationSeconds = 3600) {
    const latestBlock = await ethers.provider.getBlock("latest");
    const deadline = latestBlock.timestamp + durationSeconds;

    await crowdfunding
      .connect(creator)
      .createCampaign(recipient.address, goal, deadline);

    const campaignCount = await crowdfunding.campaignCount();
    const campaignId = campaignCount - 1n;

    return { campaignId, deadline };
  }

  it("creates a campaign with correct initial data", async function () {
    const goal = ONE_ETH;
    const { campaignId, deadline } = await createBasicCampaign(goal, 3600);

    const campaign = await crowdfunding.campaigns(campaignId);

    expect(campaign.creator).to.equal(creator.address);
    expect(campaign.recipient).to.equal(recipient.address);
    expect(campaign.goal).to.equal(goal);
    expect(campaign.deadline).to.equal(deadline);
    // CampaignStatus.Active = 0
    expect(campaign.status).to.equal(0n);
  });

  it("reverts when creating campaign with zero goal", async function () {
    const latestBlock = await ethers.provider.getBlock("latest");
    const deadline = latestBlock.timestamp + 3600;

    await expect(
      crowdfunding
        .connect(creator)
        .createCampaign(recipient.address, 0n, deadline),
    ).to.be.revertedWithCustomError(crowdfunding, "ZeroValue");
  });

  it("reverts when creating campaign with past deadline", async function () {
    const latestBlock = await ethers.provider.getBlock("latest");
    const pastDeadline = latestBlock.timestamp - 1;

    await expect(
      crowdfunding
        .connect(creator)
        .createCampaign(recipient.address, ONE_ETH, pastDeadline),
    ).to.be.revertedWithCustomError(crowdfunding, "DeadlinePassed");
  });

  it("accepts donations for active campaign and tracks contributions", async function () {
    const { campaignId } = await createBasicCampaign(ONE_ETH, 3600);

    await crowdfunding.connect(donor1).donate(campaignId, { value: ONE_ETH });

    const campaign = await crowdfunding.campaigns(campaignId);
    const contribution = await crowdfunding.contributions(campaignId, donor1);

    expect(campaign.totalRaised).to.equal(ONE_ETH);
    expect(contribution).to.equal(ONE_ETH);
  });

  it("reverts on zero-value donations", async function () {
    const { campaignId } = await createBasicCampaign(ONE_ETH, 3600);

    await expect(
      crowdfunding.connect(donor1).donate(campaignId, { value: 0n }),
    ).to.be.revertedWithCustomError(crowdfunding, "ZeroValue");
  });

  it("reverts donations after deadline", async function () {
    const { campaignId } = await createBasicCampaign(ONE_ETH, 1);

    await networkHelpers.time.increase(4000);
    await networkHelpers.mine();

    await expect(
      crowdfunding.connect(donor1).donate(campaignId, { value: ONE_ETH }),
    ).to.be.revertedWithCustomError(crowdfunding, "DeadlinePassed");
  });

  it("admin can pause and resume a campaign, blocking donations while paused", async function () {
    const { campaignId } = await createBasicCampaign(ONE_ETH, 3600);

    await crowdfunding.connect(admin).pauseCampaign(campaignId);

    await expect(
      crowdfunding.connect(donor1).donate(campaignId, { value: ONE_ETH }),
    ).to.be.revertedWithCustomError(crowdfunding, "InvalidState");

    await crowdfunding.connect(admin).resumeCampaign(campaignId);

    await crowdfunding.connect(donor1).donate(campaignId, { value: ONE_ETH });

    const campaign = await crowdfunding.campaigns(campaignId);
    expect(campaign.totalRaised).to.equal(ONE_ETH);
  });

  it("non-admin cannot pause or resume campaigns", async function () {
    const { campaignId } = await createBasicCampaign(ONE_ETH, 3600);

    await expect(
      crowdfunding.connect(donor1).pauseCampaign(campaignId),
    ).to.be.revertedWithCustomError(crowdfunding, "NotAdmin");

    await crowdfunding.connect(admin).pauseCampaign(campaignId);

    await expect(
      crowdfunding.connect(donor1).resumeCampaign(campaignId),
    ).to.be.revertedWithCustomError(crowdfunding, "NotAdmin");
  });

  it("finalizes successful campaign and sends funds to recipient", async function () {
    const goal = ONE_ETH;
    const { campaignId } = await createBasicCampaign(goal, 3600);

    const donation = ONE_ETH;

    await crowdfunding.connect(donor1).donate(campaignId, { value: donation });

    const beforeBalance = await ethers.provider.getBalance(recipient.address);

    await crowdfunding.finalizeCampaign(campaignId);

    const afterBalance = await ethers.provider.getBalance(recipient.address);
    const campaign = await crowdfunding.campaigns(campaignId);

    expect(campaign.status).to.equal(2n); // CampaignStatus.Successful
    expect(campaign.totalRaised).to.equal(0n);
    expect(afterBalance - beforeBalance).to.equal(donation);
  });

  it("allows admin to manage verified recipients", async function () {
    expect(await crowdfunding.verifiedRecipients(recipient.address)).to.equal(
      false,
    );

    await crowdfunding
      .connect(admin)
      .setVerifiedRecipient(recipient.address, true);

    expect(await crowdfunding.verifiedRecipients(recipient.address)).to.equal(
      true,
    );

    await crowdfunding
      .connect(admin)
      .setVerifiedRecipient(recipient.address, false);

    expect(await crowdfunding.verifiedRecipients(recipient.address)).to.equal(
      false,
    );
  });

  it("reverts setVerifiedRecipient for zero address", async function () {
    await expect(
      crowdfunding
        .connect(admin)
        .setVerifiedRecipient(ethers.ZeroAddress, true),
    ).to.be.revertedWithCustomError(crowdfunding, "InvalidCampaign");
  });

  it("reverts direct ETH transfers via receive()", async function () {
    await expect(
      donor1.sendTransaction({
        to: crowdfunding.target,
        value: ONE_ETH,
      }),
    ).to.be.revertedWith("Direct ETH transfers not allowed");
  });

  it("reverts invalid calls via fallback()", async function () {
    await expect(
      donor1.sendTransaction({
        to: crowdfunding.target,
        value: ONE_ETH,
        data: "0x1234",
      }),
    ).to.be.revertedWith("Invalid call");
  });

  it("allows admin to force fail an active campaign", async function () {
    const { campaignId } = await createBasicCampaign(ONE_ETH, 3600);

    await crowdfunding.connect(admin).forceFailCampaign(campaignId);

    const campaign = await crowdfunding.campaigns(campaignId);
    expect(campaign.status).to.equal(3n); // CampaignStatus.Failed
  });

  it("only allows forceFail from admin", async function () {
    const { campaignId } = await createBasicCampaign(ONE_ETH, 3600);

    await expect(
      crowdfunding.connect(donor1).forceFailCampaign(campaignId),
    ).to.be.revertedWithCustomError(crowdfunding, "NotAdmin");
  });
});
