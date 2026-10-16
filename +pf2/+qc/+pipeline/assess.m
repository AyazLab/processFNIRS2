function report = assess(data, varargin)
% ASSESS Standalone fNIRS channel quality assessment pipeline
%
% Performs lightweight internal processing on raw fNIRS data and runs
% configurable quality checks to produce a detailed channel-by-channel
% report. Independent of the main processing pipeline — no global
% variables, no SMAR/TDDR, no baseline correction.
%
% Internal processing chain:
%   1. Raw -> OD: -log10(raw / mean(raw)) per channel
%   2. OD -> Hb: bvoxy_basic per channel pair (default DPF)
%   3. LPF on Hb: Butterworth low-pass (default 0.1 Hz)
%
% Checks run (in order):
%   saturation - Raw intensity at floor (0) or ceiling (device max) (raw)
%   sci        - Scalp coupling index via cardiac cross-correlation (raw)
%   cardiac    - Cardiac peak presence in power spectrum (raw)
%
%   sci and cardiac are skipped (channels not penalized, with a
%   skipReason) when the sampling rate cannot reach the cardiac band or
%   the recording spans fewer than 5 cycles of CardiacBand(1) (10 s for
%   the default band). takizawa likewise skips recordings under 10 s.
%   cov        - Coefficient of variation of raw signal (raw)
%   takizawa   - 4-rule hemoglobin QC (filtered Hb)
%
% Syntax:
%   report = pf2.qc.pipeline.assess(data)
%   report = pf2.qc.pipeline.assess(data, 'Checks', {'saturation', 'sci'})
%   report = pf2.qc.pipeline.assess(data, 'SCIThreshold', 0.8)
%
% Name-Value Parameters:
%   Checks         - Cell array of check names to run
%                    (default: {'saturation','sci','cardiac','cov','takizawa'})
%   SaturationThreshold - Max fraction of saturated samples per channel
%                    to pass (default: 0.1, i.e. 10%)
%   SCIThreshold   - SCI pass threshold (default: 0.75)
%   CardiacBand    - [1x2] cardiac frequency band in Hz (default: [0.5, 2.5])
%   CardiacSNR     - Minimum cardiac peak SNR to pass (default: 3)
%   CoVThreshold   - Max coefficient of variation of the raw signal
%                    (default: 0.2; raw fNIR intensity naturally runs
%                    higher CoV than filtered Hb)
%   LPFCutoff      - Low-pass cutoff for Hb in Hz (default: 0.1)
%   TakizawaStrict - Use strict (OR) Takizawa criteria (default: false)
%   Wavelengths    - Override wavelength layout for SCI (default: [])
%   ChannelNumbers - Override channel numbers for SCI (default: [])
%
% Inputs:
%   data - Raw fNIRS data struct with .raw, .fs, .time, .fchMask
%
% Outputs:
%   report - Struct with per-check details. See report fields below.
%
% Example:
%   data = pf2.import.importNIR('subject01.nir', 'subject01.mrk');
%   report = pf2.qc.pipeline.assess(data);
%   pf2.qc.pipeline.report(report);
%
% See also: pf2.qc.pipeline.apply, pf2.qc.pipeline.report,
%           pf2.qc.pipeline.plotReport, pf2.qc.sci, pf2.qc.powerSpectrum

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
data = pf2_base.args.check(data, '', 'struct', {}, 'Invalid argument at position 1.');
opts = pf2_base.args.parse('assess', varargin, {}, {
    'Checks',              ({'saturation','sci','cardiac','cov','takizawa'}), '', '', {@(v) mustBeA(v, 'cell')}
    'SaturationThreshold', (0.1), '1,1', '', {@mustBeNumeric}
    'SCIThreshold',        (0.75), '1,1', '', {@mustBeNumeric}
    'CardiacBand',         ([0.5, 2.5]), '', '', {@mustBeNumeric}
    'CardiacSNR',          (3), '1,1', '', {@mustBeNumeric}
    'CoVThreshold',        (0.2), '1,1', '', {@mustBeNumeric}
    'LPFCutoff',           (0.1), '1,1', '', {@mustBeNumeric}
    'TakizawaStrict',      (false), '1,1', 'logical', {}
    'Wavelengths',         ([]), '', '', {@mustBeNumeric}
    'ChannelNumbers',      ([]), '', '', {@mustBeNumeric}
    });

