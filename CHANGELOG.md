# Changelog

## v1.2.2 (2026-10-30)
NIRx import and SNIRF export follow-ups: vendor geometry, NIRStar recordings without a `.nirs` file, and recording start times.

### Added

- `pf2.import.importNIRX` accepts `'Model'` (for example `'NIRSport2'`) to name the device when the `.hdr` only records a serial `Device ID`, as Aurora writes it.

### Changed

- `pf2.export.asSNIRF` writes `MeasurementDate` and `MeasurementTime` in UTC (`+00:00`) when the recording's time zone is known, with the zone in `MeasurementTimeZone`. MNE drops the UTC offset when it reads `MeasurementTime`, so a local time with an offset was read as UTC.
- The "Time column could not be found" warning from device setup in `processFNIRS2` is shown once per session (`pf2:updateCurrentDevice:noTimeColumn`). It is expected for devices whose raw data has no time column, such as NIRx, and was repeated for every recording.
- `pf2.import.importNIR` no longer stores the marker file index in `Amplitude`. When markers come from more than one `.mrk` file, a `MarkerSource` column holds the file each came from; with one file there is no extra column and `Amplitude` keeps its default of 1, which SNIRF export does not write. The marker documentation now describes the `.mrk` columns as they are read.

### Fixes

- `pf2.export.asSNIRF` writes the measurement list as SNIRF defines it: `dataType`, `dataTypeIndex`, `sourceIndex`, `detectorIndex` and `wavelengthIndex` as integers (they were doubles, which the SNIRF validator rejects), and no `dataTypeLabel` (`raw-DC` is not a SNIRF label; labels are defined for processed data) or `dataUnit`. MNE 1.13 refuses files whose `dataUnit` is `au`. `importSNIRF` reads the integer fields as doubles and finds raw channels by `dataType` when de-normalizing.
- `pf2.export.asSNIRF` no longer writes `.info` fields that identify or describe a person (names, date of birth, age, sex, experimenter or operator, contact details, free-text notes) unless `'IncludeIdentifying'` is true, and writes only the file name of path values. The `.nir` filename was written with the full local path, including the user name.
- `pf2.import.importNIRX` uses the vendor coordinate set from `<root>_probeInfo.mat` when present, the source of the positions in NIRx's own SNIRF: 3D positions in mm, the vendor 2D layout, 10-10 optode labels, and the head model as the coordinate system (ICBM152 is declared as MNI). Landmarks (Nz, Iz, LPA, RPA, Cz) are read from `digpts.txt`. The `.nirs` `SD` positions it used before are in a translated frame.
- `pf2.import.importNIRX` imports NIRStar recordings that have no `.nirs` file. It errored on an undefined variable and built no device. Channels now come from the `.hdr` `S-D-Key` and `S-D-Mask`, data from the `.wl1`/`.wl2` files, geometry from `<root>_probeInfo.mat`, and markers from the `.hdr` `Events` or, when there are none, the `.evt` trigger bits. `.hdr` `Events` rows no longer read the frame number as the duration. A `_probeInfo.mat` that lists more optodes than the recording uses is accepted, and a recording without markers gets an empty marker table.
- `pf2.import.importNIRX` sets `t0` from the first frame of the raw `.roh` stream, read from inside `<root>.zip` without extracting it, when present; this is the start time NIRx's own SNIRF reports. It reads the Aurora `Sampling rate` header key.
- `pf2.export.asSNIRF` writes source and detector labels and landmarks (`landmarkPos3D` with a label index and a 1-D `landmarkLabels`), and declares the device coordinate system. BIDS identifiers go to `probe/coordinateSystem`; other tags such as `MNI` go to the `CoordinateSystem` and `CoordinateSystemDescription` metadata tags, which `importSNIRF` restores, since `Other` draws a validator warning.
- `pf2.import.importSNIRF` converts `UnixTime` to the recording's `MeasurementTimeZone` instead of attaching the zone to the UTC clock time, which shifted `t0` by the zone's offset. A `MeasurementTime` with a UTC offset is parsed, and a time without a zone stays zone-less instead of taking this machine's zone.
- `pf2.import.importSNIRF` reads landmark labels stored as fixed-width strings, as NIRx writes them; such files failed to import.
- `pf2_base.tests.integration.RoundtripTest` export checks pass a time zone, since exporting without one now warns.

## v1.2.1 (2026-10-16)
Groundwork for running headless single-subject processing under GNU Octave.

### Added

- GNU Octave CI (`.github/workflows/octave.yml`) runs `pf2_base.tests.runOctaveSubset` in the `gnuoctave/octave:11.3.0` image on every push and pull request. It covers package loading, the INI reader/writer, every shipped device, import, default processing, the Pipeline API through a `ProcessingContext`, the block-averaging recipe (markers, blocks, epochs, averages, sliding windows) and the QC pipeline, and compares numerical results with a MATLAB reference (`+pf2_base/+tests/+data/octave_reference.mat`, rebuilt with `pf2_base.tests.generateOctaveReference`). The job removes the root `pf2.m` GUI launcher from its checkout, since under Octave it shadows the `+pf2` package.
- `pf2.import.sampleData(name, ...)` loads a named sample dataset (`'fNIR2000'`, `'experiment'`, `'group'`, ...), equivalent to `pf2.import.sampleData.<name>(...)`. Under Octave this is the form that works, since there `sampleData.m` hides the `+sampleData` namespace.
- `pf2_base.args.parse` and `pf2_base.args.check` reproduce arguments-block input handling (optional positional inputs, name-value matching, class conversion, size checks, validators and their error identifiers) in a form Octave can run.
- `pf2_base.env.ensureOctaveCompat` loads the Octave `datatypes`, `signal` and `statistics` packages and adds `compat_shims/octave` (`contains`, `strip`, `strlength`, `extractAfter`, `extractBefore`, `isStringScalar`, two-argument `round`). It runs automatically at the importer, device-loading and initialization entry points and does nothing under MATLAB.
- `pf2_base.env.runtime` now reports missing `datatypes` and `statistics` packages as well as `signal`.

### Changed

- `pf2.data.defineBlocks` warns instead of silently returning no blocks when the markers are empty (`pf2:defineBlocks:noMarkers`), when none of the requested marker or end-marker codes occur (`pf2:defineBlocks:codesNotFound`, which lists the codes present and flags non-integer codes as a likely column-order problem), when start codes have no following end code (`pf2:defineBlocks:noPairedBlocks`), and when every block falls outside `MinDuration`/`MaxDuration` (`pf2:defineBlocks:allBlocksFiltered`). Messages name the recording when `info.filename` or `info.SubjectID` is set.
- `pf2_base.external.INI` no longer derives from `dynamicprops`. Sections are held in a private struct and reached through overloaded indexing, so `cfg.<Section>`, `cfg.("Section")`, `get`, `add`, `remove`, `read` and `write` behave as before, including on object arrays and indexed elements. Display lists each section. A section whose name matches a property or method of the class (for example `write` or `Data`) is stored under an `x_` prefix and still reached by its original name through `get`, `remove` and `write`; the old class refused such names.
- `pf2.methods.raw.create` and `pf2.methods.oxy.create` reject method names that match a property or method of `INI`, since method libraries address methods as `cfg.(name)`.
- INI objects saved by earlier versions keep their sections: MATLAB re-attaches the old dynamic properties after loading, and the first access moves them into the new store. Any section still missing is re-read from `File`, with a warning if it cannot be restored. Under Octave, saving and loading classdef objects keeps only their declared properties, so INI section data does not survive a save there.
- `pf2_base.fnirs.processStageOD2Hb` parses its name-value options with `inputParser` instead of an `arguments` block.
- The functions in `pf2.data` (including `pf2.data.aux`) and `pf2.qc` parse their inputs with `pf2_base.args` instead of `arguments` blocks, whose name-value entries Octave cannot parse. Inputs are handled as before: a comparison of the original and new parsing over several thousand input combinations (defaults, positional prefixes, name variants, wrong types, unknown and ambiguous names, unpaired lists) found no difference in values, classes or error identifiers.
- Exported group tables (`Experiment.toWideTable`, `toLongTable`, `writeCSV`, and the default labels of `exploreFNIRS.export.mergeGbyTablesWide`/`mergeGbyTablesLong`) name channels with zero-padded numbers from the new `pf2_base.channelLabels` (`HbO_Opt01`, `Opt01_HbO`). With 10 or more channels these were space-padded (`HbO_Opt 1`); columns now sort in channel order and contain no spaces. LME model labels are unchanged. The wide export's default labels no longer fail when no names are passed.
- `pf2_base.ProcessingContext`, `pf2_base.Pipeline` and `pf2_base.PipelineFunction` declare properties without inline types or validators, which Octave cannot parse. Set methods on `ProcessingContext` and `Pipeline` convert, size-check and validate in the same order as the declarations, with the same MATLAB error identifiers. Under MATLAB, ordinary values (char, string scalars, numeric, logical, structs and empty arrays) convert and error as before. Exceptions: objects such as `datetime`, `categorical` or `table` assigned to a struct-valued `ProcessingContext` property now error instead of being converted with `struct()`; complex values with a zero imaginary part are accepted as real instead of failing `mustBeReal`; and `matlab.lang.OnOffSwitchState` values assigned to logical properties are stored as `logical`. Under Octave, `mustBeMember` and `mustBePositive` raise errors without an identifier.
- `ProcessingContext` derives from `handle` and implements `copy()` itself instead of inheriting `matlab.mixin.Copyable`. `copy()` still returns an independent shallow copy of the same class and size, including `pf2.ProcessingContext` and `pf2_base.GUIContext`, without reloading the method libraries. Subclass constructors receive `ProcessingContext.COPY_TOKEN` from `copy()` and must accept it.

### Fixes

