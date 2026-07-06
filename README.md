# Foundation Models Framework CLI

`afm` is a Swift command-line tool for working with Apple's Foundation Models framework from the terminal, scripts, local servers, and agent workflows.

Use it to check runtime availability, try prompts, stream responses, count tokens, run structured-output flows, validate tools, export transcripts, serve local chat-compatible endpoints, and connect automation to a signed Foundation Lab host.

The CLI is a standalone package again. The reusable runtime pieces live in [FoundationModelsKit](https://github.com/rryam/FoundationModelsKit), and this repo builds the `afm` developer tool on top of it.

Apple's native `fm` tool remains the system-owned interface. `afm` complements it with scriptable JSON output, request validation, local OpenAI-style chat endpoints, and the signed Foundation Lab bridge that lets agents use PCC without pretending PCC is a raw server API.

## Requirements

- macOS 26+
- Swift 6.2+
- Xcode 26.6 or Xcode 27
- Apple Silicon with Apple Intelligence for live on-device model execution
- OS 27 and the right entitlement state for Private Cloud Compute checks
- A signed Foundation Lab host when a separate process needs to execute PCC

File-based workflows, dry runs, schema inspection, token estimates, tool validation, and server request validation are useful even when live model execution is unavailable. Unsigned CLI processes can inspect the PCC boundary, but PCC execution belongs to the signed host that owns the entitlement.

## Build

```bash
git clone https://github.com/rudrankriyam/Foundation-Models-Framework-CLI.git
cd Foundation-Models-Framework-CLI
swift build -c release --product afm
.build/release/afm --help
```

For local development:

```bash
swift build --product afm
swift test
swift run afm --help
```

For a local Homebrew-prefix install while iterating:

```bash
swift build -c release --product afm
install -m 755 .build/release/afm /opt/homebrew/bin/afm
afm --version
```

## First Commands

```bash
afm available
afm quota-usage --model pcc
afm model status
afm token-count "What is Swift?"
afm session respond --prompt "Summarize Foundation Models in one paragraph."
afm session stream --prompt "Write a short poem about rain."
afm session chat --message "Hello" --message "Now answer in French."
afm schema run typed-person --input "Alex Rivera is a designer in Berlin."
afm tool inspect --tool demo-weather
afm serve
afm serve --ui
afm bridge status
afm bridge chat --model pcc --prompt "Summarize this repository."
```

## Runtime Checks

Use `available`, `quota-usage`, and `model` when you want to know what the system can do right now.

```bash
afm available
afm available --model on-device
afm available --model pcc
afm quota-usage --model pcc
afm model status
afm model languages
afm model use-cases
afm model guardrails
```

These commands report framework availability separately from whether the current process can actually run the selected runtime. That distinction matters for PCC: an unsigned CLI can report that PCC exists while also reporting that the current process is missing the entitlement.

## Token Counting

Use `token-count` before sending a prompt, schema, or tool-heavy request.

```bash
afm token-count "What is Swift?"
afm token-count --instructions @instructions.md --prompt @prompt.md --breakdown
afm token-count --schema person-card --schema-dir .afm/schemas --prompt @person.txt
afm token-count --tool demo-weather --prompt "Use the weather tool."
afm token-count --output json --pretty --prompt @prompt.md
```

The JSON output includes provenance so you can tell exact tokenizer counts from estimates.

## Sessions

Use `session` for one-shot prompting, streaming, and shared-context conversations.

```bash
afm session respond --prompt "Summarize Foundation Models in one paragraph."
afm session respond --prompt @prompt.txt
afm session respond --adapter ~/MyAdapter.fmadapter --prompt "Rewrite this in my style."
afm session respond --use-case content-tagging --prompt "Organize this photo library item."
afm session stream --prompt "Write a short poem about rain."
afm session chat --message "Hello" --message "Now answer in French."
```

Streaming JSON output is newline-delimited so scripts and agents can react while generation is still running:

```bash
afm session stream --output json --prompt "Reply with three short lines."
afm session chat --stream --output json --message "Hello" --message "Keep going."
```

## Structured Output

Use `schema` when the result needs to fit a predictable shape.

```bash
afm schema list
afm schema object --name Person --string name --integer age --optional
afm schema run typed-person --input "Alex Rivera is a designer in Berlin."
afm schema run basic-object --preset product
afm schema run array-schema --preset todo
afm schema run enum-schema --preset sentiment
afm schema run custom --schema person-card --schema-dir .afm/schemas --input @person.txt
afm schema run custom --schema person-card --input @person.txt --no-include-schema-in-prompt
```

Bare schema identifiers resolve through `--schema-dir`, which defaults to `.afm/schemas`.

## Tools

Use `tool` to inspect, validate, and call file-backed tools before using them in a session.

```bash
afm tool inspect --tool demo-weather
afm tool validate --tool demo-weather
afm tool call --tool demo-weather --args "{}"

afm tool inspect --tool echo-json --tool-dir .afm/tools
afm tool call --tool echo-json --tool-dir .afm/tools --args @args.json
afm session respond --prompt "Use the bundled weather sample." --tool demo-weather
```

Bare tool identifiers resolve through `--tool-dir`, which defaults to `.afm/tools`.

## Local Server

`afm serve` exposes local Foundation Models-compatible chat endpoints over TCP or a Unix-domain socket. This is the direct local service path for the current process.

```bash
afm serve
afm serve --ui
afm serve --ui --trace-dir ~/.afm/traces
afm serve --host 127.0.0.1 --port 4815
afm serve --socket ~/.afm/bridge.sock
```

The server validates request shape, authentication, loopback binding, body limits, tool schemas, structured response formats, streaming, and cancellation paths before model work runs.

### Browser Workbench

Use `afm serve --ui` when you want a local browser control plane for Codex, Cursor, or another agent running on the same Mac.

```bash
afm serve --ui
open http://127.0.0.1:1976
```

The workbench serves:

- `/` and `/workbench`: a local browser UI for model status, prompt runs, snippets, and traces.
- `/api/workbench/status`: direct runtime, PCC quota, signed bridge, and trace-directory status.
- `/api/workbench/snippets`: copyable curl, JavaScript, and Codex walkthrough snippets.
- `/api/workbench/traces`: recent saved run summaries from `~/.afm/traces`.
- `/api/workbench/chat`: a JSON wrapper around the direct local server or signed bridge chat path.

`--ui` requires TCP because browsers cannot open Unix-domain sockets. PCC runs still use the signed Foundation Lab bridge; the workbench only makes that boundary visible and easier to drive from a browser.

## Foundation Lab Bridge

`afm bridge` talks to a signed Foundation Lab host when a separate process needs to use the app as the model host. This is the PCC path for agents and automation: Foundation Lab owns the entitlement and the local bridge exposes only an authenticated loopback descriptor.

```bash
afm bridge prepare
afm bridge ensure
afm bridge status
afm bridge models
afm bridge chat --model pcc --prompt "Summarize this repository."
```

This keeps the CLI useful in headless scripts and agent workflows while still letting Foundation Lab own app-specific hosting.

## Release

The CLI version is declared in `AFMRootCommand`. Tagged releases use the same semantic version as the Git tag, build a universal macOS binary, and optionally update the Homebrew tap:

```bash
git tag 0.2.0
git push origin 0.2.0
```

After the release workflow publishes `afm_0.2.0_macOS_universal`, the tap formula should point at that artifact and checksum.

## Files And Automation

`afm` is designed for terminal and automation use:

```bash
afm session respond --prompt @prompt.md
cat prompt.md | afm session respond --output json
afm schema run custom --schema person-card --schema-dir .afm/schemas --input @person.txt
afm tool call --tool echo-json --tool-dir .afm/tools --args @args.json
```

Output defaults to text in an interactive terminal and JSON when piped or used in CI:

```bash
afm model status --output text
afm model status --output json --pretty
```

## Relationship To The Other Repos

- [FoundationModelsKit](https://github.com/rryam/FoundationModelsKit): reusable Swift package used by apps and CLIs.
- [Foundation Models Framework Lab](https://github.com/rudrankriyam/Foundation-Models-Framework-Lab): native app for exploring and validating the framework.
- `Foundation-Models-Framework-CLI`: this repo, the canonical home for the `afm` command.

## Development

```bash
swift build --product afm
swift test
swift run afm --help
```

When public command behavior changes, update this README and the command help together.
