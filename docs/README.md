# processFNIRS2 Documentation

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.23348858.svg)](https://doi.org/10.5281/zenodo.23348858)

Reference documentation for the processFNIRS2 MATLAB fNIRS analysis toolbox.
New here? Start with the [project README](https://github.com/AyazLab/processFNIRS2/blob/master/README.md)
for installation and a quick start, then come back for the deeper references
below. Runnable tutorials live in
[`examples/scripts/`](https://github.com/AyazLab/processFNIRS2/tree/master/examples/scripts).

## Reference

| Document | What's inside |
|----------|---------------|
| [API_REFERENCE.md](API_REFERENCE.md) | Package-by-package function reference, listings, and supported-device coverage. |
| [PROCESSING_PIPELINE.md](PROCESSING_PIPELINE.md) | The three-stage pipeline (raw → optical density → hemoglobin), available methods, and configuration. |
| [USAGE_EXAMPLES.md](USAGE_EXAMPLES.md) | Worked workflows: single-subject, multi-device, and batch processing patterns. |
| [MATLAB_CLI.md](MATLAB_CLI.md) | Command-line / headless execution and automation patterns (`matlab -batch`). |
| [CLI_UX_GUIDE.md](CLI_UX_GUIDE.md) | CLI/UX conventions and the progressive-disclosure API pattern. |
| [EXPLORERNIRS_PIPELINE.md](EXPLORERNIRS_PIPELINE.md) | The group-analysis layer (exploreFNIRS): Experiment class, grouping, statistics. |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the toolbox fits together: data flow, package map, and where new code belongs. |

## Citing

If you use processFNIRS2 in your research, please cite it:

> Curtin, A., & Ayaz, H. (2026). *processFNIRS2* (Version v1.2.1) [Computer
> software]. Zenodo. https://doi.org/10.5281/zenodo.23348858

See [Citing processFNIRS2](CITING.md) for BibTeX and for choosing between the
project DOI and a per-version DOI.

## Also useful

- [Project README](https://github.com/AyazLab/processFNIRS2/blob/master/README.md) — overview, install, quick start.
- [CONTRIBUTING](https://github.com/AyazLab/processFNIRS2/blob/master/CONTRIBUTING.md) — dev setup, tests, and coding conventions.
- [exploreFNIRS README](https://github.com/AyazLab/processFNIRS2/blob/master/ExploreFNIRS_README.md) — the group-analysis module's own guide.
- [CHANGELOG](https://github.com/AyazLab/processFNIRS2/blob/master/CHANGELOG.md) — release notes.
- [Examples index](https://github.com/AyazLab/processFNIRS2/blob/master/examples/scripts/README.md) — runnable, copy-pasteable tutorials grouped by topic.

> Development roadmaps, research notes, and contributor-facing design docs are
> maintained under `internal/` and are intentionally not part of the shipped
> documentation set.