%% Validate required fields
assert(isfield(data, 'raw'), 'pf2:qc:pipeline:noRaw', ...
    'Data struct must contain a .raw field.');
assert(isfield(data, 'fs'), 'pf2:qc:pipeline:noFs', ...
    'Data struct must contain a .fs field.');
assert(isfield(data, 'time'), 'pf2:qc:pipeline:noTime', ...
    'Data struct must contain a .time field.');

fs = data.fs;
nRawCols = size(data.raw, 2);

%% Resolve channel layout from Device or fallback
hasDev = isfield(data, 'device') && isa(data.device, 'pf2.Device');
if hasDev
    dev = data.device;
    nChannels = dev.nChannels;
    wavelengths = dev.wavelengthSet;
    nWl = numel(wavelengths);
    % Build per-channel column map from Device. Channel k is the k-th
    % entry of the channel list (as in processFNIRS2), which differs from
    % the raw channel number on merged probes with non-contiguous numbering
    chNums = dev.channelNumbers();
    wlVec = dev.wavelengths();
    chList = dev.channelList();
    chColMapWl = cell(1, nChannels); % columns per wavelength (excl dark)
    for ch = 1:nChannels
        wlCols = find(chNums == chList(ch) & wlVec > 0);
        chColMapWl{ch} = wlCols;
    end
elseif isfield(data, 'info') && isfield(data.info, 'synthetic') ...
        && isfield(data.info.synthetic, 'wavelengths')
    wavelengths = data.info.synthetic.wavelengths;
    nWl = numel(wavelengths);
    nChannels = floor(nRawCols / nWl);
    hasDev = false;
    chColMapWl = cell(1, nChannels);
    for ch = 1:nChannels
        chColMapWl{ch} = (ch-1)*nWl + (1:nWl);
    end
else
    wavelengths = [730, 850];
    nWl = numel(wavelengths);
    nChannels = floor(nRawCols / nWl);
    chColMapWl = cell(1, nChannels);
    for ch = 1:nChannels
        chColMapWl{ch} = (ch-1)*nWl + (1:nWl);
    end
end

%% Determine which checks to run
validChecks = {'saturation', 'sci', 'cardiac', 'cov', 'takizawa'};
checks = lower(opts.Checks);
for i = 1:numel(checks)
    assert(ismember(checks{i}, validChecks), 'pf2:qc:pipeline:badCheck', ...
        'Unknown check: %s. Valid: %s', checks{i}, strjoin(validChecks, ', '));
end

needsHb = ismember('takizawa', checks);

%% Internal processing: Raw -> OD -> Hb (only if needed)
procInfo = struct();
procInfo.wavelengths = wavelengths;
procInfo.nChannels = nChannels;

if needsHb
    % Step 1: Raw -> OD
    baseline = mean(data.raw, 1);
    baseline(baseline == 0) = 1;  % avoid log(0)
    od = -log10(data.raw ./ baseline);

    % Step 2: OD -> Hb via simplified Beer-Lambert (no DPF, mM*mm units)
    wl1 = wavelengths(1);
    wl2 = wavelengths(2);
    nT = size(data.raw, 1);
    HbO = zeros(nT, nChannels);
    HbR = zeros(nT, nChannels);
    HbTotal = zeros(nT, nChannels);

    % Extinction coefficients via interpolation (same table as bvoxy)
    [eHbO_wl, eHbR_wl] = getExtinctionCoeffs([wl1, wl2]);
    eHbO_1 = eHbO_wl(1); eHbR_1 = eHbR_wl(1);  % shorter wavelength
    eHbO_2 = eHbO_wl(2); eHbR_2 = eHbR_wl(2);  % longer wavelength
    denom = eHbO_1 * eHbR_2 - eHbO_2 * eHbR_1;
    L = 100;  % NoPathlength mode: L=100, output in mM*mm

    for ch = 1:nChannels
        cols = chColMapWl{ch};
        if numel(cols) >= 2 && cols(2) <= nRawCols
            od1 = od(:, cols(1)) / L;
            od2 = od(:, cols(2)) / L;
            HbO(:,ch) = (eHbR_2 * od1 - eHbR_1 * od2) / denom;
            HbR(:,ch) = (eHbO_1 * od2 - eHbO_2 * od1) / denom;
            HbTotal(:,ch) = HbO(:,ch) + HbR(:,ch);
        end
    end

    % Step 3: Low-pass filter Hb
    lpfCutoff = opts.LPFCutoff;
    nyq = fs / 2;
    if lpfCutoff < nyq && nT > 20
        filterOrder = min(3, floor(nT/10));
        if filterOrder >= 1
            HbO_filt = pf2_base.signal.lpf(HbO, 3, fs, lpfCutoff, filterOrder);
            HbR_filt = pf2_base.signal.lpf(HbR, 3, fs, lpfCutoff, filterOrder);
            HbTotal_filt = pf2_base.signal.lpf(HbTotal, 3, fs, lpfCutoff, filterOrder);
        else
            HbO_filt = HbO;
            HbR_filt = HbR;
            HbTotal_filt = HbTotal;
        end
    else
        HbO_filt = HbO;
        HbR_filt = HbR;
        HbTotal_filt = HbTotal;
    end

    procInfo.odComputed = true;
    procInfo.hbComputed = true;
    procInfo.lpfCutoff = lpfCutoff;
    procInfo.lpfApplied = lpfCutoff < nyq && nT > 20;
