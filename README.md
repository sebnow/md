# md

A command-line utility for working with Markdown files.
Designed for composability with other Unix tools,
and particularly useful for LLM agents
that need to read and manipulate Markdown.

`md` parses Markdown leniently,
preferring best-effort results over strict errors.

## Features

### Frontmatter

Read and write YAML frontmatter.
Output as JSON for use with `jq`.

```sh
# Extract frontmatter as JSON
md frontmatter notes.md | jq '.tags'

# Set a frontmatter field
md frontmatter set notes.md title "My Note"

# Delete a frontmatter field
md frontmatter delete notes.md draft
```

### Body

Output the document body without frontmatter.

```sh
md body notes.md
```

### Links

List outgoing links from a file.
Supports standard Markdown links, Obsidian `[[wikilinks]]`,
and embeds (`![]()`, `![[]]`).

```sh
# List outgoing links
md links notes.md

# List incoming links (scans directory for files linking to target)
md links --incoming notes.md
md links --incoming notes.md --dir ./vault/
```

### Headings

List headings with their depth and line numbers.

```sh
md headings notes.md
md headings --json notes.md | jq '.[] | select(.depth == 2)'
```

### Sections

Extract the content under a specific heading.

```sh
md section "## API" notes.md
```

### Tags

Extract tags from frontmatter and inline `#tags`.

```sh
md tags notes.md
```

### Code Blocks

List fenced code blocks with language and line ranges.

```sh
md codeblocks notes.md
md codeblocks --json notes.md | jq '.[] | select(.language == "go")'
```

### Stats

Word count, line count, and other basic statistics.

```sh
md stats notes.md
```

## Supported Formats

- Standard Markdown links: `[text](url)`
- Obsidian wikilinks: `[[target]]`, `[[target|alias]]`
- Image/embed links: `![alt](url)`, `![[embed]]`
- YAML frontmatter (delimited by `---`)
- ATX headings (`# H1` through `###### H6`)
- Fenced code blocks (backtick and tilde)
- Inline tags (`#tag`)

## Design

- **Lax parsing** — best-effort, never fails on malformed input.
- **Unix philosophy** — single-purpose commands,
  composable with pipes and other tools.
- **Stdin support** — reads from stdin when no file argument is given.
- **Plain text default** — human-readable output by default,
  `--json` for structured output.

## Building

Requires Zig 0.15.2.

```sh
zig build
```

## Development

A Nix flake provides a development shell:

```sh
nix develop
```

## License

TODO
