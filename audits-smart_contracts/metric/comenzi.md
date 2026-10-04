cd /workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/metric-core

FOUNDRY_OFFLINE=true echidna test/MetricOmmPool.echidna.t.sol \
  --contract MetricOmmPoolEchidna \
  --config echidna-metric-omm-pool-rounding.yaml \
  --corpus-dir echidna-corpus/metric-omm-pool-rounding \
  --format text \
2>&1 \
| perl -ne '
    BEGIN { $| = 1; $next = 50000; }
    if (/\[status\]/) {
      if (/fuzzing:\s+([0-9]+)\// && $1 >= $next) {
        print;
        $next += 50000 while $1 >= $next;
      }
      next;
    }
    print;
  ' \
| tee echidna-metric-omm-pool-rounding.filtered.log

cd /workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/metric-core

FOUNDRY_OFFLINE=true echidna test/MetricOmmPoolMultiActor.echidna.t.sol \
  --contract MetricOmmPoolMultiActorEchidna \
  --config echidna-metric-omm-pool-multi-actor.yaml \
  --test-limit 500000 \
  --seed 21734 \
  --seq-len 150 \
  --corpus-dir echidna-corpus/metric-omm-pool-multi-actor \
  --format text \
2>&1 \
| perl -ne '
    BEGIN { $| = 1; $next = 50000; }
    if (/\[status\]/) {
      if (/fuzzing:\s+([0-9]+)\// && $1 >= $next) {
        print;
        $next += 50000 while $1 >= $next;
      }
      next;
    }
    print;
  ' \
| tee echidna-metric-omm-pool-multi-actor.filtered.log


cd /workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/metric-core

FOUNDRY_OFFLINE=true forge test \
  --match-path test/removeliquidity-fuzzing.t.sol \
  --match-contract MetricOmmPoolRemoveLiquidityFuzzTest \
  --fuzz-runs 500000 \
  --fuzz-seed 21734 \
  -vvv \
2>&1 | tee removeliquidity-fuzzing.log



set -o pipefail

FOUNDRY_OFFLINE=true echidna test/MetricOmmPool.echidna.t.sol \
  --contract MetricOmmPoolEchidna \
  --config echidna-metric-omm-pool-rounding.yaml \
  --corpus-dir echidna-corpus/metric-omm-pool-rounding \
  --test-limit 500000 \
  --seed 21734 \
  --seq-len 150 \
  --format text \
2>&1 \
| perl -ne '
    BEGIN { $| = 1; $next = 50000; }
    if (/\[status\]/) {
      if (/fuzzing:\s+([0-9]+)\// && $1 >= $next) {
        print;
        $next += 50000 while $1 >= $next;
      }
      next;
    }
    print;
  ' \
| tee echidna-metric-omm-pool-swap-traversal-stuff.filtered.log