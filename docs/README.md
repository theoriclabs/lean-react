# LeanApp documentation

[LeanApp](../README.md) · [Live café](https://proof-and-pour-production.up.railway.app) · [Private Notes](https://private-notes-production.up.railway.app) · [Release evidence](RELEASE.md)

Start with the task you want to do. The café runs a shared Lean domain model on a native server and in the browser; LeanReact is the optional library for writing the React components themselves in Lean.

| Your goal | Start here |
| --- | --- |
| Run the full-stack café and change a rule | [Getting started](GETTING_STARTED.md) |
| Understand what Lean buys you | [Domain modeling](DOMAIN_MODELING.md) |
| Try proof-carrying authorization and rejected agent patches | [Private Notes guide](PRIVATE_NOTES.md), then the [original demonstration](AUTHORIZATION_DEMO.md) and [implementation design](AUTHORIZATION_DESIGN.md) |
| Understand the libraries and request boundaries | [Architecture](ARCHITECTURE.md) |
| Write React components in Lean | [LeanReact overview](LEANREACT.md), then the [first-form tutorial](HOW_TO.md#build-your-first-form) |
| Add signup and cookie sessions | [Authentication](AUTH.md) |
| Host the café with persistent SQLite | [Hosting](HOSTING.md) |
| Change the framework or run its checks | [Contributing](../CONTRIBUTING.md) |

## API and implementation references

| Area | Reference |
| --- | --- |
| Application assembly and capabilities | [Interface contract](FULLSTACK_INTERFACES.md), [binding source](../engine/LeanApp/Binding.lean), [executable assembly fixture](../tests/app/Main.lean) |
| Identity, validation and codecs | [LeanOntology API](../engine/LeanOntology/API.md) |
| Typed operations and transport | [LeanContract operations](../engine/LeanContract/Operation.lean), [HTTP protocol](../engine/LeanContract/Http.lean) |
| React authoring | [LeanReact API](../engine/LeanReact/API.md), [composition guide](COMPOSABILITY.md) |
| Generated JavaScript representations | [LeanJS ABI](../engine/LeanJS/ABI.md) |
| Reusable implementation and example locations | [Engine map](../engine/README.md), [examples map](../examples/README.md) |
| Native Tickets compatibility example | [Tickets adapter](NATIVE.md) |

The Tickets server is an unauthenticated local fixture. Use the café's auth/hosting guides for the publicly hosted application; the two examples have different trust boundaries.

## Status and design history

[Implementation status](LEANAPP_STATUS.md) is the current framework coverage report. [Release evidence](RELEASE.md) records the hosted image, tests and known limits. [Frontend implementation](IMPLEMENTED.md) covers LeanReact and its compiler/runtime integrations, not the whole framework.

The [full-stack vision](../FULLSTACK_VISION.md) and [full-stack implementation plan](../FULLSTACK_IMPLEMENTATION_PLAN.md) describe the broader destination, including work that is not implemented. The earlier [LeanReact vision](../VISION.md) and [frontend plan](../IMPLEMENTATION_PLAN.md) remain useful design history. [Frontend readiness](FRONTEND_READINESS.md) and [qualification](QUALIFICATION.md) are dated reviews; their historical observations are not new promises.

This repository is now the LeanApp monorepo. Its GitHub URL and the compatible Lake package name remain `lean-react` and `leanreact`, respectively. Public product naming does not change module imports or the exact wire identities of existing applications. [Architecture](ARCHITECTURE.md#names-and-compatibility) records that decision.
