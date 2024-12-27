# Compota

**Compota** is an ERC20 token designed to **continuously** accrue rewards for its holders. These rewards come in two main forms:
1. **Base Rewards**: Simply holding the token yields automatically accruing interest over time.  
2. **Staking Rewards**: Staking **Uniswap V2-compatible** liquidity pool (LP) tokens for additional yield, boosted by a **time-based cubic multiplier** applied to the staking rewards formula.

The system also introduces key features such as **configurable interest rate bounds**, a **reward cooldown** to prevent **excessive compounding**, a **maximum total supply cap**, **multi-pool** staking, and thorough **ownership** controls. This README explains every novel element, mathematical underpinning, usage flow, and test coverage in great detail.

---

## Table of Contents

1. [Conceptual Overview](#conceptual-overview)  
2. [Feature Highlights](#feature-highlights)  
3. [Contract Architecture](#contract-architecture)  
4. [Mathematical Foundations of Rewards](#mathematical-foundations-of-rewards)  
   - [Base Rewards](#base-rewards)  
   - [Staking Rewards](#staking-rewards)  
   - [Cubic Multiplier](#cubic-multiplier)  
   - [Average Balance & Accumulated Balance Per Time](#average-balance--accumulated-balance-per-time)  
5. [Implementation Details](#implementation-details)  
   - [Multi-Pool Support](#multi-pool-support)  
   - [Min/Max Yearly Rate](#minmax-yearly-rate)  
   - [Reward Cooldown](#reward-cooldown)  
   - [Max Total Supply Constraint](#max-total-supply-constraint)  
   - [Global vs. User-Specific Reward Updates](#global-vs-user-specific-reward-updates)  
   - [Active Stakers Management](#active-stakers-management)  
   - [Precision & Overflow Protection](#precision--overflow-protection)  
   - [Custom Errors & Event Emissions](#custom-errors--event-emissions)  
6. [Why Uniswap V2?](#why-uniswap-v2)  
7. [Ownership & Access Control](#ownership--access-control)  
8. [Overridden ERC20 Methods](#overridden-erc20-methods) 
9. [API Reference & Methods](#api-reference--methods)  
   - [ICompota Interface](#icompota-interface)  
   - [Additional Public/External Functions](#additional-publicexternal-functions)   
10. [Security & Audit Considerations](#security--audit-considerations)  
11. [License](#license)

---

## Conceptual Overview

`Compota` is a system that **auto-accrues** yield for holders while also allowing **stakers** to earn boosted returns. The **boost** is governed by a **cubic multiplier** that scales rewards significantly the longer the staker remains in the pool. Additionally, the system is designed with **predictable** rate changes (bounded by min/max BPS), a **reward cooldown** to prevent abuse via rapid re-claims, and a **maximum total supply** that caps inflation.

---

## Feature Highlights

1. **Continuous Accrual**: Rewards accumulate over time, without constant user claims.  
2. **Cubic Multiplier**: Novel time-based booster for stakers, culminating in higher returns for longer durations.  
3. **Multi-Pool Staking**: Supports multiple LP tokens, each with distinct parameters.  
4. **Configurable Rate Bounds**: An **owner** can adjust the yearlyRate (APR in BPS) within `[MIN_YEARLY_RATE, MAX_YEARLY_RATE]`.  
5. **Reward Cooldown**: Users must wait a specified period to claim new rewards, preventing **over-compounding**.  
6. **Max Total Supply**: Prevents unbounded inflation.  

---

## Contract Architecture

`Compota` inherits from:
- **ERC20Extended**: A standard token interface (with 6 decimals) plus minor utility methods:
   - We use the **[M0 standard ERC20Extended](https://github.com/m0-foundation/common/blob/main/src/ERC20Extended.sol)** because it incorporates additional functionality beyond the standard ERC20, including EIP-2612 for signed approvals (via EIP-712, with compatibility for EIP-1271 and EIP-5267) and EIP-3009 for transfers with authorization (also using EIP-712). This makes the token more versatile and compatible with modern cryptographic signing standards, improving user experience and flexibility. 
- **Owned**: An ownership module from **Solmate** controlling certain admin functions.

It interfaces with:
- **ICompota**: The main external interface.  
- **IERC20** 
- **IUniswapV2Pair**: For reading pool reserves (`getReserves()`) and identifying token addresses, ensuring **Uniswap v2** compatibility.

**Data structures** central to the system:

- **`AccountBalance`**: Tracks base holdings for each user.  
- **`UserStake`**: Tracks staked LP and relevant timestamps.  
- **`StakingPool`**: Parameters for each pool, including `lpToken`, `multiplierMax`, `timeThreshold`.

---

## Mathematical Foundations of Rewards

### Base Rewards

For **base rewards**, each address’s holding grows according to:

**Δ_base = (avgBalance * elapsedTime * yearlyRate) / (SCALE_FACTOR * SECONDS_PER_YEAR)**

where:  
- **avgBalance** is the user’s time-weighted average holdings,  
- **elapsedTime** is the number of seconds since last update,  
- **yearlyRate** is in BPS,  
- **SCALE_FACTOR** = 10,000,  
- **SECONDS_PER_YEAR** = 31,536,000.

---

### Staking Rewards

When **staking** an LP token, the user’s effective portion of `Compota` in the pool is determined by:

**compotaPortion = (avgLpStaked * compotaReserve) / lpTotalSupply**

The staking reward itself (Δ_staking) applies the **cubic multiplier** in the final step:

**Δ_staking = (compotaPortion * elapsedTime * yearlyRate) / (SCALE_FACTOR * SECONDS_PER_YEAR) * cubicMultiplier(t)**

---

### Cubic Multiplier

A core innovation is the **cubic multiplier** for staking. Let:
- t = timeStaked  
- timeThreshold  
- multiplierMax (scaled by 1e6)

Then:

**cubicMultiplier(t) = multiplierMax      if t >= timeThreshold**

**cubicMultiplier(t) = 1*10^6 + (multiplierMax - 10^6) * (t / timeThreshold)^3      if t < timeThreshold**

---

### Average Balance & Accumulated Balance Per Time

By using an **average balance** rather than a single snapshot, Compota fairly accounts for both the amount of tokens a user holds (or stakes) and how long they hold them. If only an instantaneous balance was measured, users could briefly inflate their balance right before a snapshot to gain disproportionate rewards. Meanwhile, those consistently holding or staking a moderate balance over a longer period would be undercompensated. The time-weighted average ensures that each user’s reward is proportional not just to the magnitude of their balance, but also to the duration they keep it, reflecting a more accurate and equitable distribution of yield.

To compute **average balance**, the contract uses **discrete integration** at every balance-changing event (transfer, stake, unstake, claim).

1. Accumulate:

**accumulatedBalancePerTime += (balance * (T_now - lastUpdateTimestamp))**

**lastUpdateTimestamp = T_now**

2. Average Balance:

**avgBalance = accumulatedBalancePerTime / (T_final - periodStartTimestamp)**

This yields a **time-weighted average** of how much the user held or staked.

---

## Implementation Details

### Multi-Pool Support
- The contract holds an array of `StakingPool`.
- Each pool has its own LP token, `multiplierMax`, and `timeThreshold`.
- Users can stake/unstake by specifying `poolId`.

### Min/Max Yearly Rate
- `MIN_YEARLY_RATE` and `MAX_YEARLY_RATE` define the allowable range.
- Attempts to set `yearlyRate` outside this range revert.

### Reward Cooldown
- A global `rewardCooldownPeriod` ensures a user cannot claim rewards too often, preventing **over-compounding**.
- If a user attempts to claim before cooldown finishes, only their internal accounting is updated.

### Max Total Supply Constraint
- Any token mint or reward mint cannot exceed `maxTotalSupply`.
- If a reward calculation attempts to exceed the supply cap, it is truncated.

### Global vs. User-Specific Reward Updates
- Maintains global timestamps plus user-specific data (`AccountBalance`, `UserStake`).
- Ensures each user’s pending rewards are accurately tracked and minted only if cooldown passes.

### Active Stakers Management
- Tracks stakers in an `activeStakers` array + `_activeStakerIndices` mapping.
- Users are removed from the list when they fully unstake from all pools.

### Precision & Overflow Protection
- Uses `uint224` to avoid overflow.
- BPS calculations are scaled by `10,000`, multipliers by `1e6`.
- Casting is checked with `toSafeUint224`.

### Custom Errors & Event Emissions
- Custom errors like `InvalidYearlyRate`, `NotEnoughStaked`, `InsufficientAmount` give precise revert reasons.
- Events like `YearlyRateUpdated`, `RewardCooldownPeriodUpdated` ensure transparency.

---

## Why Uniswap V2?

The Compota contract is designed to work with **Uniswap V2-compatible liquidity pools** for the following reasons:

1. **Simplicity and Compatibility**:  
   Uniswap V2 provides a straightforward mechanism to retrieve pool reserves via the `getReserves()` function. This allows the contract to calculate the `Compota` portion in the pool with minimal complexity, ensuring efficient and reliable reward calculations.

2. **Standardization**:  
   The V2 interface is widely adopted and integrated across various DeFi ecosystems. By relying on this standard, Compota ensures compatibility with most decentralized exchanges and LP tokens available today.

3. **Future-Proofing with Uniswap V4**:  
   While Uniswap V4 introduces new features and changes, its flexibility allows pools to be adapted to emulate V2 behavior. For example, projects like [V2PairHook](https://github.com/hensha256/v2-on-v4/blob/main/src/V2PairHook.sol) demonstrate how V4 pools can be wrapped to mimic V2 interfaces. This ensures that Compota will remain compatible with future developments in Uniswap.

4. **Efficiency in Reserve Calculations**:  
   The reserve-based calculations in V2 are straightforward and require minimal on-chain processing, making them gas-efficient. This aligns with Compota’s goal of delivering robust rewards mechanisms while keeping costs manageable for users.

By leveraging Uniswap V2 compatibility, Compota ensures a balance between current usability and adaptability to future innovations, making it a solid choice for staking and reward distribution.

---

## Ownership & Access Control

- Inherits `Owned` from **Solmate**.
- Only the `owner` has the privilege to:
  - **Set `yearlyRate`**: Adjust the annual percentage yield within the min/max range.
  - **Set `rewardCooldownPeriod`**: Define the cooldown period for claiming rewards.
  - **Add staking pools**: Introduce new liquidity pool options with custom parameters.
  - **Mint new tokens**: Create additional tokens, respecting the `maxTotalSupply` constraint.
- Non-owners cannot perform these privileged actions.

---

## Overridden ERC20 Methods

The Compota contract customizes several standard ERC20 methods to incorporate rewards logic and enforce system constraints:

1. **`balanceOf(address account)`**:  
   - Returns the current token balance, **including unclaimed base and staking rewards**.  
   - This ensures users see their effective balance at all times.

2. **`totalSupply()`**:  
   - Dynamically calculates the total supply, **including all pending unclaimed rewards** across accounts.  
   - Enforces the `maxTotalSupply` constraint.

3. **`_transfer(address sender, address recipient, uint256 amount)`**:  
   - Updates reward states for both the sender and the recipient before executing the token transfer.  
   - Maintains accurate reward calculations for all involved parties.

4. **`_mint(address to, uint256 amount)`**:  
   - Ensures the `maxTotalSupply` constraint is respected during minting.  
   - Updates internal reward states when minting tokens.

5. **`_burn(address from, uint256 amount)`**:  
   - Verifies sufficient balance (including pending rewards) before burning tokens.  
   - Adjusts internal balances and the total supply accordingly.

These overrides ensure that **reward logic and supply constraints** are seamlessly integrated into ERC20 operations without disrupting compatibility.

---

## API Reference & Methods

### ICompota Interface

1. **`setYearlyRate(uint16 newRate_)`**  
Adjusts APY (BPS) within `[MIN_YEARLY_RATE, MAX_YEARLY_RATE]`.

2. **`setRewardCooldownPeriod(uint32 newRewardCooldownPeriod_)`**  
Changes the cooldown for claiming.

3. **`addStakingPool(address lpToken_, uint32 multiplierMax_, uint32 timeThreshold_)`**  
Introduces a new pool.

4. **`stakeLiquidity(uint256 poolId_, uint256 amount_)`**  
Stakes LP tokens in `poolId_`.

5. **`unstakeLiquidity(uint256 poolId_, uint256 amount_)`**  
Unstakes LP tokens from `poolId_`.

6. **`mint(address to_, uint256 amount_)`**  
Owner-only. Respects `maxTotalSupply`.

7. **`burn(uint256 amount_)`**  
Burns user’s tokens.

8. **`balanceOf(address account_) returns (uint256)`**  
Current user balance + unclaimed rewards.

9. **`calculateBaseRewards(address account_, uint32 currentTimestamp_) returns (uint256)`**  
Helper function for base reward math.

10. **`calculateStakingRewards(address account_, uint32 currentTimestamp_) returns (uint256)`**  
 Helper function for staking reward math.

11. **`totalSupply() returns (uint256)`**  
 Global supply including pending rewards.

12. **`claimRewards()`**  
 Mints pending rewards if cooldown is met; otherwise updates state.

### Additional Public/External Functions
- **`calculateCubicMultiplier(uint256 multiplierMax_, uint256 timeThreshold_, uint256 timeStaked_) returns (uint256)`**  
Public helper to view the multiplier growth.

---

## Security & Audit Considerations

- **Ownership**: The `owner` can change rates, add pools, and mint tokens—adopt secure governance (e.g., multisig).
- **Time Manipulation**: Miners can nudge block timestamps slightly, but the contract’s design minimizes material impact over long durations.
- **Rate Boundaries**: Constraining the APY within `[MIN_YEARLY_RATE, MAX_YEARLY_RATE]` prevents extreme or sudden changes.
- **Cooldown Enforcement**: Thwarts repeated reward claims, limiting excessive compounding exploitation.
- **Max Supply**: Caps total token issuance to prevent runaway inflation.
- **Uniswap v2**: Straightforward reserve interface. For v4, consider [this wrapper approach](https://github.com/hensha256/v2-on-v4/blob/main/src/V2PairHook.sol).

---

## License

All code in `Compota.sol` and associated files is published under the **GPL-3.0** license.  
For full details, see the [LICENSE](./LICENSE) file.

🍎✨ **Dive into the sweet world of Compota—where your rewards grow continuously!** ✨🍐


## Getting started

The easiest way to get started is by clicking the [Use this template](https://github.com/MZero-Labs/foundry-template/generate) button at the top right of this page.

If you prefer to go the CLI way:

```bash
forge init my-project --template https://github.com/MZero-Labs/foundry-template
```

## Development

### Installation

You may have to install the following tools to use this repository:

- [Foundry](https://github.com/foundry-rs/foundry) to compile and test contracts
- [lcov](https://github.com/linux-test-project/lcov) to generate the code coverage report
- [slither](https://github.com/crytic/slither) to static analyze contracts

Install dependencies:

```bash
npm i
```

### Env

Copy `.env` and write down the env variables needed to run this project.

```bash
cp .env.example .env
```

### Compile

Run the following command to compile the contracts:

```bash
npm run compile
```

### Coverage

Forge is used for coverage, run it with:

```bash
npm run coverage
```

You can then consult the report by opening `coverage/index.html`:

```bash
open coverage/index.html
```

### Test

To run all tests:

```bash
npm test
```

Run test that matches a test contract:

```bash
forge test --mc <test-contract-name>
```

Test a specific test case:

```bash
forge test --mt <test-case-name>
```

To run slither:

```bash
npm run slither
```

### Code quality

[Husky](https://typicode.github.io/husky/#/) is used to run [lint-staged](https://github.com/okonet/lint-staged) and tests when committing.

[Prettier](https://prettier.io) is used to format code. Use it by running:

```bash
npm run prettier
```

[Solhint](https://protofire.github.io/solhint/) is used to lint Solidity files. Run it with:

```bash
npm run solhint
```

To fix solhint errors, run:

```bash
npm run solhint-fix
```

### CI

The following Github Actions workflow are setup to run on push and pull requests:

- [.github/workflows/coverage.yml](.github/workflows/coverage.yml)
- [.github/workflows/test-gas.yml](.github/workflows/test-gas.yml)

It will build the contracts and run the test coverage, as well as a gas report.

The coverage report will be displayed in the PR by [github-actions-report-lcov](https://github.com/zgosalvez/github-actions-report-lcov) and the gas report by [foundry-gas-diff](https://github.com/Rubilmax/foundry-gas-diff).

For the workflows to work, you will need to setup the `MNEMONIC_FOR_TESTS` and `MAINNET_RPC_URL` repository secrets in the settings of your Github repository.

Some additional workflows are available if you wish to add fuzz, integration and invariant tests:

- [.github/workflows/test-fuzz.yml](.github/workflows/test-fuzz.yml)
- [.github/workflows/test-integration.yml](.github/workflows/test-integration.yml)
- [.github/workflows/test-invariant.yml](.github/workflows/test-invariant.yml)

You will need to uncomment them to activate them.

### Documentation

The documentation can be generated by running:

```bash
npm run doc
```

It will run a server on port 4000, you can then access the documentation by opening [http://localhost:4000](http://localhost:4000).

## Deployment

### Build

To compile the contracts for production, run:

```bash
npm run build
```

### Deploy

#### Local

Open a new terminal window and run [anvil](https://book.getfoundry.sh/reference/anvil/) to start a local chain:

```bash
anvil
```

Deploy the contracts by running:

```bash
npm run deploy-local
```

#### Sepolia

To deploy to the Sepolia testnet, run:

```bash
npm run deploy-sepolia
```
