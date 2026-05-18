# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.14.1] - 2026-05-15

### Added
- Initial public release of bot_army_runtime
- NATS connection management with automatic reconnection
- Service registry for bot discovery
- Telemetry integration for observability
- Ecto persistence patterns
- Comprehensive documentation and examples

### Fixed
- NATS connection stability under high load

### Changed
- Refined module organization for public API clarity

## [0.14.0] - 2026-05-10

### Added
- Health check telemetry events
- Registry query endpoints

### Fixed
- Connection pool exhaustion under concurrent load
