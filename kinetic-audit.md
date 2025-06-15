### [H-1] User can't withdraw funds if the `stakingManager` contract was deauthorized by `stakingAccountant` and the the token hold by the `stakingManager` is unique


**Description:** Function `StakingManager::confirmWithdrawal` calls function `StakingAccountant::recordClaim` which requires the `stakingManager` contract to be authorized. If the `stakingManager` is the only owner of its khype token and it gets deauthorized by `stakingAccountant`, the user `confirmWithdrawal` call results in the revert of transaction making the user unable to withdraw his funds.

**Impact:** User is unable to withdraw his hype from the protocol.

**Proof of Concept:**
1. User stakes hype to get khype tokens
2. `stakingManager` is deauthorized
3. User calls `queueWithdrawal` and after `confirmWithdrawal`
4. Because the token is owned by only one `stakingManager` contract the user can't withdraw his funds.

<details>
<summary> Code </summary>

```javascript
// add this to Base.t.sol
 function testVulnerability() public {
        
        address user1 = makeAddr("user");
        address validator = makeAddr("validator");
        vm.deal(address(stakingManager),2 ether); // Giving 2 ether cuz the targetBuffer is 0 and stake is not going to give the value to the contract, is going to give it to l1 contract
        vm.deal(user1,1 ether);
        vm.startPrank(manager);
        validatorManager.activateValidator(validator);
        validatorManager.setDelegation(address(stakingManager),validator);
        vm.stopPrank();
        vm.prank(user1);
        stakingManager.stake{value: 0.5 ether}();
        vm.prank(admin);
        stakingAccountant.deauthorizeStakingManager(address(stakingManager));
        vm.startPrank(user1);
        kHYPE.approve(address(stakingManager),0.5 ether);
        stakingManager.queueWithdrawal(0.3 ether);
        assert(stakingManager.withdrawalRequests(user1,0).kHYPEAmount>0); // assuring the request is valid
        vm.warp(60480111);
        vm.expectRevert("Not authorized");
        stakingManager.confirmWithdrawal(0);   
        

    }
```

</details>

**Recommended Mitigation:** In the `StakingAccountant::deauthorizeStakingManager` function, if total suply of the token is 0 and the token is unique send back the hype to owners


<details>

```diff
function deauthorizeStakingManager(address manager) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Get the token before removing the manager
        (bool exists, address token) = _authorizedManagers.tryGet(manager);
        require(exists, "Manager not found");

        _authorizedManagers.remove(manager);

        // Check if any other manager is using this token
        bool tokenStillInUse = false;
        uint256 length = _authorizedManagers.length();

        for (uint256 i = 0; i < length; i++) {
            (, address otherToken) = _authorizedManagers.at(i);
            if (otherToken == token) {
                tokenStillInUse = true;
                break;
            }
        }

        // If no other manager is using this token, remove it from unique tokens
-       if (!tokenStillInUse) {
+		if(!tokenStillInUse && token.totalSuply() == 0){
            _uniqueTokens.remove(token);
        }
+ 		else { sendBackHype(); }
        emit StakingManagerDeauthorized(manager);
    }
```
</details>


### [H-2] User who tries to recover his funds from an deauthorized `StakingManager` by calling withdraw from another `StakingManager` contract breaks the exchange ratio.

**Description:** 

After deauthorizing an `StakingManager` contract an owner of the token that staked his hype trough this contract can try to withdraw his funds using another `StakingManager` contract which holds the same token resulting in taking away the balance of the contract which can be supplied with hype by calling `StakingManager::stake` which means there will be minted more tokens which will break the exchange ratio.

**Impact:** Braks the exchange ratio from `StakingAccountant`.

