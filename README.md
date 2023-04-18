![wizardex](header.png)

<h1 align="center">WizarDex</h1>

<div align="center">

![Solidity](https://img.shields.io/badge/Solidity-0.8.17-e6e6e6?style=for-the-badge&logo=solidity&logoColor=black)
![NodeJS](https://img.shields.io/badge/Node.js-16.x-339933?style=for-the-badge&logo=nodedotjs&logoColor=white)

[![Discord](https://img.shields.io/badge/Discord-7289DA?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/tEaGBcGdQC)
[![Twitter](https://img.shields.io/badge/Twitter-1DA1F2?style=for-the-badge&logo=twitter&logoColor=white)](https://twitter.com/ithil_protocol)
[![Website](https://img.shields.io/badge/Website-E34F26?style=for-the-badge&logo=Google-chrome&logoColor=white)](https://ithil.fi/)
[![Docs](https://img.shields.io/badge/Docs-7B36ED?style=for-the-badge&logo=gitbook&logoColor=white)](https://docs.ithil.fi/)

</div>

> A fully on-chain fee-less orderbook model dex by Ithil.

This repository contains the core smart contracts for WizarDex V1.

## Key Features

- Market and limit orders on any ERC20 token pair
- Zero slippage
- No fees
- Internal MEV to boost order execution priority
- No off-chain parts

## Installation

Prerequisites for this project are:

- Git
- NodeJS v16.x
- Rust
- Yarn

To get a copy of the source

```bash
git clone https://github.com/Ithil-protocol/wizardex
cd v1-core
forge install
```

## Usage

Create an environment file `.env` copying the template environment file

```bash
cp .env.example .env
```

and add the following content:

```text
ARBITRUM_RPC_URL="https://..." needed to run arbitrum fork tests
```

Load it in your local env with `source .env` and finally you can compile the contracts:

```bash
forge build
```

## Test

```bash
forge test
```

and to view in details the specific transactions happening

```bash
forge test -vvvv
```

## Security

This code, despite heavily documented and tested, has not been audited.

## Licensing

The main license for the Ithil contracts is the Business Source License 1.1 (BUSL-1.1), see LICENSE file to learn more.
The Solidity files licensed under the BUSL-1.1 have appropriate SPDX headers.

## Disclamer

This application is provided "as is" and "with all faults." Me as developer makes no representations or warranties of
any kind concerning the safety, suitability, lack of viruses, inaccuracies, typographical errors, or other harmful
components of this software. There are inherent dangers in the use of any software, and you are solely responsible for
determining whether this software product is compatible with your equipment and other software installed on your
equipment. You are also solely responsible for the protection of your equipment and backup of your data, and THE
PROVIDER will not be liable for any damages you may suffer in connection with using, modifying, or distributing this
software product.
