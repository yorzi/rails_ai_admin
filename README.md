# Rails AI Admin

A self-hosted Rails admin engine with an explicit resource registry and a shared,
authorized operation boundary for conventional pages and future AI interfaces.

**Status: unreleased development.** The development plan describes the target
product, not the currently supported feature set. See [ROADMAP.md](ROADMAP.md)
for implementation status and [COMPATIBILITY.md](COMPATIBILITY.md) for evidence.

The host owns authentication, authorization, tenants and domain data. Access is
denied until a host supplies both context and policy adapters. No provider call,
public deployment or gem publication is part of local development.

Licensed under [MIT](LICENSE). The implementation is original; dependencies keep
their own licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
