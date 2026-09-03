# Security Research Work

This repository contains my work in security research. Most of the audits and findings come from audit contests, although I also include independent research and other security-related work.

I especially enjoy discovering complex technical and logic vulnerabilities rather than simple pattern-based issues.

Most of my work so far has focused on Web3 protocols, but I am also interested in infrastructure-level and systems security. I plan to expand this repository with research on software written in Go, Rust, and C/C++, including areas such as virtualization, browsers, kernels, binary exploitation, and other low-level systems.

One of the projects included here is research on [an older version of the Sei protocol](findings/old-sei-findings.md). I originally encountered the codebase during an interview and later investigated it independently. It was my first time auditing a Go codebase at the infrastructure level, and the experience made me much more interested in this type of security research.

I may also include my Unikraft integration work for Cloud Hypervisor. Although it was not an audit, it involved interesting systems-level research and debugging.

> **Note:** Some findings in this repository may be labeled internally as **"High Valid"**. These labels reflect technical severity only. A finding may still be out of scope for a bug bounty, depend on privileged configuration, rely on assumptions outside the protocol's intended threat model, or otherwise not qualify as a valid submission. I only publish findings that do not represent an active risk under the protocol's documented trust and security assumptions.

## Contents

- [Selected research](#selected-research)
- [Research methodology and AI use](#research-methodology-and-ai-use)
- [Finding evaluation and submission strategy](#finding-evaluation-and-submission-strategy)
- [Tools](#tools)
- [AI in vulnerability research](#ai-in-vulnerability-research)
- [Planned research](#planned-research)

---

## Selected Research

### Ostium Bug Bounty — Disclosure Pending

**Resolution:** Not going to fix.

I am currently waiting for approval before publicly disclosing this finding. Technical details will be added only if and when disclosure is authorized.

### EtherFi and EtherFi Cash

The [EtherFi](audits/etherfi/) and [EtherFi Cash](audits/etherfi-cash/) research contains tests, leads, vulnerability hypotheses, and findings that are technically valid but may not qualify as accepted bug bounty submissions because they depend on conditions that could be interpreted as design choices, user mistakes, privileged configuration, or limited reachability.

#### Research Areas Retained

- CashModule, Aave v4, liquidation, pending-withdrawal, and migration accounting
  interactions, including invariant and fork-test work.
- Asynchronous bridge and module-lifecycle hazards whose practical relevance depends
  on privileged configuration and the protocol's operational trust assumptions.
- Scroll oracle/accountant integration behavior, including paused and stale-rate
  handling, documented with its reachability and threat-model limitations.
- Signature and recovery authorization reviews, together with independent
  reproductions of behavior already documented in previous assessments.

These materials are retained as public security research rather than presented as
unconditional, bounty-valid findings. Each report should be read together with its
stated invalidation risks, trust assumptions, and final assessment.

---

## Research Methodology and AI Use

The EtherFi research provides a transparent view of my workflow. I generally divide the process into six stages.

### 1. Scoping and Architecture Mapping

I begin by scoping the protocol, summarizing its purpose and entry points, and identifying the areas of code most likely to contain vulnerabilities.

AI helps with the initial mapping and prioritization, but its output is only a starting point.

### 2. Mapping Interactions Between Flows

I identify flows that interact by modifying shared state or relying on data exposed across contracts.

At this stage, I also ask AI to propose possible attack vectors, which I treat as hypotheses rather than conclusions.

### 3. Reading the Code and Extracting Invariants

I then read the code myself. I may prioritize flows with potentially interesting interactions, but I usually review the entire codebase at a high level first to understand where everything fits.

Although an AI-generated summary is often useful, reading the implementation gives me significantly more context.

During this stage, I take notes on interesting properties, assumptions, and individual lines of code that may imply invariants. AI sometimes helps explain unfamiliar mechanisms, but I independently evaluate the resulting leads.

Most early leads are stored in `idei.md`. Many are written in Romanian, so readers may need to translate them.

### 4. Developing Attack Hypotheses

I investigate the most interesting flows more deeply, turning observations into concrete hypotheses and questions about potential attack paths.

In the notes, a general lead such as `2` may branch into related hypotheses numbered `2.1`, `2.2`, and so on.

### 5. Testing Reachability

Once I have a vulnerability hypothesis or suspected invariant, I test whether the relevant state is reachable.

This may involve unit tests, fuzzing, invariant testing, fork tests, or targeted scripts.

The EtherFi Cash research contains an example where I identified an interesting invariant and used AI to help build a fuzzing harness. The harness found several flows that violated that invariant.

AI assists with implementing and expanding the tests, while I define the property being tested and evaluate whether each counterexample represents realistic protocol behavior.

If the suspected trigger is reachable, I proceed to impact analysis.

### 6. Assessing Impact and Practical Relevance

After proving reachability, I evaluate the maximum realistic impact.

I frequently analyze on-chain transactions to determine whether the required conditions or timing windows have occurred in production and how much capital may have been exposed.

This step is important because a theoretically reachable state may still have low practical relevance. On-chain evidence can establish that the required timing window, configuration, or user behavior has occurred before, rather than merely being possible in an abstract model.

Most candidate findings do not survive this stage. I filter them by considering questions such as:

- How likely is the condition to occur?
- How much capital could be affected?
- If funds are frozen, is recovery possible, who can perform it, and how long could it take?
- Can an administrator recover the system through normal protocol operations?
- Would the required configuration change reasonably be classified as an administrator mistake?
- Is the impact covered by the bug bounty's scope and rules?
- Does exploitation require a privileged actor to behave maliciously?
- Does the path depend on a user mistake?

At this point, vulnerability research often becomes as much about policy and interpretation as technical correctness, which is the part of the process I enjoy least.

---

## Finding Evaluation and Submission Strategy

A recurring lesson from vulnerability research is that I sometimes filter findings too aggressively before submission.

In the past, this resulted in findings that I chose not to submit in audit contests even though they would later have ranked among the strongest issues in those contests.

Two examples are Revert Finance on Cantina and Fluid DEX v2, where the findings I had identified corresponded to the #1 finding in each contest and would have placed me in the top 3.

I do not think these issues were necessarily difficult to discover. The harder part was judging whether the behavior was actually considered unintended, especially when you cannot communicate with the protocol team to clarify what their intention is.

I am sure that other researchers may also have found some of these issues but decided not to submit them for similar reasons.

This changed how I approach findings. I now try to evaluate technical validity, reachability, practical impact, and submission-policy interpretation separately instead of treating them as a single decision.

---

## Tools

- AI-assisted analysis
- Echidna fuzzing
- Foundry fuzzing and invariant testing
- Slither
- Python tooling

I also built some tools in Python to find where functions are called more quickly. They are faster than Slither for this specific purpose, although not as accurate. For exploratory research, they are usually good enough.

I recently discovered OpenKritt, which seems like an interesting tool for building agent workflows.

I have not used it to its full potential yet, mainly because it consumes a lot of tokens, but I may be able to improve the performance/cost trade-off with a better understanding of how to structure the workflows.

---

## AI in Vulnerability Research

I am still not sure exactly where AI will take vulnerability research.

Sometimes I feel like AI could reduce a large part of vulnerability research to a triaging stage. At other times, its limitations are very obvious.

What is clear is that, with enough guidance, it can do some tasks extremely well. Even with that guidance, however, it is not 100% reliable.

I experienced this during the Metric contest.

I specifically asked AI to check for rounding issues in a pool such as BTC/USDC interacting with a particular extension because I already suspected that the difference in token decimals could cause problems.

It did not find anything.

I then trusted the AI too much and assumed it had checked the path thoroughly. As a result, I did not investigate that path deeply enough myself and missed vulnerability `#3048`.

That experience made me think more carefully about how much I should trust AI during security research.

A potential future problem in security may be researchers blindly trusting AI when it reports that a path is safe and therefore not manually checking the same path, while attackers may still investigate it manually and in greater depth.

---

## Planned Research

I plan to research new types of protocols and systems outside Web3.

I really enjoy binary analysis and the complex world of traditional software exploitation, including techniques such as ROP and FSOP.
