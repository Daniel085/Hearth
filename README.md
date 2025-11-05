# 🏠 Hearth

> A thoughtful iOS companion for nurturing meaningful relationships

## Overview

Hearth is a privacy-first iOS application designed to help you maintain and strengthen relationships with the people who matter most. Inspired by the attentive personal assistants of the 1950s, Hearth provides gentle, contextual reminders to stay connected—without the noise and overwhelm of modern social media.

## The Vision

In an age of constant notifications and social media pressure, Hearth takes a different approach:

- **Intentional, not reactive**: You come to Hearth to launch your communications, rather than being interrupted by notifications
- **Privacy-first**: All data processing happens on-device using Core ML. No cloud infrastructure, no data collection
- **Relationship-focused**: Uses photo metadata, location patterns, and calendar data to understand your meaningful connections
- **Thoughtfully proactive**: Gentle reminders delivered with the warmth and consideration of a personal assistant

## Key Features

### Initial Setup
- **Photo Intelligence**: Analyzes your photo library using iOS Vision framework to identify people you spend time with
- **Place Recognition**: Identifies your favorite locations and establishes visit patterns
- **Pattern Learning**: Uses Core ML to understand your communication rhythms and relationship habits

### The Launchpad
- **Contextual Cards**: See who needs attention and why (time since last contact, upcoming birthdays, established patterns)
- **Smart Reminders**: "Sarah's birthday is Thursday—perhaps send flowers?"
- **Location Awareness**: "You haven't visited Joe's Coffee in 3 months—you're nearby now"
- **Direct Actions**: Launch calls, texts, emails, or calendar invites directly from Hearth

### Privacy & Intelligence
- All processing happens on-device using Core ML
- No external servers or cloud infrastructure
- Full control over permissions and data usage
- Optional iCloud sync for multi-device (data remains encrypted and private)

## Technology Stack

- **Language**: Swift
- **UI Framework**: SwiftUI
- **Core Frameworks**:
  - Vision (face detection and clustering)
  - Core ML (pattern recognition and predictions)
  - Core Data (local storage)
  - PhotoKit (photo library access)
  - EventKit (calendar integration)
  - Core Location (place tracking)
  - BackgroundTasks (silent data processing)

## Design Philosophy

Hearth embodies the ethos of a 1950s personal assistant:
- Thoughtful and proactive, never intrusive
- Focused on human connection, not metrics
- Respectful of your time and attention
- Private and trustworthy

## Current Status

🎨 **Concept Phase** - Storyboards and initial design complete

[View Interactive Storyboards](./docs/storyboards.html)

## Roadmap

- [ ] Core data model design
- [ ] Photo analysis prototype (Vision framework)
- [ ] Pattern learning system (Core ML)
- [ ] SwiftUI interface implementation
- [ ] Background processing setup
- [ ] Beta testing with real users
- [ ] App Store submission

## Contributing

This project is in early conceptual stages. If you're interested in contributing or have ideas to share, feel free to open an issue or reach out!

## License

To be determined

---

**Note**: Hearth is a concept application currently in the design phase. The storyboards represent the intended user experience and feature set.