**Proof of Concept:**
```
Not including the rewards and fees 

        1 hype           khypeToken
user1 ---------->    stakingManager1 ❌        user1 now has amount1(khype) = 1 hype
         stake        	   1 hype 

        3 hype           khypeToken
user2 ---------->    stakingManager2 ✅        user2 now has amount2(khype) = 3 hype    
         stake             3 hype 


        1 hype           khypeToken
user1 <----------    stakingManager2 ✅        user1 now has 1 hype = amount1(khype)
		withdraw		  2 hype

		3 hype           khypeToken
user2 <----------    stakingManager2 ✅        user2 can't withdraw 3 hype = amount2(khype) because there is insuficient balance
		withdraw		  2 hype
```
Contract  `StakingManager` receive function calls `StakingManager::stake` which means it can get funds if it mints khype
Only method to resuply the `StakingManager` is a selfdestruct contract but this will break the exchange ratio because the hype is not accounted.
The function for rescuing the funds do not update the hype/khype which means even if the funds are recovered the exchange ratio will be broken.

- In the base.t.sol conract i added a new stakingManager1 owning the same token as the first stakingManager
<details>
<sumary> Code </sumary>

```javascript
function testVulnerability3() public{
        address user1 = makeAddr("user");
        address user2 = makeAddr("user2");
        address validator = makeAddr("validator");
        address validator1 = makeAddr("validator1");
        uint256 blocktime = 604810;

        vm.deal(user1, 3 ether);
        vm.deal(user2, 3 ether);

        vm.startPrank(manager);
        stakingAccountant.authorizeStakingManager(address(stakingManager1),address(kHYPE));
        vm.stopPrank();

        vm.startPrank(manager);
        validatorManager.activateValidator(validator);
        validatorManager.setDelegation(address(stakingManager), validator);
        stakingManager.setTargetBuffer(1 ether);
        vm.stopPrank();

        vm.startPrank(manager);
        validatorManager.activateValidator(validator1);
        validatorManager.setDelegation(address(stakingManager1), validator1);
        stakingManager1.setTargetBuffer(1 ether);
        vm.stopPrank();

        vm.prank(user1);
        // first user stkaes 1 ether for khype
        stakingManager.stake{value: 1 ether}();

        vm.prank(user2);
        // first user stkaes 1 ether for khype
        stakingManager1.stake{value: 1 ether}();

        vm.prank(admin);
        stakingAccountant.deauthorizeStakingManager(address(stakingManager));

        vm.startPrank(user1);
        kHYPE.approve(address(stakingManager1), 2 ether);
        uint256 khypeTokensForUser1 = kHYPE.balanceOf(user1);
        console.log("user1 amount of khype tokens:", khypeTokensForUser1);
        uint256 amountUser1ShouldBeAbleToWithdraw = stakingAccountant.kHYPEToHYPE(khypeTokensForUser1);
        console.log("amount user2 can withdraw from his tokens: ", amountUser1ShouldBeAbleToWithdraw);
        stakingManager1.queueWithdrawal(0.9 ether);
        vm.warp(blocktime);
        stakingManager1.confirmWithdrawal(0);
        vm.stopPrank();

        vm.startPrank(user2);
        kHYPE.approve(address(stakingManager1), 2 ether);
        uint256 khypeTokensForUser2 = kHYPE.balanceOf(user1);
        console.log("user1 amount of khype tokens:", khypeTokensForUser2);
        uint256 amountUser2ShouldBeAbleToWithdraw = stakingAccountant.kHYPEToHYPE(khypeTokensForUser2);
        console.log("amount user2 can withdraw from his tokens: ", amountUser2ShouldBeAbleToWithdraw);
        stakingManager1.queueWithdrawal(0.9 ether);
        vm.warp(blocktime*2);
        vm.expectRevert("Insufficient contract balance");
        stakingManager1.confirmWithdrawal(0);
        vm.stopPrank();

    }
```
</details>

**Recommended Mitigation:** Improve rescue functions in `StakingManager` and handle properly `Stakingaccountant::deauthorizeStakingManager` funds of users and contracts;

### [H-3] `OracleManager::generatePerformance` function can be frontrunned giving anyone the posibility to constantly gain profit over stake and withdraw cycles


**Description:** Functions stake and withdraw from StakingManager.sol contract use `StakingAccountant::_getExchangeRatio` function which uses `validatorManager.totalRewards()` and `validatorManager.totalSlashing()` to calculate the totalHype which then is used for the ratio.
<details>
<summary> _getExchangeRatio </summary>
	
