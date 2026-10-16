function report = takizawa(data, varargin)
% TAKIZAWA Automatic channel quality assessment using Takizawa criteria
%
% Evaluates four rules derived from Takizawa et al. (2008, 2014) to
% identify artifactual fNIRS channels based on high-frequency noise,
% low-frequency noise, zero-variance signals, and body movement artifacts.
% Returns a structured report with per-rule detail, suitable for use by
% the QC pipeline or standalone analysis.
%
% Originally designed for Hitachi ETG-4000 data during ~60 s verbal
% fluency tasks at 10 Hz. Adaptations for other devices include unit
% approximation in mM*mm, alternate sampling frequency support,
% proportional high-frequency window calculation, and sliding margin for
% body movement detection.
%
% The 2014 criteria (unitless) are preferred over 2008 band-power rules
% for cross-device compatibility. Band-power values are computed
% optionally via the IncludeBandPower parameter.
%
% Reference:
%   Takizawa, R., Kasai, K., Kawakubo, Y., Marumo, K., Kawasaki, S.,
%   Yamasue, H., & Fukuda, M. (2008). Reduced frontopolar activation
%   during verbal fluency task in schizophrenia: A multi-channel
%   near-infrared spectroscopy study. Schizophrenia Research, 99(1-3),
%   250-262. DOI: 10.1016/j.schres.2007.10.025
%
%   Takizawa, R., Fukuda, M., Kawasaki, S., Kasai, K., Mimura, M.,
%   Pu, S., Noda, T., Niwa, S.-I., & Okazaki, Y. (2014).
%   Neuroimaging-aided differential diagnosis of the depressive state.
%   NeuroImage, 85, 498-507. DOI: 10.1016/j.neuroimage.2013.05.126
%
% Syntax:
%   report = pf2.qc.takizawa(data)
%   report = pf2.qc.takizawa(data, 'Strict', true)
%   report = pf2.qc.takizawa(data, 'BodyMovementThreshold', 0.2)
%
% Name-Value Parameters:
%   Strict               - Use OR instead of AND for sub-conditions
%                          within each rule (default: false)
%   HFNoiseRatio         - SD ratio threshold for Rule 1 (default: 4)
%   HFNoiseWindow        - Sliding window size in seconds for Rule 1
%                          (default: 15)
%   HFNoiseFraction      - Fraction of time exceeding threshold to fail
%                          Rule 1 (default: 0.5)
%   LFThreshold          - Low-frequency value threshold for Rule 2
%                          (default: 0.3)
%   CorrThreshold        - Pearson correlation threshold for Rule 2
%                          (default: -0.9)
%   BodyMovementThreshold - Jump threshold in mM*mm for Rule 4
%                          (default: 0.5). The published 0.15 value was
%                          calibrated for Hitachi ETG-4000 verbal-fluency
%                          data; 0.5 generalizes better across devices and
%                          sampling rates without rejecting normal channels.
%   BodyMovementWindow   - Window size in seconds for Rule 4
%                          (default: 2)
%   ProtocolDuration     - Reference protocol length in seconds for Rule 4.
%                          The number of tolerated movement events scales as
%                          floor(recordingLength / ProtocolDuration), min 1
%                          (default: 90)
%   IncludeBandPower     - Compute 2008 band-power metrics (default: false)
%
% Inputs:
%   data - fNIRS data struct. If data.HbO exists, uses processed Hb
%          fields directly. Otherwise requires .raw, .fs, .time and
%          performs lightweight OD->Hb conversion internally.
%
% Outputs:
%   report - Struct with fields:
%     .pass       - [1xC] logical, combined pass/fail per channel
%     .values     - [1xC] double, count of rules failed (0-4)
%     .skipped    - logical, true if check was skipped
%     .skipReason - char, reason for skip (empty if not skipped)
%     .rules      - [4xC] logical, per-rule pass/fail
%     .ruleNames  - {'HighFreqNoise','LowFreqNoise','ZeroVariance','BodyMovement'}
%     .rule1      - struct with HF noise detail fields
%     .rule2      - struct with LF noise detail fields
%     .rule3      - struct with zero-variance detail fields
%     .rule4      - struct with body movement detail fields
%     .strict     - logical, whether strict mode was used
%     .fs         - scalar, sampling rate used
%     .units      - char, units of Hb data used
%
% Example:
%   data = pf2.import.sampleData.fNIR2000();
%   processed = processFNIRS2(data);
%   r = pf2.qc.takizawa(processed);
%   fprintf('Channels passing: %d/%d\n', sum(r.pass), numel(r.pass));
%
% See also: pf2.qc.pipeline.assess, pf2.qc.sci, pf2_TakizawaRejection

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
data = pf2_base.args.check(data, '', 'struct', {}, 'Invalid argument at position 1.');
opts = pf2_base.args.parse('takizawa', varargin, {}, {
    'Strict',                (false), '1,1', 'logical', {}
    'HFNoiseRatio',          (4), '1,1', '', {@mustBeNumeric}
    'HFNoiseWindow',         (15), '1,1', '', {@mustBeNumeric}
    'HFNoiseFraction',       (0.5), '1,1', '', {@mustBeNumeric}
    'LFThreshold',           (0.3), '1,1', '', {@mustBeNumeric}
    'CorrThreshold',         (-0.9), '1,1', '', {@mustBeNumeric}
    'BodyMovementThreshold', (0.5), '1,1', '', {@mustBeNumeric}
    'BodyMovementWindow',    (2), '1,1', '', {@mustBeNumeric}
    'ProtocolDuration',      (90), '1,1', '', {@mustBeNumeric}
    'IncludeBandPower',      (false), '1,1', 'logical', {}
    });

