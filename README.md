# Security Research and Audits


This repository contains my security research work acros different types of codebases.
For the moment there are multiple smart contracts findings and a clear explanaiton of 
my vulnerability research process only for this type of projects. The methodology used 
for my other code reviews is mainly the same. 

I am particularly interested in complex vulnerabilities, this is one of the reason I 
started to hunt for vulnerabilities in projects with a higher complexity making a transition
from blockchain protocols to regular system software (not a one way transition, I am still going
to hunt for bugs in smart contracts too). This transition was made easy due to AI
which helps me understand the codebases and new arhitectures easily. 

Most of my work is code review and exploit development. In my next months I am planning 
to start a vulnerability research targeting a proprietary software using binary analysis tools
such as ghidra, gdb. I will also use my own tool for visualizing memory. This tool was created
entirely with AI based on the features I want and it still needs a lot of improvements.

Over the coming months, I will gradually publish my Libreswan findings.


## Research Areas

| Area | Description |
| --- | --- |
| [Smart contracts](audits-smart_contracts/README.md) | Audit-contest findings and independent research covering DeFi protocols, accounting, authorization, bridges, oracles, and protocol invariants. |
| [Other codebases](audits-other_codebases/README.md) | Research into infrastructure and systems software, including C/C++ codebases such as Libreswan. |

## Repository Layout

```text
audits-smart_contracts/
    README.md                 Smart-contract research overview and results
    findings/                 Public findings and contest reports
    etherfi/                  EtherFi research, notes, scripts, and PoCs
    etherfi-cash/             EtherFi Cash research and reproductions
    metric/                   Metric research, findings, and tests

audits-other_codebases/
    README.md                 Systems-research overview
    libreswan/                Public Libreswan vulnerability reports
```

## Research Approach

My workflow generally consists of:

1. mapping architecture, entry points, and trust boundaries;
2. tracing interactions between flows that share state;
3. extracting assumptions and security invariants from the implementation;
4. developing concrete attack hypotheses;
5. testing reachability with targeted scripts, fuzzing, invariant tests, or
   isolated reproducer environments;
6. evaluating realistic impact, preconditions, and possible mitigations.

Early notes and candidate findings may be incomplete, speculative, or written
partly in Romanian. Final reports should be read together with their stated
preconditions, threat model, and impact analysis.

## Disclosure and AI Use

Potential vulnerabilities in actively maintained software are reported to the
relevant maintainers before publication. Reports are published after the issue
and its remediation are public or disclosure has otherwise been authorized.

AI-assisted tools are used for tasks such as code navigation, call-flow
analysis, hypothesis generation, test-environment work, and drafting.