- `pf2.import.importNIRX` checks `.hdr` sections with `isprop` instead of `fieldnames`, which no longer lists sections now that `INI` does not derive from `dynamicprops`. Without this the sampling rate, markers, subject and date in the `.hdr` were skipped.
- `pf2.import.importNIRX` sets `t0` (and `info.StartDateTime`) from the `.hdr` `Date` and `Time`, including a `Date` that holds the full timestamp (`yyyy-MM-dd HH:mm:ss.SSSSSS`). A date that cannot be parsed raises `pf2:importNIRX:unparsedStartTime`. The device model comes from the `.hdr` `Device` entry, or else from `Device ID` mapped to the model name (NIRSport, NIRSport2, NIRScout, NIRScoutX), instead of a fixed `'Sport'`.
- `pf2.import.importNIRX` keeps 3D optode positions in mm, as `.cfg` devices and `importSNIRF` do, and declares `CoordinateUnits = 'mm'`. Source-detector distances stay in cm and are computed from the 3D positions. The 2D layout is a top view (anterior up, the subject's right on the right): the positions themselves when the montage is planar, an azimuthal equidistant projection about the vertex for head-centred positions, and otherwise a projection onto the best-fit plane. Positions were previously stored in cm with the 3D coordinates copied into the 2D layout.
- `pf2.import.importNIRX` drops all-zero aux columns, which NIRStar writes when no aux input is connected.
- `pf2.import.importNIRX` stores `Probe.Wavelength` as the unique wavelength list indexed by `wvI`. It was a per-measurement list, so SNIRF export wrote the first wavelength for both wavelength indices (for example `[760 760]`).
- `pf2.export.asSNIRF`, `pf2.export.asBIDS` and batch SNIRF export take a `'TimeZone'` option for a `t0` without a time zone. With a zone (from `t0` or the option), `MeasurementTime` includes its UTC offset and `MeasurementTimeZone`, `UnixTime` and `AcquisitionStartTime` are written. Without one, `MeasurementTime` has no offset, `UnixTime` and `AcquisitionStartTime` are omitted, and `pf2:asSNIRF:noTimeZone` is warned. A zoneless `t0` was previously read as UTC, which put `.nir` recordings 4-5 h early in US Eastern time.
- `pf2.export.asSNIRF` writes `MeasurementDate` only from a parsed date, as `yyyy-MM-dd`. Free-text `info` date fields were written as they were.
- `pf2.export.asSNIRF` writes stim column labels as one 1-D `dataLabels` string dataset, as the SNIRF specification defines it, instead of `dataLabels1`...`dataLabelsN`, which other readers ignored. An `Amplitude` column that is all 1 (the default, which `importSNIRF` restores) is no longer written.
- `pf2.export.asSNIRF` writes `probe/wavelengths` and `data/time` as 1-D datasets, through a `Force1D` option added to the bundled `easyh5` writer.
- `pf2.export.asSNIRF` takes `LengthUnit` from the device's `CoordinateUnits` when set and adds a 0 nm entry to `probe/wavelengths` only when the data includes dark channels.
- `pf2.import.importNIR` documents how `.mrk` columns map to markers: the third column is read as `Duration`, though COBI Studio writes a running counter there; manual marker files get `Duration` 100; `Amplitude` holds the index of the source `.mrk` file.
- `pf2_base.tests.unit.AllPlotsSmokeTest/testCreateFigure` pins light mode, as `PlotStyleTest` does, so a dark default figure color left by earlier rendering tests no longer fails it.
- `pf2_base.tests.integration.FullPipelineTest/testDifferentMethods` builds its method combinations with the Pipeline API and runs them through a `ProcessingContext`, so it no longer skips on machines without the named methods in their library or changes the global method selection.
- `pf2_base.normalizeMarkerDict` parses `{code, label}` cell dictionaries element by element, so numeric codes keep one row each under Octave.
- `pf2_base.external.zp2sos` orders complex roots with `sortrows` instead of `sort(..., 'ComparisonMethod', 'real')`, which Octave lacks; the resulting second-order sections are identical.
- `pf2.data.split` and `pf2.data.resample` failed on aux signals stored as tables with their own time column (for example a derived HRV series): MATLAB R2025b's `table` rejects a single char name for `'VariableNames'`. The time-column name is now passed as a cell array. v1.1.0 is affected the same way.
- `pf2_base.wavelet.wcoherence` returns NaN when either input has no finite samples or is constant. With cached CWTs (`'CwtX'`/`'CwtY'`) the coefficients of a series containing NaN are NaN, and the clamp `min(wcoh, 1)` turned them into a coherence of exactly 1, because `min` ignores NaN; computed internally, an all-NaN series was zero-filled and gave 0. The clamp now leaves NaN in place. Hyperscanning analyses that cache per-channel CWTs and include a fully rejected channel or ROI were inflated toward 1 for every pair involving it. `WaveletCoherenceTest` covers both paths.
- `pf2.import.importHitachiMES` no longer requests the unused second output of `strsplit`, and `pf2.data.split` assigns its time-size variables directly; both failed under Octave.
- `loadDeviceCfg` and `pf2_base.gui.updateCurrentDevice` assign whole table columns instead of growing them by indexed assignment, and no longer call `sprintf` on a categorical or `nansum` on a logical.
- `bvoxy` declares its positional `coefs` and `isOD` options before its name-value parameters. Argument handling under MATLAB is unchanged.
- Calls to the undocumented `fields` alias use `fieldnames`.
- `pf2.Device` and `pf2_base.PipelineFunction` properties use `SetAccess = private` instead of `immutable`, which Octave does not support. They remain read-only outside the class.
- `processFNIRS2`'s local device helper is renamed so Octave resolves the call to `pf2_base.gui.updateCurrentDevice` instead of recursing into the local function.
- `pf2_initialize` adds the toolbox subfolders by absolute path. Octave stored the relative entries verbatim, so they stopped resolving after the working folder changed.
- Removed a stray editor temporary file (`+pf2_base/+external/.!36603!INI.m`).

## v1.2.0 (2026-10-09)
processFNIRS2 moves to the AyazLab organization.

### Changed

- The repository moved to the AyazLab organization: https://github.com/AyazLab/processFNIRS2. Old GitHub URLs redirect. The documentation site is now https://ayazlab.github.io/processFNIRS2/; the old `adriancurtin.github.io` address does not redirect.
- `CITATION.cff`, the README citation, and the documentation links point at the new location.

### Added

- Zenodo archiving. The concept DOI [10.5281/zenodo.23348858](https://doi.org/10.5281/zenodo.23348858) is in `CITATION.cff` and the README citation.

## v1.1.2 (2026-10-09)
Citation metadata ahead of Zenodo archiving.

### Added

- Author ORCIDs in `CITATION.cff`, which GitHub's "Cite this repository" and Zenodo archiving read.
- `pf2version` reports the current release; v1.1.1 shipped reporting v1.1.0.

## v1.1.1 (2026-10-09)
SMAR motion-artifact functions on raw intensity, and QC power-spectrum crash and channel-mapping fixes.

### Fixes

**SMAR motion-artifact family (`pf2_SMAR`, `pf2_SMAR_mask`, `pf2_SMAR2`, `pf2_sSMART`):**
- These functions now run on raw light intensity only, before `pf2_Intensity2OD`. Their coefficient-of-variation test divides by the windowed mean, which is near zero for optical density and hemoglobin, so on OD they rejected most of a recording (94% of the fNIR2000 sample for `pf2_SMAR`). The function library now marks them raw-stage, and each warns when given non-positive input.
- The `OD_SMAR` seed now runs a 0.1 Hz low-pass, then SMAR, then the OD conversion, the order used in published SMAR work. On startup, a stored `OD_SMAR` that still matches the old seed exactly is replaced; edited copies are left alone (run `pf2.methods.resetDefaults('raw')` to re-seed them).
- Saved methods no longer pin a registered function's `requiresOD`/`validStages`; the function library is authoritative, so methods saved with the old flags can place SMAR before the OD conversion.
- `pf2_SMAR2`: new defaults `tauArtifact = 10`, `tauClean = 1`, `minSeg = N + 2`. The old defaults rejected most of an artifact-free recording, and `tauClean = 0` (the previous library default) masked whole channels; `tauClean` must now be > 0. Artifact segment indices (`MA_idx`) are now in input rows, masked segments no longer grow by a sample, the recording edges are evaluated with a shrinking window instead of always rejected, `chNum` is validated, and a window spanning the whole recording warns instead of silently passing artifacts.
- `pf2_sSMART`: gap filling no longer extrapolates past the last clean sample (`pchip`/`spline`/`makima` previously diverged at the recording edges). Detection runs on raw intensity, with shift correction and interpolation done on log intensity. Empty arguments now select defaults, `minSeg = -1` (the library default) selects the automatic N+2, and channels masked in full raise a warning.
- Removed the `pf2_SMAR2_mask` library entry, which referenced a function that no longer exists.

**Quality control (`pf2.qc.powerSpectrum`, `pf2.qc.sci`, `pf2.qc.pipeline.assess`):**
- `pf2.qc.powerSpectrum` no longer errors with "Index in position 2 exceeds array bounds" when every channel is masked bad; it returns an empty result and `assess` fails the cardiac check for all channels. This crash surfaced through the cardiac check in `assess` and `pf2.qc.ChannelCheck`.
- `powerSpectrum` clamps the Welch window to between 3 samples and the recording length, so recordings shorter than `WindowLength` no longer error in `pwelch`.
- `powerSpectrum` on raw data now reads each channel's first non-dark wavelength column from the device layout. It previously assumed 2 interleaved columns per channel, so on devices with a dark column (fNIR1200, fNIR2000, fNIR3000) most channels were analyzed on a dark or wrong-wavelength column. Cardiac results on raw data from these devices change accordingly.
- `assess`, `sci`, and `powerSpectrum` map channel k to the k-th entry of the device channel list, as `processFNIRS2` does. On the merged Hitachi probe (`fNIR_Hitachi_3x5_merged`), whose channel numbers are non-contiguous, results previously landed on the wrong channels and some channels were never assessed. A `.device` that is not a `pf2.Device` is now ignored instead of erroring.
- Recordings too short for a measure now skip it instead of reporting a meaningless result. SCI and cardiac need 5 cycles of the cardiac band's lower edge (10 s for the default band) and report `skipped` with a `skipReason`, without penalizing channels; SCI previously failed every channel on short data and errored at 2 s. `powerSpectrum` peak bands carry `skipped`/`skipReason` under the same rule (10 s cardiac, 50 s respiratory, 100 s Mayer), so Mayer detection is now skipped on recordings under 100 s.
- `pf2.qc.pipeline.report` prints each skipped check's actual reason instead of always "not applicable at this fs", and `assess` now carries the Takizawa skip reason.
- `pf2.qc.plotQuality` renders PSD results with no channels or an all-zero spectrum instead of erroring.

## v1.1 (2026-07-24)
Phase-synchrony coupling metrics, GLM group statistics, result-table/BIDS export, Beer–Lambert extensions (PPF mode, partial-volume correction, OD-space short-channel regression), in-memory device geometry, a cortical head render, and a broad correctness/robustness pass across GLM, hyperscanning statistics, hemoglobin conversion, export, and the importers.

### New Features

**Processing Methods:**
- New default oxy (Stage 3) methods, seeded via `pf2_base.methods.seeds.oxy.*`: `HPF` (0.01 Hz high-pass), `BPF` (0.01–0.1 Hz Butterworth band-pass), and `takizawa_easy` / `takizawa_hard` (Takizawa automatic channel rejection, lenient / strict criteria — Takizawa et al. 2008)
- Refreshed the processing-method reference tables to match the live registry

**Toolbox-Free Signal Processing (`+pf2_base/+external/`):**
- First-party implementations of `butter`, `fir1`, `sgolay`, `sgolayfilt`, `medfilt1`, `zp2sos`, and the window functions (`hamming`, `hann`, `hanning`, `genCosWin`), so filtering and motion correction no longer require the MATLAB Signal Processing Toolbox
- Filtering and motion-correction functions (`bpf`/`hpf`/`lpf`, `pf2_bpf_*`, `pf2_hpf`/`pf2_lpf`, `pf2_bandstop`, `pf2_MotionCorrectTDDR`, `pf2_MotionCorrectSplineSG`) route through the external math and `filtfilt_classic`/`filtfilt_piecewise`/`filtfilt_interp`
- `+pf2_base/+tests/+unit/ExternalMathTest.m` — validates the external math against ground-truth and (when available) toolbox reference values

**Global / Systemic Signal Removal:**
- `pf2_GSR` — PCA-based global signal removal, isolating and subtracting the dominant shared-variance component(s) as a model of systemic (extra-cerebral) interference, with a fractional-variance safety cap and column-mean preservation
- Compared head-to-head with common-average reference (`pf2_CAR`) and short-channel regression (`pf2_SSR`), now updated to share a common interface
- `examples/scripts/example_global_signal_removal.m` — CAR vs PCA-GSR vs short-channel regression on the fNIR2000 sample and against ground truth

**Spatial Visualization:**
- `pf2.probe.project.parcels()` — Voronoi-style per-channel optode parcel map on the cortical surface (nearest-optode cells with smooth outlines and numbering), with channel highlighting and value-filled or schematic display modes
- `exploreFNIRS.connectivity.plotChord()` — colour nodes by a per-node statistic with its own colorbar (`'NodeValues'`, `'NodeColormap'`, `'NodeCLim'`), group nodes under region anchors (`'GroupLabels'`), and draw uniform-colour edges
- `pf2.probe.plot.interpolateValues3D()` — render-style refinements and a parcellation overlay path (`'Parcellate'`, `'HighlightChannels'`)

**Documentation Site:**
- MkDocs configuration (`mkdocs.yml`) and a published `docs/` reference set (API reference, processing pipeline, usage examples, CLI/UX guide, exploreFNIRS pipeline, architecture)
- `CONTRIBUTING.md` contributor guide and a GitHub Pages build workflow (`.github/workflows/docs.yml`)
- Top-level `README.md` restructured to a concise overview, with detailed material relocated into `docs/`

**Diffuse Optical Tomography (`+pf2/+probe/+dot/`, `+pf2/+probe/+forward/`):**
- `pf2.probe.forward.sensitivity()` — channel-by-vertex PMDF ("banana") sensitivity matrix on the bundled MNI cortical surface, relating an absorption change at each vertex to each channel's optical-density change; options for wavelength, scalp offset, max source-detector distance, and pruning
- `pf2.probe.forward.coverage()` — per-vertex sensitivity support map for a montage
- `pf2.probe.dot.reconstruct()` — vertex-space HbO/HbR image reconstruction by inverting the forward model with a depth-weighted, channel-whitened Tikhonov min-norm estimator; automatic regularization (GCV or L-curve), masked to the coverage support; time-mean, windowed, or all-time output; priors `minnorm` / `laplacian` (spatial smoothness) / `parcel`; optional layered head model and short-separation scalp regression
- `pf2.probe.dot.montageInfo()` — reports whether a montage is high-density / multi-distance and its reconstruction suitability
- `pf2.probe.dot.resolution()` — point-spread-function diagnostics (localization error, spread, FWHM)
- `pf2.probe.project.tomography()` — render a reconstruction on cortex (signed, sensitivity-masked, headless-safe)
- `pf2.probe.project.pmdf()` — honest channel projection through the physical optical footprint (vs a Gaussian kernel)
- `pf2.probe.plot.tomographyMovie()` — time-resolved DOT movie (MP4/AVI/GIF)
- `+pf2_base/+dot/` internals: Green's functions (homogeneous and layered), layered head model, cortical mesh and surface normals, mesh Laplacian, optical properties, sensitivity matrix assembly, and regularization-parameter selection
- `examples/scripts/example_dot_reconstruction.m` — DOT tutorial: forward sensitivity, montage coverage, banana projection, depth-weighted reconstruction, cortical render

**PPI Hyperscanning:**
- `exploreFNIRS.connectivity.computePPI()` — cross-brain psychophysiological interaction: `'SeedData'` for a seed taken from another recording (e.g. speaker→listener), `'SeedSignal'` for an external seed (e.g. EKG/HRV-derived), plus polynomial drift modeling, OLS / AR-IRLS fitting, optional HRF deconvolution, and ROI seed/target selection
- `pf2.data.aux.hrvSeries()` — time-resolved HRV metrics via a sliding window over a PPG/EKG waveform, for use as a continuous PPI seed signal
- `exploreFNIRS.core.GLMExperiment.ppi()` / `.ppiTable()` / `.ppiLME()` — group-level PPI: per-subject contrast betas reshaped into a long-format bridge table and modeled with an LME
- `exploreFNIRS.hyperscanning.computeGroup()` — N-way (e.g. triad) coupling via `'GroupSize'`
- `examples/scripts/example_ppi_hyperscanning.m` — PPI tutorial: cross-brain seed, EKG/HRV-derived seed, triad coupling, group-level PPI modeling

**Generic Tidy-Table Import:**
- `pf2.import.fromTable()` — adapt plain long-format (tidy) repeated-measures data (survey waves, longitudinal scores, diary measures) into the cell array of segment structs the toolbox consumes, so the Experiment class, temporal/bar plots, and the LME engine work on non-fNIRS data; `'Subject'` / `'Time'` / `'Value'` column mapping, multi-channel values, `'TimeMode'` (`index` vs real-spacing `value`), `'Duplicates'` handling, and subject-constant columns carried into `.info` as grouping factors. No device/probe, so spatial visualization is unavailable
- `exploreFNIRS.core.Experiment` honors `settings.useBaseline = false` and `settings.resampleRate = 0` to skip baseline correction and resampling for already-summarized input

**Block & Marker Workflow:**
- `pf2.data.dedupeMarkers()` — collapse near-duplicate markers that share a Code and fall within a time `'Tolerance'` of an earlier kept row (typical of bouncing device triggers)
- `pf2.data.removeMarkers()` — drop marker rows by Code, time window, row index, or any combination
- `pf2.data.defineBlocks()` — explicit per-block metadata sources (`'ConditionMap'`, `'InfoTable'`, `'InfoFields'`) and per-trial factors carried from marker columns (e.g. RT, condition label) into `block.info`, with explicit sources taking precedence
- `pf2.data.importBlockInfo()` now accepts block metadata directly from memory, not just a CSV/Excel path: pass an in-memory MATLAB table, or a per-block numeric vector with `'Field'` to name the target `block.info` field (default `'value'`). Non-path/table/vector inputs raise a clear error instead of a cryptic file-read failure

**LME Robustness & Diagnostics:**
- `exploreFNIRS.stats.suppressLMEWarnings()` — scope-suppresses the `fitlme` rank-deficiency / Hessian warning identifiers that otherwise repeat per channel and term, returning an `onCleanup` handle that restores prior state
- `exploreFNIRS.stats.autoModelLME()` / `fitLME()` / `fitInfoLME()` — rank-deficiency-aware model selection and reporting

**Probe Geometry Export:**
- `pf2.probe.saveCfg()` — serialize a probe's geometry (from imported data or a SNIRF file) into a toolbox-native device `.cfg`, reloadable via `pf2.Device.load`; reconstructs source/detector coordinates, channel/wavelength mapping, and source/detector indices, preferring 3D (mm) with a 2D fallback

**BIDS Export:**
- `pf2_base.bids.resolveEntities()` — recordings that collide on sub/ses/task without an explicit run are auto-numbered `run-01`, `run-02`, … in input order; a duplicate explicit run is renumbered to the next free value with a `pf2:asBIDS:runCollision` warning so entities never resolve to the same path

**New Coupling Methods:**
- `exploreFNIRS.coupling.partialCorr()` — partial correlation controlling for confound signals
  - Standalone: pass `'Confounds', Z` to regress out signals (QR decomposition)
  - Via `computeMatrix`: uses precision-matrix batch path (inverts covariance, no pairwise regression)
  - Ledoit-Wolf shrinkage regularization for near-singular covariance matrices
  - Supports sliding window mode; p-values via t-distribution
- `exploreFNIRS.coupling.mutualInfo()` — histogram-based mutual information
  - Captures both linear and nonlinear dependencies
  - Auto bin selection via Freedman-Diaconis rule, or fixed bin count
  - Normalized MI (NMI = MI / sqrt(H(x)*H(y))) to [0,1] by default
  - Block-shuffle surrogate p-values
  - Supports sliding window mode
- Both methods registered in `computeMatrix` and `computeDyad` dispatch
- `exploreFNIRS.coupling.plv()` — phase-locking value (Hilbert-phase synchrony); band-pass + a first-party FFT analytic signal, so it requires no Signal Processing Toolbox
- `exploreFNIRS.coupling.wpli()` — weighted phase-lag index; debiased-squared (default) and magnitude estimators, robust to zero-lag/volume-conduction (Vinck et al. 2011)
- `exploreFNIRS.coupling.imagCoherence()` — imaginary part of coherency; insensitive to zero-lag mixing (Nolte et al. 2004)
- `exploreFNIRS.coupling.surrogateTest()` — surrogate/permutation significance for any coupling metric, with autocorrelation-aware circular-shift and phase-randomization nulls
- PLV / wPLI / imaginary coherence registered in `computeDyad` dispatch

**Neural Efficiency Analysis:**
- `exploreFNIRS.core.plotNeuralEfficiency()` — scatter plot of brain activation vs behavioral performance
  - Both axes z-scored; identity line separates "efficient" from "inefficient" subjects
  - Per-group regression lines, Pearson/Spearman statistics, arrow annotations
  - Flexible axis mapping: FlipXY, InvertX, ZScoreMode (global/pergroup)
- `exploreFNIRS.core.plotNeuralEfficiencyFromTable()` — same plot from a pre-built table (for custom data)
- `exploreFNIRS.core.plotNeuralEfficiencyCore()` — shared rendering engine
- `Experiment.plotNeuralEfficiency()` — wrapper returning fig, stats, and per-point neTable
- `examples/scripts/example_neural_efficiency.m` — tutorial script

**FFT-Based Wavelet Transform:**
- `pf2_base.wavelet.cwt()` — batch FFT-based continuous wavelet transform (Morlet)
  - Single precision by default for faster FFTs; GPU-aware
  - Power-of-2 padding; vectorized scale computation (all Morlet kernels as [nfft x nScales] matrix)
  - No Wavelet Toolbox dependency
- `pf2_base.wavelet.wcoherence()` — license-free wavelet coherence using pre-computed CWTs
  - SmoothedAutoX/SmoothedAutoY params for batch mode (skip redundant auto-spectra smoothing)
  - FFT-based smoothing (not per-row convolution)
- `exploreFNIRS.coupling.wcoherence()` now delegates to `pf2_base.wavelet.wcoherence`
- `exploreFNIRS.connectivity.computeMatrix()` batch CWT path for wcoherence method: pre-computes smoothed auto-spectra once per channel, eliminating N-1 redundant smoothings
- `exploreFNIRS.hyperscanning.computeDyad()` batch CWT path with same optimization

**Parallel Acceleration:**
- `pf2_base.accel.canParfor()` pattern: returns [canUse, poolRunning] for auto mode
- `pf2_MotionCorrectTDDR` — parfor over channels (threshold: >8)
- `pf2_MotionCorrectSpline` — parfor over channels (threshold: >8)
- `processFNIRS2` cell array mode — parfor with ProcessingContext snapshot (threshold: >2 items)
- `exploreFNIRS.stats.fitLME` — parfor over channels (single-biomarker path, threshold: >4)
- `exploreFNIRS.hyperscanning.permutationTest` — parfor over permutations (threshold: >10)
- `exploreFNIRS.hyperscanning.computeGroup` — parfor over dyad computations (threshold: >2)
- `exploreFNIRS.graph.smallWorld` — parfor over random network rewirings (threshold: >10)
- `exploreFNIRS.core.Experiment` — parfor over subjects in `connectivity()` and `intraROI()` (threshold: >2)

**HB-ICA (Hyper-Brain Independent Component Analysis):**
- `exploreFNIRS.hyperscanning.hbica()` — component-based inter-brain network detection for hyperscanning data using TDSEP ICA and Goodness-of-Fit classification (Luo et al. 2024)
  - Concatenates dual-subject channel data, decomposes via TDSEP, classifies components as inter-brain or intra-brain using GOF index
  - Dual regression provides subject-specific sources and spatial maps
  - Supports all biomarkers, time windowing, channel selection, adjustable GOF threshold
- `pf2_base.signal.tdsep()` — Temporal Decorrelation Source Separation (Ziehe & Muller 1998)
  - PCA whitening, time-lagged covariance matrices, Jacobi joint diagonalization
  - Configurable lags, variance retention threshold, number of components
- `exploreFNIRS.coupling.hbica()` — pairwise coupling adapter for HB-ICA (API compatibility with dispatch system)
- `exploreFNIRS.hyperscanning.plotHBICA()` — visualization: GOF bar chart, dual-brain spatial patterns, source time courses
- `Experiment.hbica()` — group-level HB-ICA with automatic subject pairing, block-wise analysis, and summary statistics
- HB-ICA registered in coupling dispatch for `computeMatrix` and `computeDyad`
- `examples/scripts/example_hbica.m` — HB-ICA tutorial: standalone dyad, group-level, block-wise, and pairwise comparison

**Graph Theory Metrics (`+exploreFNIRS/+graph/`):**
- `threshold()` — connectivity matrix to graph struct (absolute, proportional, or significance-based thresholding)
- `degree()`, `charPathLength()`, `clusteringCoefficient()`, `betweenness()`, `efficiency()` — standard graph-theoretic metrics
- `modularity()` — Louvain community detection (Blondel et al. 2008), participation coefficient
- `smallWorld()` — sigma/omega small-world indices with Maslov-Sneppen null model rewiring
- `detectHubs()` — composite z-score hub classification (provincial vs connector hubs)
- `computeMetrics()` — convenience dispatcher for computing multiple metrics at once
- `plotNetwork()` — graph visualization with force-directed, circle, or probe-based layouts and community coloring
- `plotMetrics()` — grouped bar charts for comparing graph metrics across conditions
- `metricsToTable()` — long-format table export with optional CSV save
- `Experiment.graphMetrics()` — wrapper delegating to `connectivity()` + `computeMetrics()`

**Cluster-Based Permutation Testing:**
- `exploreFNIRS.stats.clusterPermutation()` — non-parametric cluster-based testing for LME results (Maris & Oostenveld 2007)
- `exploreFNIRS.stats.findClusters()` — BFS connected-component cluster identification on thresholded stat maps
- `pf2.probe.computeAdjacency()` — spatial adjacency matrix from MNI coordinates for cluster permutation
- `Experiment.statsClusterPermutation()` — wrapper for cluster-based permutation testing

**Channel Quality Check GUI:**
- `pf2.qc.ChannelCheck` — App Designer GUI for interactive channel quality assessment
  - Spatial probe mini-plot grid, detail waveform + PSD views, undo/redo, bulk operations
  - Auto-runs QC pipeline on open (saturation, SCI, cardiac, CoV, Takizawa)
  - Configurable QC thresholds with persistent preferences
  - Two modes: single dataset or cell array with prev/next navigation
  - Dark mode support; opt-in via `'ChannelCheckVersion', 2` on import functions

**Internal Refactoring:**
- `pf2_base.resolveMethodsLib()` / `pf2_base.storeMethodsLib()` — method library access abstracted from global PF2
- `global PF2` scoping reduced in processing stages and plot functions — explicit parameters replace global reads

**Pipeline Class Hierarchy:**
- `pf2_base.PipelineFunction` — immutable value class encapsulating a single processing function with precomputed argument mappings and zero-overhead `execute()` method
  - 12 special argument types (x, fs, fTime, fchMask, etc.) resolved at construction as uint8 enums
  - `fromStruct(s)` / `toStruct()` for legacy method struct round-tripping
  - `fromString(callStr)` for parsing MATLAB call syntax
  - `detect(funcName)` for auto-discovering function signatures from source
  - `register(pf)` for persisting to config file
  - `setParam()`, `setParams()`, `addArg()`, `removeArg()`, `addOutput()`, `removeOutput()` for mutation (returns new copy)
- `pf2_base.Pipeline` — ordered chain of PipelineFunction steps (value class)
  - `add()`, `insert()`, `remove()`, `swapStep()`, `setParam()`, `setParams()` for chain manipulation
  - `toMethod()` converts to legacy method struct for backward compatibility
  - `fromMethod(name, stage)` builds Pipeline from existing named method
  - `params()` returns aggregate table of all tunable parameters
- `pf2_base.RawPipeline` — Stage 1 specialization with `hasIntensity2OD()` helper
- `pf2_base.OxyPipeline` — Stage 3 specialization with `hasROI()`, `swapROI()`, `removeROI()` helpers
- `pf2_unpackMethod` now eagerly converts legacy structs to PipelineFunction via `fromStruct()` at unpack time — all callers receive PipelineFunction objects
- `processStageRaw2OD` and `processStageFilterHb` use PipelineFunction exclusively (silent fallback retained for safety)
- Tutorials:
  - `examples/scripts/example_pipeline_basics.m` — Pipeline API tutorial
  - `examples/scripts/example_pipeline_custom_function.m` — Custom function tutorial

**GLM Improvements:**
- `pf2_base.fnirs.diagnoseGLM()` — comprehensive GLM diagnostic report (collinearity, VIF, partial R², residual ACF, task-data correlation, predicted amplitude, automatic flagging)
- `fitGLM` AR-IRLS method now returns prewhitened design matrix (`Xw`) and prewhitened residuals (`residuals_w`); contrasts use prewhitened quantities for correct standard errors

**New Processing Functions:**
- `pf2_MotionCorrectSplineSG` — spline interpolation with Savitzky-Golay smoothing motion correction

**SNIRF Import Improvements:**
- Source and detector labels from SNIRF probe info now stored during import
- Per-optode S_D channel labels (e.g., "S1_D11") built with fallback to numeric format

**Interactive Setup Wizard:**
- `pf2_scripts.quickSetup` — interactive wizard for first-time users

### Config Changes
- `pf2_functions_default.cfg` reformatted and alphabetized
- Added `requiresOD` field to motion correction functions (TDDR, Wavelet, Spline, SplineSG, SMAR, SMAR2, MARA, kbWF, sSMART) — validated at runtime in processStageRaw2OD
- New function entries: `pf2_MotionCorrectSpline`, `pf2_MotionCorrectSplineSG`, `pf2_GSR`
- Global-signal-removal methods (`pf2_CAR`, `pf2_SSR`, `pf2_GSR`) registered through `+pf2/+methods/+oxy/setMethod.m` and `+pf2/+methods/+raw/setMethod.m`
- Removed bundled `devices/DrP_probe.cfg` (unreferenced)

### GUI Changes
- Method configuration GUI now converts between PipelineFunction and legacy struct for editing
- `requiresOD` added to reserved args in GUI

### New Tests
- **PipelineFunctionTest.m** — PipelineFunction construction, precomputed mapping, execute, round-trip
- **PipelineTest.m** — Pipeline hierarchy: add, insert, remove, setParam, toMethod, fromMethod
- **GLMDiagnosticsTest.m** — diagnoseGLM diagnostic output validation
- **HBICATest.m** — HB-ICA decomposition, inter/intra-brain detection, coupling adapter, ROI mode
- **TDSEPTest.m** — TDSEP mixing recovery, dimensionality reduction, reconstruction
- **GraphMetricsTest.m** — Graph theory metrics on known topologies (K5, star, ring, block-diagonal)
- **ClusterPermutationTest.m** — Adjacency computation, cluster finding, null distribution
- **GroupStatsIndependenceTest.m** — group GLM subject-level aggregation, mixed-montage channel-label alignment, nuisance-regressor exclusion
- **HyperscanningNullTest.m** — positive-metric null handling in `computeGroup`, per-element permutation denominator, `computeDyad` fs-mismatch rejection and timestamp alignment
- **BuildOptodeTableTest.m** — `buildOptodeTable` schema contract: expected columns, OptodeNum sorting, source/detector recovery (NaN when unmatched), geometry-column omission, short-separation derivation
- **PhaseSyncCouplingTest.m** — PLV / wPLI / imaginary coherence and `surrogateTest` (identical-signal PLV, zero-lag robustness, magnitude vs debiased-squared estimator, NaN/insufficient-data handling)
- **GLMEnhancementsTest.m** — FIR basis rank/singularity guard, single-gamma HRF, AR-order selection, and rank-deficient estimability (aliased coefficients/contrasts NaN, invariant under rescaling)
- **BeerLambertPPFTest.m** — PPF mode, case-insensitive DPFmode, PPF/PVC validation, and PVC extrapolation warning
- **StrangmanPVCTest.m** — Strangman partial-volume correction lookup and extrapolation behavior
- **ShortChannelRegressionODTest.m** — OD-space short-channel regression
- **ResultsTableExportTest.m** — `blockAvgToTable` / `glmToTable` schema, session preservation, channel-vector handling, TSV export, and headless-path guards

### GUI Refactoring
- `updateCurrentDevice` consolidated: GUI and headless paths now delegate to shared `pf2_base.gui.updateCurrentDevice`
- `updatePlots` extracted into per-stage helpers: `pf2_base.gui.plotStageRaw` (stages 1–2) and `pf2_base.gui.plotStageHb` (stages 3–4)
- `plotOxyArranged` / `plotRawArranged` consolidated into single `pf2_base.gui.plotArranged` helper
- `processStageOD2Hb` GUI wrapper now delegates to shared function with `BaselineSamples` option instead of calling `bvoxy` directly
- `processFNIR_GUI` inlined raw and filter-Hb wrappers — processing calls now use explicit parameters instead of reading globals inside wrapper functions
- `GUIContext` sync wired up via `syncContextFromGUI()` at the start of each processing cycle
- GUI processing calls now pass `showGUIerrors=true` so pipeline errors show as dialog boxes instead of crashing

### Improvements
- `Experiment.select()` now preserves the user-specified order of subjects/elements instead of sorting by index
- Bar charts support `ErrorColor` parameter for custom error bar coloring
- `pf2_MotionCorrectWavelet` uses WaveLab `FWT_TI`/`IWT_TI`/`DownDyadLo` instead of `dwt`/`idwt` (no Signal Processing Toolbox dependency)
- `calcCBSI` refactored with literature references (Cui et al. 2010)
- INI writer fix: correctly handles numeric array values in method config files

### Bug Fixes
- Fixed AR-IRLS contrast p-values being anti-conservative — contrasts now use prewhitened X and residuals instead of original-space quantities
- Fixed `pf2_unpackMethod` struct array output duplication — when INI-stored method definitions used `struct()` with cell array values, MATLAB creates a struct array; the old code iterated all elements to build the `output` field, producing e.g. `{'x','x','x','x','x'}` instead of `{'x'}`, which caused "Too many output arguments" errors when executing pipeline functions
- Fixed missing `data.markers` crash in GUI filter-Hb processing — `processStageFilterHb` accesses `data.markers` for the pipeline context, but the GUI's stage{4} data lacked `.markers`, `.Aux`, and `.time` fields
- Fixed `plotArranged` `LightColorAuto` validation error — parameter used `@islogical` validator but the GUI stores the value as numeric 0/1
- Fixed HB-ICA GOF computation — combined GOF was always zero for two-subject case due to symmetric z-score cancellation; now uses absolute loading ratios
- Fixed `clusterPermutation` permutation loop fitting the same formula (same dependent variable) for all channels instead of rewriting per channel
- Fixed `clusterPermutation` RNG seeded inside the inner channel loop instead of per permutation
- Fixed `plotHBICA` subplot layout — `subplot(nRows,1,1)` conflicted with `subplot(nRows,3,...)` destroying the GOF panel
- Fixed `ChannelCheck` QC tooltip referencing non-existent `pctSaturated` field instead of `totalPct`
- Fixed `ChannelCheck` ambient/marker/reference lines accumulating on mini-plots during repeated redraws
- Eliminated repeated "Converting legacy struct to PipelineFunction" warnings during processing — `pf2_unpackMethod` now converts structs to PipelineFunction objects at unpack time (single canonical conversion point); `processStageRaw2OD` and `processStageFilterHb` retain silent fallback only as a safety net; `pf2.methods.raw.create` and `pf2.methods.oxy.create` pass methods through `pf2_unpackMethod` before memory storage

**GLM & design matrix:**
- Fixed FIR-basis designs silently producing invalid inference — `buildDesignMatrix` skipped its rank/condition check in exactly the guaranteed-rank-deficient case (more FIR lag columns than time samples), and `fitGLM` reported negative degrees of freedom from a raw `T - P`. The condition-number check now always runs for FIR bases (`pf2:buildDesignMatrix:firNearSingular`), `fitGLM` uses the design's effective rank (`pf2:fitGLM:rankDeficient`), and rank-deficient fits return NaN t-stats/p-values instead of a nonsensical negative-dof test
- Fixed FIR designs silently ignoring event amplitude and duration — a non-default amplitude/duration under a FIR basis now warns `pf2:buildDesignMatrix:firIgnoresAmplitude` (FIR still models onset timing only)
- Fixed `fitGLM` erroring for `Method='OLS'` when an `AROrder` was supplied — AR order applies only to AR-IRLS; OLS now warns (`pf2:fitGLM:arOrderIgnored`) and ignores it. `AROrder` also accepts a string scalar
- Fixed `GLMExperiment.groupStats` treating every recording as an independent subject — multiple runs/sessions per participant inflated the subject count, degrees of freedom, and significance. Betas are now averaged within subject before the group-level test; subject identity resolves from `.info` (`SubjectID`/`participant_id`/…) with a `pf2:GLMExperiment:noSubjectID` warning and per-recording fallback when unavailable
- Fixed `GLMExperiment.groupStats` crashing on mixed montages — subjects with differing channel counts now align on a common channel-label axis (NaN-padded) instead of raising a dimension-mismatch error
- Fixed `GLMExperiment` promoting arbitrary nuisance regressors (drift, short-channel, aux/physio, motion, cardiac, respiration) to reported task conditions — condition auto-detection now excludes nuisance/aux/drift terms and anything declared in `glm.auxNuisance`

**Hemoglobin conversion:**
- Fixed case-sensitive `DPFmode` handling — the value was accepted case-insensitively at the front door but compared case-sensitively downstream, so e.g. `'ppf'` silently fell through to calculated DPF instead of selecting the PPF escape hatch. `DPFmode` is now canonicalized at every entry point (`processFNIRS2`, `processFNIRS2_GUI`) and compared case-insensitively in `processStageOD2Hb`
- Fixed `bvoxy` silently mishandling a malformed `PartialPathlengthFactor` — a vector longer than two elements was cut to its first two, and a NaN propagated into all HbO/HbR. PPF must now be scalar or exactly two finite positive values, else `pf2_base:fnirs:bvoxy:badPPF`
- Fixed automatic partial-volume correction (`PVC='auto'`) silently clamping short-separation channels to the Strangman model's 20 mm bound — out-of-range separations now warn `pf2_base:fnirs:processStageOD2Hb:pvcExtrapolated`, naming the affected channels
- Fixed the GUI `ODShortRegression` option being accepted but silently ignored — it now applies OD-space short-channel regression before Beer-Lambert, matching the headless `processFNIRS2` path

**Group coupling & hyperscanning:**
- Fixed invalid group significance for strictly-positive coupling metrics — `computeGroup` tested raw PLV / imaginary coherence / wPLI / (w)coherence against a zero null, but their finite-sample null is positive (independent noise produced spuriously significant "coupling"). These metrics no longer use the zero-null t-test; they require a surrogate/permutation null (else return NaN with `pf2:computeGroup:surrogateNullRequired`), and a new `result.nullTest` field records the path taken
- Fixed anti-conservative `permutationTest` p-values — per-element NaN surrogates were counted as non-exceedances while remaining in the denominator; exceedance count and denominator are now computed per element over the non-NaN surrogates
- Fixed `computeDyad` treating unaligned recordings as synchronized — it clipped each recording independently and trimmed to equal sample counts while tolerating small sampling-rate differences, so clock offset/drift became artificial phase lag or Granger direction. It now errors on an fs mismatch (`pf2:computeDyad:fsMismatch`, 0.1% tolerance) and interpolates both signals onto a shared time grid
- Fixed `coupling.surrogateTest` returning an all-NaN null when the signal contained any missing sample — the original signal was phase-randomized and FFT'd with NaNs in place; inputs are now NaN-filled before surrogate generation, matching the other coupling metrics
- Fixed `coupling.wpli` non-debiased output returning a signed ratio instead of magnitude wPLI, and mislabeling the debiased estimator — `Debiased=false` now returns magnitude wPLI in [0,1], and a `result.estimator` field records `'wpli'` vs `'debiased-squared-wpli'` (the default, an estimator of *squared* wPLI per Vinck et al. 2011)
- Fixed `coupling.granger` F-test subtracting an intercept degree of freedom that was never fit — the denominator dof now matches the actual model parameters

**Motion correction & GUI:**
- Fixed `pf2_MotionCorrectTDDR` returning an all-NaN channel for a constant / zero-variance segment — a zero robust spread made the Tukey biweight compute `0/0 = NaN` and poison the output; such segments now keep unit weights (there is nothing to repair)
- Fixed `processFNIRS2_GUI` returning empty captured output — the output function guarded on `isfield(PF2,'data')`, but processed data lives at `PF2.GUIPF2.data` (`PF2.data` is never set), so `out = processFNIRS2_GUI(...)` silently dropped the processed stages

**Import & device geometry:**
- Fixed `pf2.import.importNIRX` marking dark (no-wavelength) columns as valid measurement channels — `TableCh.isCh` now excludes `isDark` columns, matching the toolbox-wide convention (`importOxy3`, `loadDeviceCfg`), so dark columns are no longer fed into OD→Hb conversion, SCI, or DOT channel geometry
- Fixed `pf2_base.buildOptodeTable` returning `TableOpt` in input `ChannelList` order — it now sorts by `OptodeNum` to match `loadDeviceCfg`'s canonical schema, keeping per-channel geometry (SD, positions) aligned by channel number for downstream Beer-Lambert conversion; the source/detector lookup is also vectorized (was O(nCh²))

**Export:**
- Fixed `glmToTable` collapsing sessions for repeated-subject cohorts — session was reconstructed from a subject-only map, so two recordings for one participant in different sessions both exported under the last session; each recording's own session is now preserved
- Fixed headless export opening a GUI file picker when no output path was supplied — `asSNIRF`/`asNIR`/`asBIDS`/`asTensor` now raise a clear `pf2:export:<fn>:noPath[Root]Headless` error under `-batch` instead of a low-level dialog failure
- Added input validation to `blockAvgToTable` — out-of-range `Channels` or a malformed `TimeWindow` now error (`pf2:export:blockAvgToTable:badChannel` / `:badWindow`) instead of silently dropping data or hitting a raw indexing error
- Fixed `blockAvgToTable` crashing on a column-vector `Channels` (e.g. `[1;2]`) — the channel selection is normalized to a row so it iterates per element rather than as one vector-valued loop pass

**Review-driven hardening (stress-case edges):**
- `computeGroup` now also skips the invalid zero-null t-test for the remaining nonnegative metrics — Granger (F-statistic), mutual information, transfer entropy, and HB-ICA — not just the phase-synchrony metrics; all require a surrogate/permutation null
- Rank-deficient GLM estimability is now per-coefficient and per-contrast via a null-space test with a scale-invariant (dimensionless) tolerance, so aliased coefficients/contrasts are NaN'd correctly even when the design is rescaled; a non-estimable contrast's standard error is also NaN (previously only its t/p were)
- `fitGLM` bases the surrogate insufficient-data guard and `surrogateTest` on JOINTLY finite samples, so signals whose finite spans do not overlap are reported invalid instead of being interpolated into a spurious "significant" coupling
- Nuisance-regressor auto-detection is boundary-anchored consistently — legitimate conditions like `Emotion`, `Response`, and `GlobalLocal` are kept, while documented nuisance names (`motion`, `resp`/`respiration`, `accel`/`accelerometer`, `heart`/`heartrate`, `global`, drift bases) are still excluded
- `bvoxy` rejects a non-finite `PartialVolumeCorrection` (NaN/Inf) instead of producing all-NaN hemoglobin (`pf2_base:fnirs:bvoxy:pvcInvalid`); `dpfMode='None'` now ignores PVC with a warning rather than resolving `'auto'` (which needlessly required probe geometry)
- `wpli` accepts integer `NFFT` (odd or even) and uses `floor(nfft/2)+1` for the one-sided spectrum instead of crashing on odd values; a non-integer `NFFT` is rejected up front
- `plv` is now free of the Signal Processing Toolbox (first-party Butterworth filtering + an FFT-based analytic signal), so wPLI's "use PLV instead" toolbox-free recommendation is actually valid

### Breaking Changes
- **`GLMExperiment.groupStats` aggregates to one value per subject.** `n_subjects` and degrees of freedom for cohorts with multiple recordings per participant will change (previously inflated by counting each recording); `stats.channel`/`channel_label` now index a montage-union label axis when channel counts differ across subjects
- **Group coupling significance for positive-valued metrics is gated on a surrogate null.** `computeGroup` no longer reports vs-zero t-tests for PLV, imaginary coherence, wPLI, or (w)coherence; without a surrogate/permutation null these return NaN p-values with a `surrogateNullRequired` warning. Use `permutationTest` or `coupling.surrogateTest`
- **`computeDyad` errors on sampling-rate mismatch** beyond 0.1% (previously tolerated); aligned sample values may shift slightly because both signals are now interpolated onto a shared time grid
- **`coupling.wpli` with `Debiased=false` returns magnitude wPLI in [0,1]** (previously a signed ratio in [-1,1]); the default debiased output is documented as an estimator of *squared* wPLI and carries a `result.estimator` label
- **`coupling.granger` p-values shift marginally** (denominator degrees of freedom corrected)
- **`bvoxy` rejects a malformed `PartialPathlengthFactor`** (wrong length or non-finite) with `pf2_base:fnirs:bvoxy:badPPF` instead of silently truncating or propagating NaN
- **Headless export without an explicit path now errors** (`asSNIRF`/`asNIR`/`asBIDS`/`asTensor`) instead of opening a dialog; `asSNIRF({...})` without a path performs directory batch export (the earlier single-file save-dialog behavior is gone)
- **`pf2_base.fnirs.calcLocalCV` removed** — its logic lives as file-local subfunctions inside the SMAR functions; the standalone package function was unused
- **`permutationTest` p-values may increase** (become less significant) where a null distribution contained partial NaNs — the previous values were anti-conservative

---

## v1.0 (2026-02-11)
Scriptable Group Analysis, Connectivity, Hyperscanning, Statistics & Processing Optimizations

### API Changes

**Experiment method renames (breaking):**
- `plotInfoVar()` renamed to `plotInfoBar()` (clarifies it produces a bar chart)
- `plotScatter()` renamed to `plotInfoScatter()` (clarifies it plots info-vs-info)
- `plotScatterFNIRS()` renamed to `plotScatter()` (fNIRS is assumed in this toolbox)
- Underlying standalone function renamed: `+exploreFNIRS/+core/plotScatterFNIRS.m` -> `plotScatter.m`

### New Features

**GLM Analysis Pipeline:**
- **GLMExperiment class** (`+exploreFNIRS/+core/GLMExperiment.m`) — scriptable wrapper that extends Experiment for GLM-based analysis
  - Encapsulates processing, design matrix construction, first-level fitting, and beta packaging into `fit()`
  - Auto-invalidation: changing `glm.*` or `settings.rawMethod`/`oxyMethod` triggers refit on next `aggregate()`
  - Per-subject result inspection via `subjectResults` and `plotDesignMatrix()`
  - Block-level behavioral data (reactionTime, accuracy, etc.) aggregated onto beta segments
  - Auxiliary data GLM: fits GLM on Aux signals (e.g. heartRate) at their native sampling rate
  - `betaTable()` for direct export to R/Python (bypasses Experiment pipeline)
  - All inherited Experiment methods (plotBar, plotLME, plotTopoLME, connectivity, ROI, export) work on beta data
- `pf2.data.blocksToEvents()` — convert defineBlocks output to GLM event structs for buildDesignMatrix
- `pf2.data.betasToSegments()` — package first-level GLM betas into Experiment-compatible pseudo-segments for group analysis
- `buildDesignMatrix` amplitude support — `events.amplitude` field scales boxcar/impulse regressors for parametric modulation designs
- Tutorials:
  - `examples/scripts/example_glm_analysis.m` — GLMExperiment workflow from continuous recordings through group statistics, topographic LME, and export
  - `examples/scripts/example_glm_advanced.m` — manual step-by-step GLM pipeline with design matrix construction, per-subject fitting, first-level contrasts, and beta packaging

**exploreFNIRS Scriptable API:**
- **Experiment container class** (`+exploreFNIRS/+core/Experiment.m`) for fully scriptable group analysis without the GUI
  - `select()`, `groupby()`, `aggregate()` methods for data organization
  - Copy constructor: `ex2 = Experiment(ex)` copies data, settings, and hierarchy for branching analyses
  - `connectivity()` and `hyperscanning()` methods with block-wise support
  - `plotTemporal()`, `plotBar()`, `plotLME()`, `plotTopoLME()` wrappers
  - `plotExperimentTimeline()` — visualize time settings (baseline, task block, temporal/bar resample) as a diagram before aggregating
  - `plotAuxLME()`, `plotInfoLME()` for auxiliary and info variable LME visualization
  - `plotAuxScatter()` for info vs auxiliary signal scatter correlation
  - `statsFitLME()`, `statsRunContrasts()`, `statsSummarize()`, `statsROILME()` for statistics
  - `statsInfoLME()` for LME analysis on info/behavioral variables (no aggregate needed)
  - `statsAuxLME()` for LME analysis on auxiliary signal channels
  - `exportLong()`, `exportWide()` for data export (with `IncludeROI` option)
- **Headless plotting** (`+exploreFNIRS/+core/plotTemporal.m`, `plotBar.m`, `plotScatter.m`)
  - Publication-ready temporal, bar chart, and scatter plots without GUI
  - Channels and biomarkers are never averaged — each gets its own subplot
  - Default `Channels = []` plots all channels as separate subplots
  - Automatic subplot layout adapts to channel count, biomarker count, and `PlotBy` factor
  - When all three dimensions present (channels x biomarkers x PlotBy), separate figures per biomarker with auto-named save paths
  - `PlotBy` splits subplots by a groupby variable; `Legend` controls placement (`'last'`/`'first'`/`'all'`/`'none'`)
  - `ShowN` parameter to hide subject count (n=X) from bar labels and legend entries
  - `YLim`/`XLim` with shared axes across subplots; per-biomarker-row linking when HbO and HbR have different Y scales
  - Legend styled with white background and black text for consistent appearance across themes
  - plotBar uses column-preferred layout (bar subplots are taller than wide) and delegates to `barweb` for both flat and clustered bar modes
  - plotScatter stacks per-group correlation annotations vertically to avoid overlap
  - ROI support via `'ROIs'` parameter (indices, names, or `'all'`)
  - Configurable error bands (SEM/SD) and save options
- **Auxiliary data scatter** (`plotAuxScatter`) — scatter correlation of info variables vs auxiliary signal data with per-channel subplots and regression lines
- **Time bin expansion** — when `barBinSize` produces multiple time bins, each bin becomes a separate group in bar/scatter plots (e.g. "Young [0s]", "Young [10s]")
  - `expandGroupsByTime` utility function slices gbyGrandBarFlat and creates single-bin gbyGrand per group
  - `PlotProxy` auto-adds Time to X (bar) or Color (scatter) dimensions
  - `plotBar`, `plotAuxBar`, `plotScatter`, `plotAuxScatter` all support time expansion
  - `fitLME` auto-includes Time as categorical fixed effect when multiple bins exist
  - `taskEnd` parameter on `aggregate()` controls task window endpoint

**Connectivity Analysis:**
- **Connectivity module** (`+exploreFNIRS/+connectivity/`) with `computeMatrix`, `plotMatrix`, `plotBlockComparison`
- **Coupling functions** (`+exploreFNIRS/+coupling/`) — Pearson, Spearman, cross-correlation, coherence, wavelet coherence
- **Directed coupling** — Granger causality (AR model F-test), transfer entropy (histogram-based with surrogate p-values)
- **Dynamic FC** — `computeDynamicFC` (sliding-window connectivity), `detectStates` (k-means brain state detection)
- **ROI connectivity** — `computeIntraROI` (within-ROI coupling), `computeInterROI` (between-ROI coupling)
- **GLM-based connectivity:**
  - `computeBetaSeries` — beta-series correlation via LSA (single GLM) or LSS (per-trial GLM), with condition filtering and Pearson/Spearman options
  - `computePPI` — psychophysiological interaction analysis (gPPI) with contrast specification, multi-channel seed averaging, and optional Wiener deconvolution
  - Both produce output compatible with existing `plotMatrix`/`plotChord` visualization
  - GLMExperiment integration: `betaSeriesConnectivity()` and `ppi()` methods aggregate across subjects (Fisher z-transform for beta-series, one-sample t-test for PPI)
- **Visualization** — `plotWcoherence`, `plotWindowed`, `plotDirected` (matrix + circular), `plotDynamicFC` (with brain states), `plotChord` (chord diagram), `plotIntraROI` (bar/radar), `plotInterROI` (chord/matrix)
- Tutorial: `examples/scripts/example_glm_connectivity.m` — beta-series and PPI from single-subject through group analysis with ROIs

**Hyperscanning Analysis:**
- **Hyperscanning module** (`+exploreFNIRS/+hyperscanning/`) with `pairSubjects`, `computeDyad`, `computeGroup`, `permutationTest`, `plotGroup`
- **Advanced visualization** — `plotInterBrainTopo` (dual-brain topographic display), `plotDyadMatrix` (channels x dyads heatmap), `plotGroupTemporal` (time-resolved coupling with error bands)
- Block-wise hyperscanning with struct array results

**Statistical Analysis Module:**
- `exploreFNIRS.stats.fitLME` — Standalone channel-wise LME fitting (statistics only, no visualization)
  - Supports `'DataType','Aux'` with `'AuxField'` for auxiliary signal LME
  - Supports `'DataType','ROI'` for ROI-level LME (iterates ROIs instead of channels)
- `exploreFNIRS.stats.fitInfoLME` — LME fitting for info/behavioral variables (single model, no channel iteration)
- `exploreFNIRS.stats.runContrasts` — Post-hoc contrasts across channels with FDR correction (BH or adaptive two-step)
- `exploreFNIRS.stats.summarize` — Publication-ready summary tables (ANOVA, contrasts, coefficients, fit) with optional APA formatting
- `plotLME` — LME analysis with bar charts, ANOVA tables, contrasts, and topographic F-statistic maps
  - Supports `DataType='Aux'` with `AuxField` for auxiliary signal LME visualization
  - Supports `DataType='ROI'` for ROI-level LME (iterates ROIs instead of channels)
- `plotInfoLME` — LME analysis with bar chart for info/behavioral variables (single model, F-stat per ANOVA term)
  - Convenience wrappers: `ex.plotAuxLME('heartRate')`, `ex.plotInfoLME('reactionTime')`

**plotTopoLME — 3D brain topo of LME ANOVA F-statistics:**
- `exploreFNIRS.core.plotTopoLME` renders significant ANOVA F-statistics onto the 3D brain surface
- One subplot per model term (excluding Intercept); terms with no significant channels are omitted
- Non-significant channels are NaN-masked so they render as brain color (no misleading color)
- Supports `SigType`: `'p'` (uncorrected), `'q'` (FDR), `'q-twostep'` (adaptive FDR)
- Probe geometry sourced from grouped data (no `setF` global dependency)
- `ShowNonSig`, `CameraPosition` options; returns `results.sigMasks` logical matrix

**Brodmann Area Lookup:**
- `pf2.probe.nearestBrodmann()` — find nearest Brodmann areas for each channel in a probe
  - Accepts data struct or device config name string (e.g. `'fNIR_Devices_fNIR1000.cfg'`)
  - Uses volumetric Brodmann atlas (1mm MNI) for accurate spatial lookup
  - `'N'` parameter controls how many BAs per channel (default 3), `'MaxDistance'` filters by mm
  - Returns MATLAB table with Channel, BA, Name, Distance_mm columns
  - Device and atlas data cached with persistent variables for fast repeated calls

**Block Definition & Extraction:**
- `pf2.data.defineBlocks()` — convert markers to block struct array
- `pf2.data.extractBlocks()` — extract fNIRS segments by block definitions
- Positional API: `defineBlocks(data, [49,50], 30)` or name-value pairs

**Metadata Import:**
- `pf2.data.importInfo()` — import subject-level metadata from CSV/Excel into fNIRS `.info` fields
  - Match by single or multiple key columns (e.g. SubjectID, Session)
  - Handles char/string/categorical/numeric type mismatches transparently
  - Works with single struct or cell array of structs
  - `Overwrite` option to protect existing fields
- `pf2.data.importBlockInfo()` — import block-level metadata from CSV/Excel into block struct arrays
  - Positional mode (row order) or key-based matching
  - `MarkerCode` and `Condition` filters to target specific block types
  - Integrates with `defineBlocks` output; non-matching blocks pass through unchanged

**GLM & Short-Channel Regression:**
- `pf2_base.fnirs.buildDesignMatrix()` — construct GLM design matrices from markers
- `pf2_base.fnirs.fitGLM()` — fit general linear model to fNIRS data
- `pf2_base.fnirs.shortChannelRegression()` — regress out short-channel signals
- `functions/pf2_SSR.m` — short separation regression processing function

**Method CRUD Operations:**
- `pf2.methods.raw.create()` / `pf2.methods.oxy.create()` — create new methods programmatically
- `pf2.methods.raw.delete()` / `pf2.methods.oxy.delete()` — delete methods
- `pf2.methods.raw.editFunction()` / `removeFunction()` — modify method function chains
- `pf2.methods.raw.exportMethod()` / `importMethod()` — portable method sharing
- `pf2.methods.validateFunction()` — validate function compatibility

**New Processing Functions:**
- `pf2_bpf_iir.m` — Butterworth IIR bandpass filter (used by 22/34 FRESH teams)
- `pf2_MotionCorrectSpline.m` — Spline interpolation motion correction (Scholkmann 2010, adapted from HOMER3)
- `pf2_SCIRejection.m` — SCI-based channel rejection on raw intensity
- `pf2_base.fnirs.extractShortChannelPCs()` — PCA on short-separation channels for GLM regressors

**Quality Control Module:**
- `pf2.qc.sci()` — Scalp Coupling Index for channel quality assessment (Pollonini 2014)
- `pf2.qc.powerSpectrum()` — Power spectral density with physiological peak detection
- `pf2.qc.plotQuality()` — Unified QC visualization (SCI bar chart or PSD line plots)
- **QC Pipeline** (`pf2.qc.pipeline.*`) — Standalone, orchestrated channel quality assessment independent of the processing pipeline
  - `assess()` — runs configurable checks (saturation, SCI, cardiac peak, CoV, Takizawa) on raw data with lightweight internal processing
  - `apply()` — applies QC report to `fchMask` (AND-only, never promotes rejected channels), stores report for traceability
  - `report()` — prints formatted channel-by-channel summary with per-check values and rejection reasons
  - `plotReport()` — 4-panel visual dashboard (SCI bars, cardiac SNR bars, CoV bars, Takizawa rule heatmap)

**Wavelet Family Selection & Parallel Acceleration:**
- `pf2_base.wavelet.resolveWavelet()` maps user-friendly names (e.g. `'db4'`, `'sym8'`, `'coif3'`) to WaveLab850 QMF filters
- Supports all 7 WaveLab families: Haar, Daubechies, Symmlet, Coiflet, Beylkin, Vaidyanathan, Battle-Lemarie
- `pf2_MotionCorrectWavelet`, `waveClean`, `pf2_kbWF` — new `wavelet` and `accelerate` parameters
- `accelerate` (`'auto'`, `'parfor'`, `'none'`): uses `parfor` when parallel pool is running and nChannels > 8

**Advanced Visualization:**
- `plotTopo` — Group-level 2D topographic maps (single or per-group layout); auto-uses probe geometry from Device and excludes short-separation channels
- `plotHeatmap` — Channel × time heatmap with sortable channels, diverging colormap, and ROI support
- `plotComposite` — Multi-panel publication figures with tiledlayout and auto panel labels
- `plotScatter` — Scatter correlation of info/behavioral variables vs fNIRS biomarkers with per-channel subplots, ROI support, stacked annotations, and error bands
- `plotAux` — Headless temporal plots for auxiliary signal channels with automatic channel labels from `varNames`
- `plotInfoBar` — Bar charts for info/behavioral variables (no aggregate needed)
- `plotInfoScatter` — Scatter plots of info-vs-info variables with regression lines, error bands (`ErrorBand` parameter for 95% CI), and styled legends

**Plot Style Infrastructure:**
- `pf2_base.plot.PlotStyle` — Centralized style value class with publication/presentation presets
- `pf2_base.plot.createFigure` — Standardized figure creation with auto-Visible=off when SavePath set
- `pf2_base.plot.handleSave` — Standardized save-if-requested logic
- All existing plot functions retrofitted to use centralized style system

**Sample Experiment Data Generator:**
- `pf2.import.sampleData.experiment()` — synthetic multi-subject fNIRS experiment for testing and tutorials
  - 4 subjects (2 Young, 2 Older) with 6 task blocks each (Easy, Hard, Rest)
  - Event markers, auxiliary signals (heart rate, 3-axis accelerometer) with channel labels (`varNames`), and behavioral metadata (reaction time, accuracy)
  - 4 processing stages: `'raw'`, `'blocks'`, `'extracted'`, `'aligned'` (default)
  - Jittered onsets and shuffled block orders for realistic experimental design

**Tutorial Scripts:**
- `example_experiment_cli.m` — comprehensive Experiment class CLI usage covering group analysis, behavioral variables, multi-factor grouping, auxiliary signals, LME, ROI, and export workflows
- `example_import_blocks.m` — end-to-end workflow for importing metadata from CSV, defining blocks from markers, attaching per-trial behavioral data, extracting segments, and feeding into Experiment
- `tutorial_batch_workflow.m` — realistic multi-subject workflow: directory import with `importDirectory`, CSV metadata merge with `importInfo`, batch processing, block extraction, Experiment analysis with LME statistics, and batch SNIRF export back to a directory tree

**Batch Export:**
- `pf2.export.asSNIRF` and `pf2.export.asNIR` now accept cell arrays for batch export to a directory
  - `Dir1`–`Dir4` name-value params map `.info` field values to subdirectories (inverse of `importDirectory`)
  - `Prefix` param builds filenames from `.info` field values
  - `pf2.export.export()` supports batch mode with `'Format'` param for auto-detection
  - `pf2_base.buildExportPaths()` shared helper for path generation

**Other:**
- `pf2_base.normalizeMarkers()` — standardize marker codes across devices
- `pf2_base.applyLightTheme()` — consistent light theme for figures
- `+exploreFNIRS/+export/connectivityToTable.m` — export connectivity results as tables
- `+exploreFNIRS/+core/getGroupColors.m` — consistent group coloring across plots
- `+exploreFNIRS/+core/splitGroupsByFactor.m` — split grouped data by a factor for PlotBy layouts
- `pf2_base.external.suptitle` — figure super-title with automatic subplot spacing

**FRESH Benchmark Suite** (`tests/benchmarks/fresh/`):
- Reproduces the FRESH study (Yuecel et al. 2025, Communications Biology) within processFNIRS2

### Performance

**Voxel brain rendering — isosurface optimization:**
- `interpolateValues3D` voxel brain (`showVoxelBrain=true`) now uses `isosurface()` (marching cubes) instead of individual cube patches via `plotCube`
- Multi-depth normal sampling for vertex coloring prevents dark patches in sulci and ventricles
- Isosurface mesh cached via `setappdata` so animated mode and re-renders skip recomputation
- Channel data projection now works on voxel brain — color interpolation is applied to isosurface vertices when both `showVoxelBrain` and channel data are active
- `plotCube.m` unchanged (still used by `mni3d.m`)

**Context-based processing optimization:**
- `processFNIRS2()` skips `pf2_base.pf2_initialize()` when `'Context'` parameter is provided (no disk I/O)
- Context values copied to local PF2/setF for backward compatibility
- Enables parallel processing with isolated state per worker

**Memory-efficient probe storage:**
- Output stores `info.probename` reference instead of full `probeinfo` struct
- `loadProbeInfo()` reloads full probe data from cfg file when needed

### New Tests
- **WaveletResolveTest.m** — wavelet family resolution
- **ConnectivityTest.m** — coupling functions and matrix computation
- **BlockDefinitionTest.m** — marker-to-block conversion and extraction
- **GLMTest.m** — GLM design matrix and fitting
- **SSRTest.m** — short-channel regression
- **HierarchicalAverageTest.m** — hierarchical averaging validation
- **NormalizeMarkersTest.m** — marker normalization
- **SplitTest.m** — data splitting
- **NewMethodsTest.m** — IIR, spline, SCI rejection, short-channel PCA
- **QualityControlTest.m** — SCI and power spectrum QC
- **ProcessingContextTest.m** — context creation, validation, serialization
- **GoldenFileTest.m** — regression testing with golden reference files
- **testExperiment.m** — Experiment class integration
- **PlotStyleTest.m** — style infrastructure
- **VisualizationTest.m** — plotTopo, plotHeatmap, plotComposite
- **DirectedConnectivityTest.m** — Granger, transfer entropy, dynamic FC, directed/chord plots
- **IntraROITest.m** — intra/inter-ROI connectivity
- **HyperscanVisualizationTest.m** — hyperscanning visualization
- **AllPlotsSmokeTest.m** — smoke tests for all plot functions
- **StatsModuleTest.m** — stats.fitLME, runContrasts, summarize
- **QCPipelineTest.m** — assess, apply, report, and plotReport
- **MetadataImportTest.m** — importInfo and importBlockInfo with positional, key-based, and filtered matching

### Improvements
- **Auxiliary channel labels** — `Aux.varNames` field propagates through the full pipeline (split → resample → grand average → plot). Set `d.Aux.accelerometer.varNames = {'X','Y','Z'}` on input data and `plotAux` subplot titles automatically reflect them.
- **plotTopoLME layout overhaul** — colorbars are now manually positioned on separate axes to prevent overflow, with F-stat tick labels on the right side. Non-significant terms display as titled cells with centered "n.s." text. `PositionConstraint = 'innerposition'` on all axes prevents MATLAB auto-layout from overriding grid positions. Invisible border annotations prevent `exportgraphics` from cropping whitespace.
- **plotInfoScatter `ErrorBand` parameter** — draws a 95% confidence band around regression fit lines (per-group or overall)
- **Legend styling** — `plotTemporal` (channel grid mode), `plotInfoScatter`, and `renderTemporal` legends now use white background with black text. Subject count `(n=N)` is hidden when N=1 to reduce visual clutter.
- **Bar chart overhaul** — flat and clustered bar charts now both use `barweb` for consistency with the GUI
  - `PlotBy` parameter for clustered bar charts (e.g. `'PlotBy', 'Condition'` groups bars by condition within each X-axis category)
  - `GroupByVars` parameter auto-labels x-axis with factor names (e.g. "Group x Condition")
  - Per-bar coloring with colored-patch legends for flat bars
  - X-axis margin so bars don't touch y-axis borders
  - xlabel restricted to bottom row in multi-row layouts to prevent inter-row overlap
- **plotInfoBar converted to barweb** — consistent styling with plotBar (per-bar colors, x-axis labels, patch-based legends)
- **suptitle replaces sgtitle** across all headless plot functions — `suptitle` auto-rescales subplot positions to prevent title/subplot overlap on save. Affected: `plotBar`, `plotTemporal`, `plotAux`, `plotLME`, `plotScatter`, `plotTopo`, `plotTopoLME`, `PlotProxy`, `plotQuality`, `plotReport`, `addProcessingInfoTitle`
- **plotLME** — figure title now shows full model formula (e.g. `biom ~ Condition + (1 | SubjectID)`), matching `plotTopoLME`; Intercept term restored as a column in the bar chart
- **SNIRF import** — supports BIDS `events.tsv` sidecar loading, 4-column markers (amplitude), `dataTypeLabel` inference, m/cm/mm length units
- **SNIRF export** — `MeasurementDate` and `MeasurementTime` now written from `info` fields or derived from `UnixTime` when `.t0` is not available
- **Processing function headers** — standardized documentation for TDDR, wavelet, Takizawa, MARA
- **Line ending cleanup** — `bpf.m`, `lpf.m`, `pf2_bpf_fir.m` reformatted to readable multi-line format
- `buildProcessingInfo` accepts Context parameter, reads values directly without global access
- Method fallback uses Context libraries when available

**3D visualization camera angles:**
- `interpolateValues3D` `initCamPosition` expanded with diagonal and corner views: `'bottom'`, `'top-left'`, `'top-right'`, `'top-front'`, `'top-back'`, `'front-left'`, `'front-right'`, `'back-left'`, `'back-right'`

### Config Changes
- `pf2_functions_default.cfg` updated: wavelet functions now include `wavelet` and `accelerate` parameters

### Bug Fixes
- Fixed `pf2_unpackMethod` S# extraction always failing — `strcmp(string, cellArray)` returns a logical array, and `if(logicalArray)` requires ALL elements true, so the S# → `.F` conversion never executed. Replaced with `isfield`. This bug was dormant in the normal GUI workflow (the GUI unpacked methods before `pf2_unpackMethod` saw them), but broke any code path calling `pf2_unpackMethod` on raw INI data (Pipeline API, ProcessingContext). Consolidated three duplicate S# extraction implementations (GUI `unpackMethods`, raw `unpackMethodsLocal`, oxy `unpackMethodsLocal`) to delegate to the single fixed `pf2_unpackMethod`.
- Fixed SNIRF import marker corruption — when SNIRF stimulus groups had names and 4+ data columns (e.g., amplitude), the stim name string was concatenated onto the numeric marker array, causing MATLAB to silently convert the entire marker matrix to `char`. This broke all downstream marker-dependent functions (`defineBlocks`, `extractBlocks`, `setT0`). Marker names are now discarded during import since the marker code in column 2 already encodes the stimulus identity.
- Fixed Aux metadata fields (`varNames`, `unit`) being flattened into separate aux fields (e.g. `accelerometer_varNames`) that caused `grandAvgFNIRS` to error on cell array data. These fields are now skipped during flatten and `varNames` values are used as table column names instead.
- Fixed `barweb` scatter data points leaking into legends as "data1", "data2" entries (`HandleVisibility` set to `'off'`)
- Fixed `grandAvgFNIRS.m` crash when data lacks segmentTimes field
- Fixed `plotTemporal.m` shadowing MATLAB builtins (`upper`/`lower` renamed to `upperBound`/`lowerBound`)
- Fixed `bvoxy_basic` size mismatch crash — `channels` arg was `1:T` instead of `[1,1]`, and DPF was incorrectly passed as `baselineSamples` positional arg
- Fixed `pf2.data.resample` operator precedence bug in Aux time detection — `all(diff(col>0))` was comparing before differencing, causing monotonic time fallback to always fail
- Fixed `pf2.data.resample` allowing `segmentLength=0` which caused division by zero
- Fixed `pf2.data.resample` potential uninitialized `validCh`/`validCh_roi` when baseline loop skips all biomarker fields
- Cleaned up `pf2.data.resample` — removed unused variable allocations and commented-out code
- Fixed `aggregate()` passing NaN resample size to `grandAvgFNIRS` when `barBinSize=0` — single-point segments produce empty time vectors, breaking LME and scatter plots
- Fixed `expandGroupsByTime` not slicing ROI data from `gbyGrandBarFlat` when expanding time bins

---

## v0.9 (2026-01-23)
API Standardization, Testing Infrastructure & Context-Based Processing

### New Features
- **ProcessingContext class** for isolated, reproducible processing
  - Encapsulates all processing settings (DPF, baseline, methods, device)
  - Enables parallel processing with different settings per worker
  - Supports serialization via `toStruct()`/`fromStruct()` for saving analysis settings
  - Pass via `processFNIRS2(data, 'Context', ctx)` parameter
- **processingInfo in output data** - Processed data now includes `fNIR.processingInfo` struct
  - Stores all processing settings used (DPF mode/value, baseline, methods, device)
  - Enables reproducibility by documenting exactly how data was processed
  - Plots automatically display device name, method, and DPF settings in figure title
- **Improved plotting functions** (`pf2.data.plot.oxy`, `raw`, `roi`, `auxData`)
  - Hybrid argument pattern: positional for common args, name-value for options
  - Auto-generated figure titles from processingInfo (e.g., "fNIR2000C | x5_TDDR | DPF(age=25)")
  - Added `interactive` parameter to control GUI prompts for headless/batch processing
  - Added save functionality: `savePath`, `saveWidth`, `saveHeight`, `saveDPI` parameters
  - Input validation with clear error messages
- **Improved probe plotting functions** (all `pf2.probe.plot.*` functions)
  - Added save parameters to all visualization functions:
    - `arrangedValues`, `imageValues`, `imageROIvalues`
    - `interpolateValues`, `interpolateROIvalues`, `interpolateValues3D`
  - Supports .png, .pdf, .fig, .svg, .eps, .tif, .jpg output formats
  - Configurable output dimensions and resolution
- **New helper function**: `pf2_base.plot.saveFigure` for centralized figure saving
- **Bug fixes in probe plots**:
  - Fixed `imageROIvalues.m` inverted error check that blocked valid data
  - Fixed `roi.m` incorrect fchMask reference (was using channel mask instead of ROI mask)
- **Refactored `auxData.m`**: Full refactor to use inputParser with hybrid argument pattern
- Moved `processStageOD2Hb` to external function `pf2_base.fnirs.processStageOD2Hb`

### Breaking Changes
- **camelCase API migration**: All public API functions now use camelCase naming convention
  - `pf2.Import.*` → `pf2.import.*`
  - `pf2.Export.*` → `pf2.export.*`
  - `pf2.Data.*` → `pf2.data.*`
  - `pf2.Process.*` → `pf2.process.*`
  - `pf2.Methods.*` → `pf2.methods.*`
  - `pf2.Settings.*` → `pf2.settings.*`
  - `pf2.Probe.*` → `pf2.probe.*`

### New Features
- Added comprehensive unit testing infrastructure using MATLAB's unittest framework
- Added integration tests for full processing pipeline validation
- Added synthetic fNIRS data generators with configurable physiological and artifact components
- Added quick validation scripts for rapid sanity checking

### Testing Infrastructure

**Test Runners:**
- `pf2_base.tests.runAllTests()` - Run complete test suite
- `pf2_base.tests.runQuickTests()` - Run fast validation tests

**Unit Tests:**
- `ImportNIRTest` - NIR file import validation
- `DataStructureTest` - fNIRS struct invariant validation
- `SignalProcessingTest` - Filter function testing
- `DataManipulationTest` - Resample, concatenate, split operations
- `BeerLambertTest` - Beer-Lambert conversion (bvoxy, Intensity2OD)
- `TDDRTest` - TDDR motion correction algorithm
- `ROIDefinitionTest` - ROI definition and configuration
- `ROIBuildingTest` - ROI aggregation (nanmean, PCA)
- `ExportTest` - NIR and SNIRF export functions
- `FDRTest` - FDR statistical correction (Benjamini-Hochberg, two-step)
- `MethodConfigTest` - Processing method configuration
- `AuxDataTest` - Auxiliary data handling
- `ProcessingContextTest` - Context class creation, validation, serialization
- `ProcessStageOD2HbTest` - Beer-Lambert conversion stage testing

**Integration Tests:**
- `FullPipelineTest` - End-to-end processing pipeline tests
- `RoundtripTest` - SNIRF import/export roundtrip validation
- `ProcessingContextIntegrationTest` - Context isolation, parallel processing simulation

**Synthetic Data Generators:**
- `generateFNIRS` - Realistic raw fNIRS data with HRF, cardiac, respiratory signals
- `generateHemoglobin` - Synthetic HbO/HbR concentration data
- `generateNoise` - White, pink, and brown noise generation
- `generateArtifacts` - Motion artifact generation (spikes, steps, drift)
- `generatePhysiological` - Cardiac and respiratory signal generation

**Documentation:**
- Added `testing_plan.md` - Comprehensive testing strategy document
- Added `golden/README.md` - Golden file infrastructure documentation

### Bug Fixes
- Fixed SNIRF import optode reindexing crash when optode numbers exceed array dimensions
- Fixed SNIRF import channel mapping loop iterating over wrong count (numOpt vs numCh)

## v0.8.1 (2026-01-23)
Documentation & SNIRF Improvements

- Added detailed function headers across import, export, data manipulation, plotting, and methods configuration modules
- Added `pf2.data.concatenateHorizontal` for joining fNIRS segments side-by-side with probe geometry merging
- Added `exploreFNIRS.versInfo` for version tracking
- Fixed `pf2.data.resample` to skip missing fields gracefully
- Fixed SNIRF import to use stable sort for consistent channel ordering
- Fixed SNIRF export to handle NaN wavelengths correctly
- Improved probe layout ordering to prefer source/detector index
- Fixed channel filter to determine channels in advance during processing
- Fixed probe check GUI
- Fixed help file to reflect moved export functions
- Fixed "strip extra raw" functionality
- Renamed `Concatonate` to `Concatenate` and `ConcatonateHorizontal` to `ConcatenateHorizontal`

## v0.8a (2024)
SNIRF Support & Visualization Enhancements

- Added SNIRF format import and export with embedded probe information and short separation channel handling
- Added `pf2.export.asNIR` to export fNIRS structs back to .nir file format
- Added violin plot support in exploreFNIRS bar charts with kernel density estimation
- Added IQR and IQR-without-outliers options for error bar display
- Added non-ordinal optode support (channels no longer require sequential optode numbering)
- Added datetime support in `pf2.data.setT0`
- `pf2.data.split` now properly splits and flattens auxiliary data channels
- 3D interpolation plots filter short separation channels by default
- Fixed scatter plots displaying flipped orientation
- Fixed barchart plotting with model indices
- Fixed temporal ROI plotting
- Fixed export for long and wide table formats
- Fixed channel ordering after Beer-Lambert conversion
- Fixed crash when markers are missing
- Fixed crash with mismatched channel numbers
- Fixed t0 calculation from datetime/unix timestamps
- Fixed marker sorting on SNIRF import
- Fixed probe check GUI in auto mode
- Fixed errorbar means calculation
- Fixed autocontrast indexing

## v0.7a (2022-07-05)
3D Visualization & Multi-Probe Support

- Migrated 3D visualization to MNI coordinates for standardized brain mapping
- Added Brodmann area plotting, labeling, and legend support on 3D brain models
- Added ability to plot and concatenate data from multiple probes
- Added 10-20 EEG probe plotting and ability to overlay EEG/fNIRS data
- Added voxel-based brain visualization mode
- Moved temporal, scatter, and barchart plotting to standalone functions in `exploreFNIRS.plot`
- Added Aux channel support in temporal, scatter, and barchart plots
- exploreFNIRS now handles categorical values in grouping and analysis
- Enhanced regex pattern matching for marker extraction
- Faster Hitachi import with datetime extraction
- Added datetime/duration field support and recursive struct/table resampling
- Fixed autocontrast sorting and indexing
- Fixed LME model failures with categorical types
- Fixed vline support for datetime/duration axes
- Fixed interpolate values chart orientation
- Fixed grandavg for auxiliary data with time integration
- Fixed suptitle spacing issues
- Fixed ICA clean and wavelet clean functionality

## v0.6a (2021-10-29)
Processing Pipeline Consolidation

- Merged GUI and non-GUI processing pipelines into external functions
- Created `plot_arranged` function for unified arranged plotting
- Restored classic oxy and raw plot functionality
- Added OptTable support for plotting functions
- Changed Oxy and Raw plot functions to varargin structure
- Added multiprobe plotting for Raw method
- Concatenate function improvements (saves more fields, retains markers)
- ICA clean fixes and fastica/runica configuration option
- Updated help documentation to pf2 format
- Fixed SkipOD functionality and header saving in importNIR
- GetMarkers now supports table marker types and asymmetric patterns

## v0.5a (2020-07-22)
3D Visualization Foundation

- Added InterpolateValues3D for brain surface visualization
- Added multiprobe plotting support
- Added custom colorbars and transparency controls
- Added 10-20 EEG probe plotting capability
- Added fNIR2000 sample data
- Added short separation channel visualization
- Hitachi ETG-4000 configuration updates with 3D positions
- Renamed processFNIRS2 wrapper to pf2

## v0.4a (2019-07-22)
Motion Correction & Statistics

- Added FastICA and Wavelab libraries
- Added Homer-style wavelet motion correction (Molavi)
- Added buildHRF function for hemodynamic response modeling
- Improved SMAR and SMAR2 motion correction algorithms
- Added piecewise and interpolation as NaN alternatives for filtering
- TDDR improvements
- FDR correction implementation
- ANOVA as primary LME measure in exploreFNIRS
- Save/load functionality in exploreFNIRS
- NIRx import improvements
- Baseline period improvements

## v0.3a (2019-06-22)
ROI & Visualization

- ROI support and reorganization complete
- Plot Oxy and Plot Raw functionality complete
- Added plotROI function
- Added Interpolate ROI values
- Added image values and image ROI values visualization
- Channel mask GUI editing
- Short separation channel filtering option
- Rejection level configuration
- Version number display in GUIs
- Added ability to describe methods
- List current method and method output functions

## v0.2a (2019-06-12)
Package Migration

- Migrated codebase to MATLAB package format (`+pf2`, `+pf2_base`)
- ConfigureMethods autoload default functions
- Added functionality to autoload channel rejection if present
- Fixed subtractambientlight values
- Added settings functions
- Modified exploreFNIRS to check for default root path

## v0.1a (2019-06-06)
Initial Release

- Initial commit and codebase reorganization
- Created README
- Added auto addpath functionality
- Basic exploreFNIRS with multi-biomarker LME support
- Automatic demographic loading in importNIR
- Updated ImportNIR for COBI format and space-delimited files
