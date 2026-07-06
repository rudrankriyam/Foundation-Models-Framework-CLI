# Product

## Register

product

## Users

Developers and agent operators using `afm` to inspect Apple Foundation Models
availability, run local prompts, connect to a signed Foundation Lab bridge, and
collect evidence from model runs. They are often inside Codex, Cursor, a
terminal, or a browser panel while debugging real Foundation Models behavior on
their Mac.

## Product Purpose

`afm` is a local automation layer for Apple's Foundation Models framework. It
complements Apple's native `fm` command with scriptable JSON output, validated
OpenAI-style local server routes, a signed-host bridge for PCC, and a browser
workbench that makes those surfaces inspectable and repeatable.

Success means the operator can quickly see what is runnable, understand whether
PCC is available only through the signed bridge, run a prompt, copy an exact
snippet, and point to saved trace evidence without guessing.

## Brand Personality

Quiet, precise, capable. The interface should feel close to Apple developer
tools and native macOS utilities: clear hierarchy, familiar controls, compact
information density, and no decorative theatrics.

## Anti-references

Avoid marketing-site composition, oversized hero panels, decorative gradients,
generic SaaS dashboards, glassy cards, novelty controls, and UI that hides the
Apple/PCC boundary behind vague status language. Avoid anything that looks like
a quick vibe-coded localhost demo.

## Design Principles

- Show the boundary: distinguish direct local execution from signed-bridge PCC.
- Make evidence first-class: traces, status, snippets, and run metadata should
  be visible and copyable.
- Optimize for Codex-sized browser panes: the main run path must fit without
  forcing the user through a long scrolling page.
- Prefer earned familiarity: use standard product controls, stable focus
  states, and dense but readable layout.
- Keep claims truthful: do not present unavailable runtimes, quota state, or
  bridge health as stronger than the underlying evidence.

## Accessibility & Inclusion

Target WCAG AA contrast, keyboard-visible focus states, clear button labels,
semantic status text, reduced-motion fallbacks, and layouts that remain usable
in narrow embedded browser panes.
