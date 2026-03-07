# md

A command-line tool for querying and transforming Markdown files
using a jq-inspired DSL.
Designed for composability with other Unix tools,
and useful for LLM agents
that need to read and manipulate Markdown.

`md` parses Markdown leniently,
preferring best-effort results over strict errors.

## Usage

```
md '<program>' [options] [file]
```

If no file is given, reads from stdin.

### Options

- `--json` — output in JSON format
- `--dir <path>` — directory for `incoming`/`exists`/`resolve`
- `-i` — edit file in-place (for mutations)

## Extractors

Extractors pull structured data from the document.

```sh
# YAML frontmatter as a record
md 'frontmatter' notes.md

# Document body without frontmatter
md 'body' notes.md

# Headings with depth and line number
md 'headings' notes.md

# Links (standard, wikilink, image, embed)
md 'links' notes.md

# Inline tags
md 'tags' notes.md

# Fenced and indented code blocks
md 'codeblocks' notes.md

# Word and line counts
md 'stats' notes.md

# HTML and Obsidian comments
md 'comments' notes.md

# Footnote definitions
md 'footnotes' notes.md

# Files linking to this one (scans directory)
md 'incoming' --dir ./vault/ notes.md
```

## Pipelines

Chain operations with `|`, like jq.

```sh
# Get a frontmatter field
md 'frontmatter | .title' notes.md

# Nested field access
md 'frontmatter | .author.name' notes.md

# Count headings
md 'headings | count' notes.md

# First h2 heading text
md 'headings | select(.depth == 2) | first | .text' notes.md
```

## Filtering

`select()` filters arrays by predicate.
Supports comparisons (`==`, `!=`, `<`, `>`, `<=`, `>=`),
boolean logic (`and`, `or`, `not`),
and string functions (`contains()`, `startswith()`).

```sh
# Only h2 headings
md 'headings | select(.depth == 2)' notes.md

# Wikilinks only
md 'links | select(.kind == "wikilink")' notes.md

# Links containing "github"
md 'links | select(contains(.target, "github"))' notes.md

# Tags matching a name
md 'tags | select(.name == "draft")' notes.md

# Go code blocks
md 'codeblocks | select(.language == "go") | first | .content' notes.md

# Obsidian comments only
md 'comments | select(.kind == "obsidian")' notes.md
```

## List Operations

```sh
md 'headings | first' notes.md
md 'headings | last' notes.md
md 'headings | count' notes.md
md 'headings | reverse' notes.md
md 'links | map(.target)' notes.md
md 'links | map(.target) | unique' notes.md
md 'headings | sort(.depth)' notes.md
md 'links | group(.kind)' notes.md
```

## Record Operations

```sh
# List frontmatter keys
md 'frontmatter | keys' notes.md

# Check if a field exists
md 'frontmatter | has("draft")' notes.md
```

## Format Conversion

`yaml` and `toml` convert between records and text:

```sh
# Record to YAML text
md 'frontmatter | yaml' notes.md

# Record to TOML text
md 'frontmatter | toml' notes.md

# Parse YAML text into a record
md 'codeblocks | select(.language == "yaml") | first | .content | yaml' notes.md
```

## Frontmatter Mutation

`set()` and `del()` modify frontmatter fields.
Use `-i` for in-place editing.

```sh
# Set a field (prints modified document to stdout)
md 'frontmatter | set(.title, "New Title")' notes.md

# Delete a field
md 'frontmatter | del(.draft)' notes.md

# Edit in-place
md 'frontmatter | set(.draft, false)' -i notes.md

# Append to an array field (creates field if missing)
md 'frontmatter | .tags += ["new-tag"]' -i notes.md
```

## Section Operations

Extract and modify content under a heading.

```sh
# Extract section content
md 'section("## Methods")' notes.md

# Match by heading text (any depth)
md 'section("Methods")' notes.md

# Replace section content
md 'section("## Methods") | replace("new content\n")' -i notes.md

# Append to a section
md 'section("## Notes") | append("extra text\n")' -i notes.md
```

## Link Validation

Check whether link targets exist on disk.

```sh
# Add .exists field to each link
md 'links | exists' --dir ./vault/ notes.md

# Find broken links
md 'links | exists | select(.exists == false)' --dir ./vault/ notes.md

# Resolve wikilink paths
md 'links | resolve' --dir ./vault/ notes.md
```

## Multiple Outputs

The comma operator produces multiple values from the same input.

```sh
md 'frontmatter | (.title, .draft)' notes.md
```

## JSON Output

Add `--json` for structured output.

```sh
md 'headings' --json notes.md
md 'links | select(.kind == "wikilink")' --json notes.md
```

## Composing with Shell Tools

`md` follows the Unix philosophy.
Use standard tools for multi-file operations.

```sh
# Find all draft files
find vault/ -name '*.md' -exec md 'frontmatter | .draft' {} \;

# List all wikilink targets across a vault
find vault/ -name '*.md' -exec md 'links | select(.kind == "wikilink") | map(.target)' {} \; | sort -u

# Count words in all files
find vault/ -name '*.md' -exec sh -c 'echo "$(md "stats | .words" "$1") $1"' _ {} \;
```

## Supported Formats

- Standard Markdown links: `[text](url)`
- Obsidian wikilinks: `[[target]]`, `[[target|alias]]`
- Image/embed links: `![alt](url)`, `![[embed]]`
- YAML frontmatter (delimited by `---`)
- TOML frontmatter (delimited by `+++`)
- ATX headings (`# H1` through `###### H6`)
- Fenced code blocks (backtick and tilde)
- Indented code blocks (4+ spaces or tab)
- Inline tags (`#tag`)
- HTML comments (`<!-- ... -->`)
- Obsidian comments (`%% ... %%`)
- Footnote definitions (`[^label]: text`)

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
