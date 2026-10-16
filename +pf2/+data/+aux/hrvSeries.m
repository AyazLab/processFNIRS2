function [series, t] = hrvSeries(signal, fs, varargin)
% HRVSERIES Time-resolved HRV metrics via a sliding window over a waveform
%
% Computes standard HRV metrics in successive overlapping windows of a PPG
% or EKG waveform, returning a continuous time series instead of a single
% scalar summary. Each window's metrics are placed at the window's mid-point
% time, producing a sparse but time-resolved representation that can be stored
% as a typed auxiliary signal and aligned to the fNIRS grid with
% pf2.data.auxOnGrid. This is the natural next step after pf2.data.aux.hrvFeatures
% for users who need HRV as a psychophysiological modulator or GLM regressor
% (e.g. PPI analyses, cardiac-arousal covariates, epoch-by-epoch quality checks).
%
% References:
%   Task Force of the European Society of Cardiology and the North American
%   Society of Pacing and Electrophysiology (1996). Heart rate variability:
%   standards of measurement, physiological interpretation, and clinical use.
%   Circulation, 93(5), 1043-1065. DOI: 10.1161/01.CIR.93.5.1043
%
%   Shaffer, F., & Ginsberg, J. P. (2017). An Overview of Heart Rate
%   Variability Metrics and Norms. Frontiers in Public Health, 5.
%   DOI: 10.3389/fpubh.2017.00258
%
% Syntax:
%   [series, t] = pf2.data.aux.hrvSeries(signal, fs)
%   [series, t] = pf2.data.aux.hrvSeries(signal, fs, 'Name', Value)
%
% Inputs:
%   signal - Raw PPG or EKG waveform [N x 1] at sampling rate fs.
%            Must be a numeric column (or row) vector. NaN samples are
%            treated as missing and are not interpolated across during beat
%            detection.
%   fs     - Sampling rate in Hz [positive scalar].
%
% Name-Value Parameters:
%   'Window'    - Analysis window length in seconds (default: 60).
%                 Shorter windows reduce frequency-domain reliability; the
%                 Task Force guidelines recommend >= 5 min for full LF/HF
%                 estimates and >= 2 min for reliable time-domain metrics.
%                 Windows with fewer than 'MinBeats' detected beats produce
%                 NaN for all metrics.
%   'Step'      - Advance between successive windows in seconds (default: 5).
%                 Mutually exclusive with 'Overlap'. With Step = Window the
%                 windows are non-overlapping.
%   'Overlap'   - Fractional overlap in [0, 1); sets Step = Window*(1-Overlap).
%                 Mutually exclusive with 'Step'. Mirrors the convention in
%                 pf2.data.slidingWindows.
%   'Metric'    - Metric(s) to include in the output, specified as a string
%                 or cellstr drawn from: 'meanHR', 'meanNN', 'SDNN', 'RMSSD',
%                 'pNN50', 'LF', 'HF', 'LFHF' (default: all eight).
%                 Use a cell array to select a subset, e.g. {'RMSSD','LF','HF'}.
%   'MinBeats'  - Minimum number of detected beats required in a window for
%                 that window's metrics to be non-NaN. Windows below this
%                 threshold return NaN for every metric, consistent with the
%                 gating in pf2.data.aux.hrvFeatures. Default scales with the
%                 window length (~0.33 beats/s, i.e. 20 beats for the default
%                 60 s window, floored at 6) so short windows are not silently
%                 NaN-gated by a fixed 60 s-tuned threshold. Pass an explicit
%                 value to override the scaling.
%   'Band'      - Cardiac band-pass [loHz hiHz] forwarded to beat detection
%                 (default: [0.5 5]).
%   'LFBand'    - Low-frequency HRV band in Hz (default: [0.04 0.15]).
%   'HFBand'    - High-frequency HRV band in Hz (default: [0.15 0.40]).
%   'ResampleFs'- Tachogram resampling rate for spectral HRV (default: 4 Hz).
%
% Outputs:
%   series - Struct with one field per requested metric, each a [W x 1]
%            column vector of windowed estimates (NaN where a window had
%            insufficient beats). Units and field names match those returned
%            by pf2.data.aux.hrvFeatures:
%              .meanHR  - mean heart rate (bpm)
%              .meanNN  - mean NN interval (ms)
%              .SDNN    - SD of NN intervals (ms)
%              .RMSSD   - root mean square of successive NN differences (ms)
%              .pNN50   - % of successive differences > 50 ms
%              .LF      - low-frequency power (ms^2)
%              .HF      - high-frequency power (ms^2)
%              .LFHF    - LF/HF ratio
%            Additionally contains:
%              .time    - [W x 1] window centre times in seconds
%              .units   - Struct of unit strings, one per metric field
%              .metrics - Cellstr of metric field names actually present
%   t      - [W x 1] window centre times in seconds (identical to series.time).
%
% Algorithm:
%   1. Parse and validate inputs; resolve Step from Overlap if needed.
%   2. Build window start/end pairs covering the full signal at the chosen step.
%   3. For each window, extract the corresponding waveform slice and call
%      pf2.data.aux.hrvFeatures, which handles beat detection and all HRV math.
%   4. Gate on MinBeats: windows with fewer detected beats receive NaN for
%      every requested metric.
%   5. Assemble per-metric vectors and annotate with units and time.
%
% Example:
%   % Basic usage: 60 s window, 5 s step, all metrics
%   data   = pf2.import.sampleData();
%   proc   = processFNIRS2(data);
%   ppg    = proc.Aux.ppg.data;
%   ppgFs  = proc.Aux.ppg.fs;
%   [series, t] = pf2.data.aux.hrvSeries(ppg, ppgFs);
%   plot(t, series.RMSSD);
%   xlabel('Time (s)'); ylabel('RMSSD (ms)');
%
%   % Fast step, RMSSD only (common PPI modulator)
%   series = pf2.data.aux.hrvSeries(ppg, ppgFs, 'Window', 60, 'Step', 2, ...
%       'Metric', {'RMSSD'});
%
%   % Store as typed Aux signal and align onto the fNIRS grid
%   proc = pf2.data.aux.addFeature(proc, 'hrvRMSSD', series.RMSSD, ...
%       'Time', series.time, 'Unit', 'ms');
%   rmssdOnGrid = pf2.data.auxOnGrid(proc, 'hrvRMSSD');
%
% Notes:
%   - Overlapping windows are not statistically independent; high overlap
%     inflates the effective sample size for downstream parametric tests.
%   - Frequency-domain metrics (LF, HF, LFHF) require the window to be long
%     enough to resolve the LF lower edge (~1/0.04 Hz = 25 s minimum, but the
%     default 60 s is strongly recommended). They return NaN for shorter windows
%     even when MinBeats is met.
%   - This function calls pf2.data.aux.hrvFeatures on each window slice; it
%     does not duplicate the RR or metric math. Beat detection is therefore
%     fully consistent with the scalar-HRV path.
%   - The time axis is in seconds from the start of the signal (t = 0 at the
%     first sample). If the fNIRS proc struct has an absolute time base, add
%     proc.time(1) to series.time before calling addFeature.
%   - For very short recordings (< Window), hrvSeries returns an empty series
%     (W = 0) with all numeric fields as 0x1 doubles and a warning, rather
%     than erroring, so batch pipelines remain robust.
%
% See also: pf2.data.aux.hrvFeatures, pf2.data.aux.heartRateFrom,
%           pf2.data.aux.addFeature, pf2.data.auxOnGrid,
%           pf2.data.slidingWindows

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
signal = pf2_base.args.check(signal, '', '', {@mustBeNumeric, @mustBeNonempty}, 'Invalid argument at position 1.');
fs = pf2_base.args.check(fs, '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}, 'Invalid argument at position 2.');
opts = pf2_base.args.parse('hrvSeries', varargin, {}, {
    'Window',     (60), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}
    'Step',       ([]), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}
    'Overlap',    ([]), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty}
    'Metric',     ('all'), '', '', {}
    'MinBeats',   ([]), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty}
    'Band',       ([0.5 5]), '', '', {@mustBeNumeric}
    'LFBand',     ([0.04 0.15]), '', '', {@mustBeNumeric}
    'HFBand',     ([0.15 0.40]), '', '', {@mustBeNumeric}
    'ResampleFs', (4), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}
    });

