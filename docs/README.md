# Duel guide

The [README](../README.md) shows how to install Duel, write a first
benchmark, run it, and run it in CI. This guide covers the rest.

| Page | What it covers |
|---|---|
| [Write benchmarks](benchmarks.md) | Hooks that run code around a benchmark, starting every sample alike, undoing each iteration, measuring work that a benchmark leaves for later, sharing code between benchmarks, choosing what a benchmark is judged on, and benchmarking a whole process. |
| [Configure Duel](configuration.md) | `.duel.rb` and its settings, preparing each worker and each version, running code in each worker, running each version on its own Ruby, adding your own metrics, and using plugins. |
| [Run Duel in CI](ci.md) | The GitHub Actions workflow that `duel init` writes, catching slow creep, commenting on a pull request, and installing the baseline's Ruby on CI. |
| [How Duel works](how-it-works.md) | How Duel tells a regression from noise, what it measures, where the extra time went, where the baseline comes from, and JIT compilers, including JRuby and TruffleRuby. |
| [Read Duel's report as JSON](json.md) | Writing the report as JSON with `--json`, its schema and how it's versioned, and an example. |
| [Troubleshooting](troubleshooting.md) | What Duel says when it can't compare, or reports what you don't expect, and what to do about it. |
| [Write a Duel plugin](plugins.md) | Plugin conventions, adding to the DSL, hooks and metrics in a plugin, explaining a sample, and testing a plugin. |

## Public API

What the README and this guide document is Duel's public API, which
follows [Semantic Versioning](https://semver.org).

> [!IMPORTANT]
> Anything marked `@api private` in the code or in its signatures
> (`sig/`) is Duel's own, and can change in any release.