%% Resolve Hb data
if isfield(data, 'HbO') && isfield(data, 'HbR')
    % Processed data path
    fHbO = data.HbO;
    fHbR = data.HbR;
    if isfield(data, 'HbTotal')
        fHbT = data.HbTotal;
    else
        fHbT = fHbO + fHbR;
    end

    % Unit conversion if needed. DPF_factor is the *effective* pathlength factor
    % actually applied (DPF, or DPF/PVC under partial-volume correction). PVC
    % inflates HbO by the same factor it divides out of DPF_factor, so this
    % HbO*DPF_factor reconstruction is invariant to PVC (verified: identical
    % rejection) — do NOT substitute a nominal DPF, which would over-reject on
    % PVC-corrected data.
    % KNOWN LIMITATION (not yet corrected): the hard-coded * 3 assumes a 3 cm
    % source-detector distance rather than the device's actual per-channel
    % geometry, so uM-processed data reconstructed here is thresholded ~1.45x
    % more aggressively than data processed natively in mM*mm. A geometry-aware
    % reconstruction would need re-validation against Takizawa's mM*mm
    % calibration before changing established rejection behavior.
    if isfield(data, 'units') && strcmp(data.units, 'uM')
        dpf = 1;
        if isfield(data, 'DPF_factor')
            dpf = mean(data.DPF_factor);
        end
        fHbO = fHbO * dpf * 3 / 100;
        fHbR = fHbR * dpf * 3 / 100;
        fHbT = fHbT * dpf * 3 / 100;
        units = 'mM*mm (converted from uM)';
    else
        units = 'mM*mm';
    end
else
    error('pf2:qc:takizawa:noHb', ...
        'Data must contain .HbO and .HbR fields (processed data) or pass through assess pipeline.');
end

nCh = size(fHbO, 2);
nT = size(fHbO, 1);

%% Resolve time and sampling rate
if isfield(data, 'time') && ~isempty(data.time)
    t = data.time;
    Fs = 1 / median(diff(t), 'omitnan');
elseif isfield(data, 'fs')
    Fs = data.fs;
    t = (0:nT-1)' / Fs;
else
    error('pf2:qc:takizawa:noTime', ...
        'Data must contain .time or .fs field.');
end