```javascript
	uint256 rewardsAmount = validatorManager.totalRewards();
	uint256 slashingAmount = validatorManager.totalSlashing();
	uint256 totalHYPE = totalStaked + rewardsAmount - totalClaimed - slashingAmount;
```
</details>

Contract OracleManager.sol modifies totalRewards and totalSlashing from ValidatorManager every time the function `generatePerformance` is called (once a day). 

<details>
<summary> generatePerformance </summary>

```javascript
     // Update validator performance in ValidatorManager
        validatorManager.updateValidatorPerformance(
            validator, avgBalance, avgUptimeScore, avgSpeedScore, avgIntegrityScore, avgSelfStakeScore
        );

        // Report only new rewards/slashing
        if (avgRewardAmount > previousRewards) {
            uint256 newRewardAmount = avgRewardAmount - previousRewards;
            validatorManager.reportRewardEvent(validator, newRewardAmount);
        }
        if (avgSlashAmount > previousSlashing) {
            uint256 newSlashAmount = avgSlashAmount - previousSlashing;
            validatorManager.reportSlashingEvent(validator, newSlashAmount);
        }
```
</details>
This leaves room for an attakcer to frontrun the tranzaction and stake/withdraw to make a profit based on the changes in the hype/khype ratio

**Impact:** Anyone can constanly gain a profit by frontrunning the generatePerformance function.

**Proof of Concept:**
1. `OracleManager::generatePerformance` is called
2. Someone can frontrun the tranzaction and se if the Hype/Khype ratio is going down or up based on the rewards/slashes 
3. Stake / withdraw to gain profit

**Recommended Mitigation:**  Use private nodes. (It was out of scope)




### [M-1] If an attacker is also an validator who can purposly make the protocol slash his rewards he can purposly mofiy the exchange ratio making him able to buy KHYPE at a lower price and sell it later when the rewards grow


**Description:** An attacker can manipulate the exchange ratio by manipulating the slashingAmount in `totalHYPE = totalStaked + rewardsAmount - totalClaimed - slashingAmount` if he either is a validator 

**Impact:** Profit over other validators rewards

**Proof of Concept:**

```
1. Initial state
exchange ratio 1:1

100 000 hype ----------> 100 000 khype

totalHYPE = totalStaked + rewardsAmount - totalClaimed - slashingAmount
              180 000        30 000         80 000          10 000

2. Attacker purposly slashes his rewards maybe even gets deactivated for it (it can even slash from multtiple validators accounts if he owns them or controls them in some way)

95 000 hype ----------> 100 000 khype 

totalHYPE = totalStaked + rewardsAmount - totalClaimed - slashingAmount
              180 000        30 000         80 000          15 000

3. Attacker buys khype at a lower price

190 000 hype -----------> 200 000 hype

        
totalHYPE = totalStaked + rewardsAmount - totalClaimed - slashingAmount
              270 000        30 000         80 000          15 000

4. Later exchange ratio rises to 1.1

220 000 hype -----------> 200 000 khype

totalHYPE = totalStaked + rewardsAmount - totalClaimed - slashingAmount
              480 000        40 000         280 000          20 000

5. Attacker sells his tokens for a profit 
100 000 khype -----> 110 000 hype 
```

In total the attacker lost 5 000 hype from slashing and gained 10 000 after the exchange ratio raised 


**Recommended Mitigation:** While a precise fix is difficult to define without redesigning the exchange ratio logic, one approach may involve decoupling volatile values (such as slashing) from the global exchange ratio.





### [L-1] `StakingManager::queueWithdrawal` function does not have a minimal amount to withdraw making possible an attacker to add multiple withdrawals request making processing of the withdrawal requests slower and mor gas expensive

**Description:** An attacker can add multiple withdrawals requests in the queue.

**Impact:** Makes processing of the queue harder.

**Recommended Mitigation:** Add a minimum amount to withdrawal to the `StakingManager::queueWithdrawal` function