else
    procInfo.odComputed = false;
    procInfo.hbComputed = false;
end

%% Initialize report
report = struct();
report.channels = 1:nChannels;
report.fs = fs;
report.timestamp = datetime('now');
report.processing = procInfo;
report.params = opts;

% Pre-initialize only the SELECTED checks, so each check's case has sane
% defaults (pass=true, skipped=true) if it returns early. Non-selected
% checks are intentionally absent from the report — every consumer
% (report, plotReport, apply, the summary table) iterates report.checkNames
% and guards field access with isfield, so a report contains exactly the
% checks that were run.
emptyCheck = struct('pass', true(1, nChannels), 'skipped', true);
for vc = 1:numel(checks)
    report.(checks{vc}) = emptyCheck;
end

%% Run checks
passMatrix = true(numel(checks), nChannels);

for ci = 1:numel(checks)
    switch checks{ci}

        case 'saturation'
            % Count samples at floor (<=rawMin) or ceiling (>=rawMax)
            % per channel. Requires device RawMax to be known.
            rawMaxVal = NaN;
            rawMinVal = 0;
            if hasDev
                try rawMaxVal = dev.rawMax; catch, end
                try rawMinVal = dev.rawMin; catch, end
            elseif isfield(data, 'info') && isfield(data.info, 'probename')
                % Try loading device just for bounds
                try
                    tmpDev = pf2.Device.load(data);
                    rawMaxVal = tmpDev.rawMax;
                    rawMinVal = tmpDev.rawMin;
                catch
                end
            end
            % Ensure scalar values
            if ~isscalar(rawMinVal) || ~isnumeric(rawMinVal) || isnan(rawMinVal)
                rawMinVal = 0;
            end
            if ~isscalar(rawMaxVal) || ~isnumeric(rawMaxVal)
                rawMaxVal = NaN;
            end

            nT = size(data.raw, 1);
            floorCount = zeros(1, nChannels);
            ceilCount = zeros(1, nChannels);

            for ch = 1:nChannels
                chCols = chColMapWl{ch};
                chCols = chCols(chCols <= nRawCols);
                if isempty(chCols), continue; end

                chRaw = data.raw(:, chCols);
                % Floor: any wavelength column <= rawMin
                atFloor = any(chRaw <= rawMinVal, 2);
                floorCount(ch) = sum(atFloor);

                % Ceiling: any wavelength column >= rawMax (only if known)
                if ~isnan(rawMaxVal)
                    atCeil = any(chRaw >= rawMaxVal, 2);
                    ceilCount(ch) = sum(atCeil);
                end
            end

            totalBad = floorCount + ceilCount;
            badPct = totalBad / nT;

            report.saturation.floorCount = floorCount;
            report.saturation.ceilCount = ceilCount;
            report.saturation.floorPct = floorCount / nT;
            report.saturation.ceilPct = ceilCount / nT;
            report.saturation.totalPct = badPct;
            report.saturation.pass = badPct <= opts.SaturationThreshold;
            report.saturation.threshold = opts.SaturationThreshold;
            report.saturation.rawMax = rawMaxVal;
            report.saturation.rawMin = rawMinVal;
            report.saturation.skipped = false;

            if isnan(rawMaxVal)
                % Can still check floor, but ceiling is unknown
                report.saturation.ceilCount = nan(1, nChannels);
                report.saturation.ceilPct = nan(1, nChannels);
                report.saturation.totalPct = floorCount / nT;
                report.saturation.pass = (floorCount / nT) <= opts.SaturationThreshold;
            end

            passMatrix(ci, :) = report.saturation.pass;

        case 'sci'
            sciArgs = {'Threshold', opts.SCIThreshold, ...
                       'CardiacBand', opts.CardiacBand};
            % Pass Device wavelength/channel layout to SCI
            if ~isempty(opts.Wavelengths)
                sciArgs = [sciArgs, {'Wavelengths', opts.Wavelengths}]; %#ok<AGROW>
            elseif hasDev
                sciArgs = [sciArgs, {'Wavelengths', wlVec}]; %#ok<AGROW>
            end
            if ~isempty(opts.ChannelNumbers)
                sciArgs = [sciArgs, {'ChannelNumbers', opts.ChannelNumbers}]; %#ok<AGROW>
            elseif hasDev
                sciArgs = [sciArgs, {'ChannelNumbers', chNums}]; %#ok<AGROW>
            end

            sciResult = pf2.qc.sci(data, sciArgs{:});

            % Map SCI results to our channel count (may differ)
            nSci = numel(sciResult.sci);
            if nSci == nChannels
                sciVals = sciResult.sci;
                sciPass = sciResult.isGood;
            else
                sciVals = nan(1, nChannels);
                sciPass = true(1, nChannels);
                n = min(nSci, nChannels);
                sciVals(1:n) = sciResult.sci(1:n);
                sciPass(1:n) = sciResult.isGood(1:n);
            end

            report.sci.values = sciVals;
            report.sci.pass = sciPass;
            report.sci.threshold = opts.SCIThreshold;
            report.sci.skipped = sciResult.skipped;
            if sciResult.skipped
                report.sci.skipReason = sciResult.skipReason;
                passMatrix(ci, :) = true;
            else
                passMatrix(ci, :) = sciPass;
            end

        case 'cardiac'
            % Check if cardiac detection is feasible at this sampling rate.
            % Cardiac frequency is typically 0.8-1.5 Hz (48-90 bpm).
            % Need Nyquist > ~1.0 Hz (fs > ~2 Hz) for reliable detection.
            nyq = fs / 2;
            minUsableCardiacHz = 1.0;
            % A spectral peak needs several beats: at least 5 cycles of
            % the band's lower edge (10 s for the default band), the same
            % minimum pf2.qc.sci and pf2.qc.powerSpectrum apply
            minCardiacDuration = 5 / opts.CardiacBand(1);
            durationSec = size(data.raw, 1) / fs;
            cardiacSkipReason = '';
            if nyq <= minUsableCardiacHz
                cardiacSkipReason = sprintf(...
                    'Sampling rate (%.1f Hz) too low for cardiac peak detection (Nyquist=%.1f Hz, need >%.1f Hz)', ...
                    fs, nyq, minUsableCardiacHz);
            elseif durationSec < minCardiacDuration
                cardiacSkipReason = sprintf(...
                    'Recording too short (%.1f s < %.0f s) for cardiac peak detection', ...
                    durationSec, minCardiacDuration);
            end
            if ~isempty(cardiacSkipReason)
                % Cannot meaningfully detect cardiac peaks
                report.cardiac.detected = false(1, nChannels);
                report.cardiac.snr = nan(1, nChannels);
                report.cardiac.freq = nan(1, nChannels);
                report.cardiac.pass = true(1, nChannels);
                report.cardiac.threshold = opts.CardiacSNR;
                report.cardiac.skipped = true;
                report.cardiac.skipReason = cardiacSkipReason;
                passMatrix(ci, :) = true;
            else
                psdResult = pf2.qc.powerSpectrum(data, ...
                    'Signal', 'raw', 'DetectPeaks', true);

                cardiacDetected = false(1, nChannels);
                cardiacSNR = zeros(1, nChannels);
                cardiacFreq = nan(1, nChannels);

                % Map PSD channels to our channel indices
                for ch = 1:numel(psdResult.channels)
                    idx = psdResult.channels(ch);
                    if idx <= nChannels
                        cardiacDetected(idx) = psdResult.cardiac.detected(ch);
                        cardiacSNR(idx) = psdResult.cardiac.snr(ch);
                        cardiacFreq(idx) = psdResult.cardiac.freq(ch);
                    end
                end

                cardiacPass = cardiacDetected & (cardiacSNR >= opts.CardiacSNR);

                report.cardiac.detected = cardiacDetected;
                report.cardiac.snr = cardiacSNR;
                report.cardiac.freq = cardiacFreq;
                report.cardiac.pass = cardiacPass;
                report.cardiac.threshold = opts.CardiacSNR;
                report.cardiac.skipped = false;
                passMatrix(ci, :) = cardiacPass;
            end

        case 'cov'
            covValues = zeros(1, nChannels);
            for ch = 1:nChannels
                chCols = chColMapWl{ch};
                chCols = chCols(chCols <= nRawCols);
                if isempty(chCols)
                    covValues(ch) = Inf;
                    continue;
                end
                chMeans = mean(data.raw(:, chCols), 1);
                chStds = std(data.raw(:, chCols), 0, 1);
                chMeans(chMeans == 0) = 1;
                covPerWl = chStds ./ abs(chMeans);
                covValues(ch) = mean(covPerWl);
            end

            covPass = covValues <= opts.CoVThreshold;

            report.cov.values = covValues;
            report.cov.pass = covPass;
            report.cov.threshold = opts.CoVThreshold;
            report.cov.skipped = false;  % CoV always runs; clear the emptyCheck default
            passMatrix(ci, :) = covPass;

        case 'takizawa'
            % Build minimal struct for Takizawa
            qcData = struct('HbO', HbO_filt, 'HbR', HbR_filt, ...
                'HbTotal', HbTotal_filt, 'time', data.time, ...
                'units', 'mM*mm', 'DPF_factor', [1, 1]);

            tkReport = pf2.qc.takizawa(qcData, 'Strict', opts.TakizawaStrict);

            report.takizawa.rules = tkReport.rules;
            report.takizawa.ruleNames = tkReport.ruleNames;
            report.takizawa.pass = tkReport.pass;
            report.takizawa.skipped = tkReport.skipped;
            if tkReport.skipped
                report.takizawa.skipReason = tkReport.skipReason;
            end
            passMatrix(ci, :) = tkReport.pass;
    end
