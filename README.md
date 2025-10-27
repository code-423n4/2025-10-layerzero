# LayerZero audit details
- Total Prize Pool: $100,000 in USDC 
    - HM awards: up to $92,640 in USDC 
        - If no valid Highs or Mediums are found, the HM pool is $0 
    - QA awards: $3,860 in USDC
    - Judge awards: $3,000 in USDC
    - Scout awards: $500 USDC
- [Read our guidelines for more details](https://docs.code4rena.com/competitions)
- Starts October 24, 2025 20:00 UTC
- Ends November 7, 2025 20:00 UTC

### ❗ Important notes for wardens
1. Judging phase risk adjustments (upgrades/downgrades):
    - High- or Medium-risk submissions downgraded by the judge to Low-risk (QA) will be ineligible for awards.
    - Upgrading a Low-risk finding from a QA report to a Medium- or High-risk finding is not supported.
    - As such, wardens are encouraged to select the appropriate risk level carefully during the submission phase.

## Publicly known issues

_Anything included in this section is considered a publicly known issue and is therefore ineligible for awards._

### Out-of-Scope Dependencies

The Alexandria lib and the starknet core lib are presently undergoing an audit and should be considered out-of-scope. The contacts in scope for this competition reference these 2 libraries but any findings that pertain to them are not eligible for a reward.

### Bytes Array Keccak Bug

The malformed byte array issue is already discovered and will not count as a valid finding. The issue specifically relates to the case where two different Byte Arrays result in the same keccak hash if one of them is malformed.

# Overview

The LayerZero V2-Starknet implementation maintains the same core architecture and functionality as LayerZero V2-EVM while adapting to Starknet's unique features and constraints. The protocol preserves LayerZero's core values of permissionlessness, immutability and censorship-resistance.

Starknet supports dynamic inter-contract calls via dispatcher interfaces, allowing LayerZero V2 to maintain its modular, runtime-configurable architecture. By using Dynamic Dispatchers we can allow pluggable message libs, independent workers and minimal protocol surface without needing complex workarounds or fundamental architectural changes.

The Starknet LayerZero implementation is architecturally very close to the EVM implementation, maintaining the same three-step messaging flow:

1. **Send**: OApp calls EndpointV2 with message parameters
2. **Verify**: DVNs verify messages and submit their validation to the message lib
3. **Commit**: Via a permissionless call, the message library asserts commitment requirements and commits payload hash to the endpoint
4. **Execute**: Via a permissionless call, the EndpointV2 delivers verified message to receiver

## Links

- **Previous audits:**  N/A
- **Documentation:** https://github.com/code-423n4/2025-10-layerzero/blob/main/layerzero/README.md
- **Website:** [LayerZero.network](https://layerzero.network/)
- **X/Twitter:** [@layerzero_core](https://x.com/layerzero_core)

---

# Scope

As mentioned previously, findings pertaining to the Alexandria and Starknet core libraries are out-of-scope due to them presently undergoing an audit.

### Files in scope

The following file-paths and all files within them are in-scope:

| Path |
| -- |
| [layerzero/src/endpoint/\*\*.\*\*](https://github.com/code-423n4/2025-10-layerzero/tree/main/layerzero/src/endpoint) |
| [layerzero/src/message_lib/uln_302/\*\*.\*\*](https://github.com/code-423n4/2025-10-layerzero/tree/main/layerzero/src/message_lib/uln_302) |
| [layerzero/src/workers/dvn/\*\*.\*\*](https://github.com/code-423n4/2025-10-layerzero/tree/main/layerzero/src/workers/dvn) |
| [libs/multisig/src/\*\*.\*\*](https://github.com/code-423n4/2025-10-layerzero/tree/main/libs/multisig/src) |
| [libs/enumerable_set/src/\*\*.\*\*](https://github.com/code-423n4/2025-10-layerzero/tree/main/libs/enumerable_set/src) |

### Files out of scope

Any file-path not explicitly listed as in scope in the above list should be considered out-of-scope.

# Additional context

## Areas of concern (where to focus for bugs)

- Security issues on DVN / ULN interaction
- Starknet specific problems on handling Storage; is there a way to grief the Endpoint or ULN which will be immutable?
- Censorship resistance; is there a way on the native payment path LayerZero can use its permissions to censor user messages? this should not be possible under proper configurations
- Starknet specific behaviour

## Main invariants

- Endpoint owner should not be able to censor messages
- Endpoint is immutable
- Only delegate or OApp can set configs for OApp
- ULN is immutable
- ULN owner should not be able to censor messages through native path
- DVN is secured through its multisig
- DVN cannot suffer a replay attack
- Only Admin can execute arbitrary signed payloads through DVN
- DVN can permissionless grant Admin through signed payload

## All trusted roles in the protocol

| Role                                | Description                       |
| --------------------------------------- | ---------------------------- |
| Endpoint Owner (Controlled by LayerZero) | - Registers libraries<br>- Defines default send/receive libraries and their timeouts |
| Endpoint Delegate (Controlled by OApp Owner) | - Manages OApp configurations (send/receive configs, libraries, timeouts)<br>- Clears and processes messages on the endpoint<br>- Can skip, nullify, or burn messages |
| DVN Admin (Controlled by DVN multisig / Admin) | - Grants roles<br>- Executes operations<br>- Sets destination config, price feed, supported options, and fees |
| DVN Signer (Controlled by DVN multisig) | - Signs calldata to be executed on the DVN<br>- A group of signers can collectively change the admin permissionlessly |
| Message Lib (Controlled by DVN multisig) | - Can assign jobs |
| UltraLightNode Owner | - Sets configs for UltraLightNode<br>- Defines send/receive and executor configs<br>- Sets treasury native fee cap |
| ULN Endpoint | - Can call send |
| Treasury Owner (Controlled by LayerZero)                             | - Sets fee basis points<br>- Withdraws tokens<br>-Sets LayerZero token fee library                       |

## Running tests

### Prerequisites

The codebase represents a Starknet contract system that requires the `scarb` toolkit to be compiled as well as several other tools defined in the project's `.tool-versions` file.

All these tools can be installed through [the `asdf` package manager](https://asdf-vm.com/guide/getting-started.html), and this is the recommended way to go. 

### Installing Dependencies

We need to add the project's dependencies as plugins to `asdf` and install them:

```bash
asdf plugin add cairo-profiler
asdf plugin add starknet-devnet
asdf plugin add scarb
asdf plugin add starkli
asdf plugin add starknet-foundry
asdf install
```

Please make sure the relevant installations are available in your `$PATH` by adding the `$HOME/.asdf/shims` folder to it.

After the OS-specific dependencies have been installed, we need to change our working directory to the `layerzero` folder and fetch the relevant files through `scarb`:

```bash
scarb fetch
```

### Building Codebase

The codebase can be built through the `build` command of the `scarb` CLI tool:

```bash
scarb build
```

### Running Tests

The `test` command can be issued to the `scarb` CLI to run tests:

```bash
scarb test
```

## Miscellaneous

Employees of LayerZero and employees' family members are ineligible to participate in this audit.

Code4rena's rules cannot be overridden by the contents of this README. In case of doubt, please check with C4 staff.
