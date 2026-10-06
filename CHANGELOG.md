# Changelog

All notable changes to Moonlet are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added

- Menu bar app that shows agent news at your pointer only when an agent finishes, fails, or needs you.
- Attention rules: waits for typing pauses, adapts how long cards stay to your presence, summarizes what happened while you were away or on a call, and reminds you of blocked agents at 2, 10, and 30 minutes.
- Pointer skin: Moonlet's pointer only while an agent talks to you (blue tells, yellow asks, red warns); the standard arrow otherwise, including while agents work.
- Summon view with a small circle gesture or <kbd>⌃⌥M</kbd>, and click-to-open for Terminal and iTerm tabs.
- Few-word summaries from a local Ollama model, with question detection.
- Stuck-agent detection and learning which projects you always skip.
- Claude Code hooks and Codex `notify` integrations, the `moonlet` command, and wire protocol v1.
- **Preview the pointer (20 seconds)** in the menu, to see the Moonlet pointer and check clicks without waiting for an agent.
- Cards for blocked agents say what the agent wants (`Wants to run npm install`) or show its question with the options, and stay 8 seconds.

### Fixed

- The pointer skin could swallow clicks and scrolls: its window sat at the cursor level, above the screen-shield band. It now uses the accessibility overlay level, and turns itself off if input ever stops reaching your apps.
- The pointer's hotspot now sits at the arrow's visible tip.