winLen   = opts.Window;
if isempty(opts.MinBeats)
    % Scale the beat-count gate to the window length (~0.33 beats/s, i.e. 20
    % beats for the default 60 s window, floored at 6) so short windows are not
    % silently NaN-gated by a fixed 60 s-tuned threshold.
    minBeats = max(6, round(winLen / 3));
else
    minBeats = opts.MinBeats;
end

% --- Resolve Step from Step / Overlap (mutually exclusive) ----------------
if ~isempty(opts.Step) && ~isempty(opts.Overlap)
    error('pf2:hrvSeries:stepAndOverlap', ...
        'Specify only one of ''Step'' or ''Overlap'', not both.');
end
if ~isempty(opts.Overlap)
    step = winLen * (1 - opts.Overlap);
elseif ~isempty(opts.Step)
    step = opts.Step;
else
    step = 5;   % default 5 s step
end

% --- Resolve metric list --------------------------------------------------
allMetrics = {'meanHR', 'meanNN', 'SDNN', 'RMSSD', 'pNN50', 'LF', 'HF', 'LFHF'};
metricUnits = struct('meanHR','bpm','meanNN','ms','SDNN','ms','RMSSD','ms', ...
    'pNN50','%','LF','ms^2','HF','ms^2','LFHF','ratio');

