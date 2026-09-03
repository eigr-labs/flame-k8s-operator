# Changelog

All notable changes to this project will be documented in this file.

The format is inspired by Keep a Changelog, and this project follows Semantic Versioning.

## [0.1.0] - 2026-09-03

### Added

- Initial public release of the Kubernetes backend integration for FLAME.
- `FLAME.K8sBackend` implementation backed by `FlameRunner` and `FlamePool` CRDs.
- `mix flame.gen.deployment` task to scaffold FLAME-ready Kubernetes deployment manifests.
- Documentation for backend setup and deployment generation.