timeLength = max(t) - min(t);

%% Initialize report
ruleNames = {'HighFreqNoise', 'LowFreqNoise', 'ZeroVariance', 'BodyMovement'};

report = struct();
report.pass = true(1, nCh);
report.values = zeros(1, nCh);
report.skipped = false;
report.skipReason = '';
report.rules = true(4, nCh);
report.ruleNames = ruleNames;
report.rule1 = struct();
report.rule2 = struct();
report.rule3 = struct();
report.rule4 = struct();
report.strict = opts.Strict;
report.fs = Fs;
report.units = units;

%% Graceful degradation checks
if timeLength < 10
    report.skipped = true;
    report.skipReason = sprintf('Data too short (%.1f s < 10 s minimum)', timeLength);
    return;
end

if isnan(Fs) || Fs < 2
    report.skipped = true;
    report.skipReason = sprintf('Sampling rate insufficient (Fs=%.2f Hz, need >= 2 Hz)', Fs);
    return;
end

%% Rule 1: High-frequency noise
% Per Takizawa 2014 Supplementary Material 3:
% SD of HbO and HbR in sliding windows compared to SD of HbTotal.
% If SD_HbO > ratio * SD_Total AND SD_HbR > ratio * SD_Total in a
% sufficient fraction of time windows, the channel is artifactual.

hfWindowSize = opts.HFNoiseWindow * Fs;
k = ceil(hfWindowSize);

fHbO_sd = movstd(fHbO, k);
fHbR_sd = movstd(fHbR, k);
fHbT_sd = movstd(fHbT, k);

hfRatioHbO = fHbO_sd ./ fHbT_sd;
hfRatioHbR = fHbR_sd ./ fHbT_sd;

hfExceedO = hfRatioHbO > opts.HFNoiseRatio;
hfExceedR = hfRatioHbR > opts.HFNoiseRatio;

if opts.Strict
    hfTimeMask = hfExceedO | hfExceedR;
else
    hfTimeMask = hfExceedO & hfExceedR;
end

fracExceeding = sum(hfTimeMask, 1) / size(hfTimeMask, 1);
rule1Fail = fracExceeding > opts.HFNoiseFraction;

report.rules(1, :) = ~rule1Fail;
report.rule1.hfRatioHbO = max(hfRatioHbO, [], 1);
report.rule1.hfRatioHbR = max(hfRatioHbR, [], 1);
report.rule1.fracExceeding = fracExceeding;
report.rule1.threshold = opts.HFNoiseRatio;

%% Rule 2: Low-frequency noise (2014 criteria)
% LF = abs(1 - (std(HbR) / std(HbO)))
% r = Pearson correlation of HbO and HbR per channel
% Channel is artifactual if LF < threshold AND r < corrThreshold

stdHbO = std(fHbO, 0, 1, 'omitnan');
stdHbR = std(fHbR, 0, 1, 'omitnan');

LF = abs(1 - (stdHbR ./ stdHbO));

% Per-channel correlation using diag(corr(...))
rMatrix = pf2_base.compat.corr(fHbO, fHbR, 'Rows', 'pairwise');
r = diag(rMatrix)';

if opts.Strict
    rule2Fail = (r < opts.CorrThreshold) | (LF < opts.LFThreshold);
else
    rule2Fail = (r < opts.CorrThreshold) & (LF < opts.LFThreshold);
end

report.rules(2, :) = ~rule2Fail;
report.rule2.LF = LF;
report.rule2.r = r;
report.rule2.threshold = struct('LF', opts.LFThreshold, 'r', opts.CorrThreshold);

%% Rule 3: Zero variance
% Channels with no change in HbO/HbR have std == 0 and are artifactual.
% Bug fix: original used < 0 (std is never negative), corrected to <= 0.

stdO = std(fHbO, 1, 1, 'omitnan');
stdR = std(fHbR, 1, 1, 'omitnan');

if opts.Strict
    rule3Fail = (stdO <= 0) | (stdR <= 0);