metricArg = opts.Metric;
if ischar(metricArg) || isstring(metricArg)
    if strcmpi(char(string(metricArg)), 'all')
        metrics = allMetrics;
    else
        metrics = {char(string(metricArg))};
    end
else
    metrics = cellstr(metricArg);
end
% Validate every requested metric name
for mi = 1:numel(metrics)
    if ~ismember(metrics{mi}, allMetrics)
        error('pf2:hrvSeries:badMetric', ...
            '"%s" is not a recognized HRV metric. Valid names: %s.', ...
            metrics{mi}, strjoin(allMetrics, ', '));
    end
end

% --- Prepare signal -------------------------------------------------------
signal = signal(:);
N      = numel(signal);
tSig   = (0:N-1)' / fs;   % time axis in seconds, t=0 at first sample
recLen = tSig(end);

% --- Handle recordings shorter than one full window -----------------------
if recLen < winLen
    warning('pf2:hrvSeries:recordTooShort', ...
        ['Signal duration (%.1f s) is shorter than the requested window ' ...
         '(%.1f s). Returning an empty series.'], recLen, winLen);
    series = emptySeriesStruct(metrics, metricUnits);
    t = zeros(0, 1);
    return;
end

% --- Build window start times ---------------------------------------------
% Small floating-point tolerance so the final full window is always included.
% Relative to the window/step magnitude (not a tiny fixed fraction of step) so
% that very small steps still admit the final window despite round-off.
tol = max(winLen, step) * 1e-6;
starts = (0 : step : recLen - winLen + tol)';
nWin   = numel(starts);

% --- Allocate output arrays -----------------------------------------------
data_out = nan(nWin, numel(metrics));

% --- Sliding window loop --------------------------------------------------
for wi = 1:nWin
    tStart = starts(wi);
    tEnd   = tStart + winLen;

    % Sample mask for this window
    mask = tSig >= tStart & tSig < tEnd;
    slice = signal(mask);

    % Skip windows that are entirely NaN or too short to detect beats
    if all(isnan(slice)) || isempty(slice)
        continue;
    end

    % Delegate all beat detection and HRV math to hrvFeatures
    try
        [hrv, info] = pf2.data.aux.hrvFeatures(slice, fs, ...
            'Band',       opts.Band, ...
            'LFBand',     opts.LFBand, ...
            'HFBand',     opts.HFBand, ...
            'ResampleFs', opts.ResampleFs);
    catch
        % Any error in a single window (e.g. degenerate slice) -> NaN row
        continue;
    end

    % Gate on MinBeats
    if info.nBeats < minBeats
        continue;
    end

    % Copy requested metrics into the row
    for mi = 1:numel(metrics)
        data_out(wi, mi) = hrv.(metrics{mi});
    end
end

% --- Assemble output struct -----------------------------------------------
t = starts + winLen / 2;   % window centre times
series = struct();
series.time = t;
for mi = 1:numel(metrics)
    series.(metrics{mi}) = data_out(:, mi);
end
units = struct();
for mi = 1:numel(metrics)
    units.(metrics{mi}) = metricUnits.(metrics{mi});
end
series.units   = units;
series.metrics = metrics;

end

%%_Subfunctions_________________________________________________________

function s = emptySeriesStruct(metrics, metricUnits)
% EMPTYSERIESSTRUCT Build an empty (0-window) series struct with correct fields
%   Returns a struct with all metric fields as 0x1 doubles plus metadata,
%   used when the recording is shorter than one window.
s = struct();
s.time = zeros(0, 1);
for mi = 1:numel(metrics)
    s.(metrics{mi}) = zeros(0, 1);
end
units = struct();
for mi = 1:numel(metrics)
    units.(metrics{mi}) = metricUnits.(metrics{mi});
end
s.units   = units;
s.metrics = metrics;
end
