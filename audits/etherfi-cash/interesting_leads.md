
## Idee / Known issue / inca worth un deep dive 
    - pe flowul de liquidatable am un return `loose > pending ? loose - pending : 0;`, e posibil ca pending sa fie mai mare ca loose in casul unui rebasing token sau un token care isi reduce valoarea sau ceva similar, gpt a gasit exemplul asta in care pending e mai mic decat balance ceea ce poate duce la o idee de genul: 
    user vrea sa faca withdraw, pending devine mai mare decat balance si chiar daca in mod normal userul ar trebui sa fie lichidabilacel cap la 0 ma scoate din lichidare, process withdrawal nu va reusi dar posibil sa pot amana o lichidare atata timp cat am colateral relativ suficient

    - In the liquidatable flow, I have a return value of `loose > pending ? loose - pending : 0;`. It is possible for `pending` to exceed `loose`—for instance, with a rebasing token or one that decreases in value. GPT found an example where `pending` is less than the balance, which suggests a scenario like this: a user wants to withdraw, causing `pending` to exceed the balance; even if the user would normally be liquidatable, that zero-floor logic prevents the liquidation from triggering. The withdrawal process itself might fail, but I could potentially delay liquidation as long as I have relatively sufficient collateral.

    - deocamdata asta e singurul cas de loose < pending, am mai gasit un case dupa fuzzing:

            pending withdrawal is initially covered
                ↓
            external token mutates/debits the Safe balance
                    ↓
            pending > loose balance
                    ↓
            CashLens reports zero idle balance
                    ↓
            processing cannot complete, but cancellation remains available

    - raman niste intrebari totusi, se adauga tokenul asta la ltv?

## Date
No true balance-rebasing token is currently listed.

I queried the production CashModule directly:

- Optimism: 24 withdrawal assets.
- Scroll: 17 withdrawal assets.

The yield-bearing assets use fixed-balance share accounting:

- `weETH` is explicitly non-rebasing. [Ether.fi documentation](https://etherfi.gitbook.io/etherfi/ether.fi-whitepaper/introduction)
- `eBTC`, `sETHFI`, `liquidETH`, `liquidUSD`, `liquidBTC`, and `eUSD` are Veda BoringVault shares. Yield/loss changes the Accountant exchange rate, not `balanceOf`. [Veda Accountant](https://docs.veda.tech/architecture-and-flow-of-funds/accountant)
- Superstate-style assets use static token balances with changing NAV per share. [Superstate documentation](https://docs.superstate.com/ustb/income-fees-and-yield)
- Stablecoins, WETH, OP, ETHFI, wHYPE and the remaining wrappers use ordinary balance accounting.

Therefore, the Echidna sequence:

```text
request withdrawal
→ negative rebase autonomously decreases Safe balance
→ pending > balance
```

is not reachable through the normal economics of currently listed tokens.

However, I found a separate production-real path that can create the same state.

The old Optimism `liquidRESERVE` token at `0xE5d385...` implements:

```solidity
function batchRedeem(address[] calldata accounts)
    external
    onlyBatchRedeemAdmin
{
    for (...) {
        uint256 amount = balanceOf(accounts[i]);
        _burn(accounts[i], amount);
        MIDAS_TOKEN.safeTransfer(accounts[i], amount);
    }
}
```

This replaces the old token with the new `liquidRESERVE` token at `0xca5921...`. It was actually executed twice on May 8, 2026:

- [First batchRedeem transaction](https://optimism.blockscout.com/tx/0x0f331b563d1451ad04dad46a3e96ee41297f5291c6401eaf70412646cb72e310)
- [Large batchRedeem transaction](https://optimism.blockscout.com/tx/0xc2c1e5ee87708ea54dd5077d2fc53fabc44c1616f20d8abd08c18dfcdb98caf2)

I checked the calldata and registry:

- 288 unique accounts were migrated.
- 287 were registered EtherFi Safes.
- Immediately before the large migration, both old and new `liquidRESERVE` were whitelisted withdrawal assets.

Therefore, this sequence is realistic:

```text
Safe requests withdrawal of old liquidRESERVE
→ pending request records old token
→ legitimate batchRedeem burns Safe’s complete old-token balance
→ Safe receives the new token
→ pending old-token amount > old-token balance
→ processWithdrawal reverts
```

This is not a rebasing issue. It is a token-migration/pending-request desynchronization lead. Owners can still cancel the pending withdrawal, so its impact currently appears limited unless we establish that cancellation is unavailable or another operation depends critically on the stuck request.