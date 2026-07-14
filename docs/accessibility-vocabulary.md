# Accessibility vocabulary audit

This recorder separates finite accessibility structure from unbounded app content.

The installed macOS SDK exposes 58 AX roles and 37 AX subroles in `AXRoleConstants.h`. AppKit exposes 61 role names and 33 subrole names, including web-facing forms such as link, web area, page, and list marker. These role and subrole identifiers are finite for a given SDK. Titles, descriptions, help text, values, identifiers, URLs, and custom role descriptions are supplied by applications and websites and are not finite vocabularies.

The checked-in Computer Use parser combines the SDK role sets, localized native role descriptions such as `text entry area`, and serializer-specific web phrases. It uses longest-first role parsing, accepts raw canonical forms such as `AXListMarker`, retains qualifiers such as `selected`, `disabled`, and `settable`, and parses Description, Value, Help, ID, URL, and Secondary Actions independently. Every element also retains its complete `rawDescriptor`. Unknown roles remain matchable by identity fields instead of being assigned a guessed native role.

The audit also reports qualifier counts and `rolePrefixCollisions`: descriptors where a recognized short role is followed by more words before a serializer state qualifier. This catches silent vocabulary gaps such as parsing `text entry area (settable, string)` as the shorter `text` role.

On July 13, 2026, `npm run audit:accessibility` scanned the local Codex session corpus and found:

- 44 tasks containing usable Computer Use state output;
- 577 full or diff accessibility snapshots;
- 113,068 serialized elements;
- 57 observed recognized role phrases;
- 4,975 title-only or otherwise untyped entries (4.4%).

The remaining untyped entries were predominantly application menu titles such as File, Edit, View, and Help. They do not contain an explicit role token in Computer Use's text format. The parser preserves the entire entry as its label and raw descriptor rather than fabricating a role.

Recorder-side native snapshots batch-read role, subrole, localized role description, title, description, help, value, value description, identifier, DOM identifier, URL, placeholder value, and enabled/focused/selected state. Geometry comes from native position and size. This gives the resolver several independent identity fields without depending on element indices matching between Computer Use and native AX traversal.

The audit command is read-only:

```sh
npm run audit:accessibility
```

It reports aggregate role counts and truncated unknown prefixes. It does not modify Codex sessions.