end

%% Compute overall pass
report.pass = all(passMatrix, 1);
report.nChecks = numel(checks);
report.checkNames = checks;

%% Build summary table
summaryData = cell(nChannels, numel(checks));
for ci = 1:numel(checks)
    for ch = 1:nChannels
        summaryData{ch, ci} = passMatrix(ci, ch);
    end
end
report.summary = cell2table(summaryData, ...
    'VariableNames', checks, ...
    'RowNames', arrayfun(@(x) sprintf('Ch%d', x), 1:nChannels, 'UniformOutput', false));

end


%% Local functions

function [eHbO, eHbR] = getExtinctionCoeffs(lambdas)
% GETEXTINCTIONCOEFFS Look up molar extinction coefficients for HbO and HbR
%
% Uses the Prahl tabulated values (same source as bvoxy). Returns values
% in 1/(mM*cm) matching the bvoxy convention.

% Subset of Prahl table: [wavelength, HbO (1/(cm*M)), HbR (1/(cm*M))]
coefTable = [650, 368, 3750.12; 700, 290, 1794.28; 730, 390, 1102.2;
    750, 518, 1405.24; 780, 710, 1075.44; 800, 816, 761.72;
    830, 974, 693.04; 850, 1058, 691.32; 870, 1128, 705.84;
    900, 1198, 761.84];

% Convert from 1/(cm*M) to 1/(cm*mM) = multiply by 1e-3
allWl = coefTable(:, 1);
allHbO = coefTable(:, 2) * 1e-3;
allHbR = coefTable(:, 3) * 1e-3;

% Then convert from 1/(cm*mM) to 1/(cm*uM) by dividing by 1000
% to match bvoxy's internal convention
eHbO = interp1(allWl, allHbO, lambdas, 'linear', 'extrap') / 1000;
eHbR = interp1(allWl, allHbR, lambdas, 'linear', 'extrap') / 1000;

end