else
    rule3Fail = (stdO <= 0) & (stdR <= 0);
end

report.rules(3, :) = ~rule3Fail;
report.rule3.stdHbO = stdO;
report.rule3.stdHbR = stdR;
report.rule3.threshold = 0;

%% Rule 4: Body movement artifacts
% Per Takizawa 2008/2014: channels with sharp HbO AND HbTotal changes
% exceeding a threshold over a short window are artifactual.
% Vectorized: compute differences over the window size without a loop.

ws = ceil(opts.BodyMovementWindow * Fs);

if nT > ws + 1
    % Vectorized difference: each row is fHb(i+ws) - fHb(i)
    diffHbO = fHbO(ws+1:end, :) - fHbO(1:end-ws, :);
    diffHbT = fHbT(ws+1:end, :) - fHbT(1:end-ws, :);

    overHbO = abs(diffHbO) > opts.BodyMovementThreshold;
    overHbT = abs(diffHbT) > opts.BodyMovementThreshold;

    if opts.Strict
        overBoth = overHbO | overHbT;
    else
        overBoth = overHbO & overHbT;
    end

    % Collapse consecutive over-threshold samples into discrete movement
    % EVENTS (count rising edges) so one sustained artifact counts once
    % instead of once per sample. The previous per-sample sum produced
    % counts in the thousands and, compared against an allowed-block budget
    % of order 1, rejected every channel of normal-range data.
    jumpCountHbO  = sum(diff([zeros(1, nCh); overHbO],  1, 1) == 1, 1);
    jumpCountHbT  = sum(diff([zeros(1, nCh); overHbT],  1, 1) == 1, 1);
    jumpCountBoth = sum(diff([zeros(1, nCh); overBoth], 1, 1) == 1, 1);

    % Allowed number of movement events, scaled by recording length
    % (one tolerated event per reference protocol window, minimum one).
    maxBlocks = max(1, floor(timeLength / opts.ProtocolDuration));
    rule4Fail = jumpCountBoth > maxBlocks;
else
    jumpCountHbO = zeros(1, nCh);
    jumpCountHbT = zeros(1, nCh);
    jumpCountBoth = zeros(1, nCh);
    maxBlocks = 0;
    rule4Fail = false(1, nCh);
end

report.rules(4, :) = ~rule4Fail;
report.rule4.jumpCountHbO = jumpCountHbO;
report.rule4.jumpCountHbT = jumpCountHbT;
report.rule4.jumpCountBoth = jumpCountBoth;
report.rule4.maxBlocks = maxBlocks;
report.rule4.threshold = opts.BodyMovementThreshold;

%% Optional: 2008 band-power metrics
if opts.IncludeBandPower
    ftHbO = fft(fHbO);
    ftHbR = fft(fHbR);

    L = size(ftHbO, 1);
    L2 = floor(L/2 + 1);

    Pxx_HbO = 1/(L*Fs) * abs(ftHbO(1:L2, :)).^2;
    Pxx_HbR = 1/(L*Fs) * abs(ftHbR(1:L2, :)).^2;

    DF = Fs / L;
    freqvec = 0:DF:Fs/2;

    point1hz = find(freqvec > 0.1, 1);
    onehz = find(freqvec > 1, 1);
    if isempty(onehz), onehz = length(freqvec); end

    if ~isempty(point1hz)
        report.bandPower.HbO = max(abs(Pxx_HbO(point1hz:onehz, :)), [], 1);
        report.bandPower.HbR = max(abs(Pxx_HbR(point1hz:onehz, :)), [], 1);
    else
        report.bandPower.HbO = nan(1, nCh);
        report.bandPower.HbR = nan(1, nCh);
    end
    report.bandPower.freqvec = freqvec;
end

%% Combine rules
% NaN in any rule → treat as fail
ruleResults = report.rules;
ruleResults(isnan(ruleResults)) = 0;

report.rules = logical(ruleResults);
report.values = sum(~ruleResults, 1);
report.pass = all(ruleResults, 1);

end
