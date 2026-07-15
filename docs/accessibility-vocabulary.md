# Accessibility vocabulary

This recorder separates finite accessibility structure from unbounded app content.

macOS and AppKit expose a finite set of AX roles and subroles, including web-facing forms such as link, web area, page, and list marker. Titles, descriptions, help text, values, identifiers, URLs, and custom role descriptions are supplied by applications and websites and are not finite vocabularies.

The checked-in Computer Use parser combines the SDK role sets, localized native role descriptions such as `text entry area`, and serializer-specific web phrases. It uses longest-first role parsing, accepts raw canonical forms such as `AXListMarker`, retains qualifiers such as `selected`, `disabled`, and `settable`, and parses Description, Value, Help, ID, URL, and Secondary Actions independently. Every element also retains its complete `rawDescriptor`. Unknown roles remain matchable by identity fields instead of being assigned a guessed native role.

The audit also reports qualifier counts and `rolePrefixCollisions`: descriptors where a recognized short role is followed by more words before a serializer state qualifier. This catches silent vocabulary gaps such as parsing `text entry area (settable, string)` as the shorter `text` role.

Entries such as application menu titles may not contain an explicit role token in Computer Use's text format. The parser preserves the entire entry as its label and raw descriptor rather than fabricating a role.

Recorder-side native snapshots batch-read role, subrole, localized role description, title, description, help, value, value description, identifier, DOM identifier, URL, placeholder value, and enabled/focused/selected state. Geometry comes from native position and size. This gives the resolver several independent identity fields without depending on element indices matching between Computer Use and native AX traversal.

The audit command is read-only:

```sh
npm run audit:accessibility
```

It reports aggregate role counts and truncated unknown prefixes. It does not modify or copy Codex sessions, and its output is local-only.
