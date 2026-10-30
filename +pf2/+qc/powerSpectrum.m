function result = powerSpectrum(data, varargin)
% POWERSPECTRUM Power spectral density with physiological peak detection
%
% Computes power spectral density per channel using Welch's method and
% identifies physiological peaks (cardiac, respiratory, Mayer wave). Works
% on any fNIRS signal stage: raw intensity, optical density, or hemoglobin.
% A visible cardiac peak (~0.8-1.5 Hz) in the power spectrum indicates the
% channel is picking up real physiological signal.
%
% Syntax:
%   result = pf2.qc.powerSpectrum(data)
%   result = pf2.qc.powerSpectrum(data, 'Signal', 'HbO')
%   result = pf2.qc.powerSpectrum(data, 'Channels', [1,3,5])
%   result = pf2.qc.powerSpectrum(data, 'DetectPeaks', false)
%
% Name-Value Parameters:
%   'Signal'       - Signal to analyze: 'raw', 'HbO', 'HbR', 'OD', or
%                    'auto'. Auto picks raw if available, else HbO.
%                    (default: 'auto')
%   'Channels'     - [1 x C] channel indices to analyze. Default: all good
%                    channels from fchMask. (default: [])
%   'WindowLength' - PSD window length in seconds; clamped to between
%                    3 samples and the recording length (default: 10)
%   'Overlap'      - Fractional overlap between windows, 0 to <1
%                    (default: 0.5)
%   'FreqRange'    - [1x2] frequency range to return in Hz. Upper bound is
%                    capped at Nyquist. (default: [0, 5])
%   'DetectPeaks'  - Enable physiological peak detection (default: true)
%
% Inputs:
%   data - fNIRS data struct. Must contain .fs and the selected signal
%          field (.raw, .HbO, .HbR, or .OD). For raw data, an optional
%          .device (pf2.Device) selects each channel's first non-dark
%          wavelength column, with channel k taken as the k-th entry of
%          the device channel list; without it, columns are assumed
%          interleaved.
%
% Outputs:
%   result - Struct with fields:
%            .psd       - [F x C] power spectral density matrix
%            .freqs     - [F x 1] frequency vector (Hz)
%            .channels  - [1 x C] channel indices
%            .signal    - Signal type used ('raw', 'HbO', etc.)
%            .fs        - Sampling rate
%
%            When DetectPeaks = true, also includes:
%            .cardiac      - struct with .freq, .power, .snr, .detected,
%                            .skipped, .skipReason
%            .respiratory  - struct with .freq, .power, .detected,
%                            .skipped, .skipReason
%            .mayer        - struct with .freq, .power, .detected,
%                            .skipped, .skipReason
%            A band is skipped (detected = false, freq/power NaN) when
%            the recording spans fewer than 5 cycles of the band's lower
%            edge: under 10 s for cardiac, 50 s for respiratory, 100 s
%            for Mayer.
%
% Algorithm:
%   1. Select signal from data struct based on Signal parameter
%   2. For each channel, compute PSD using Welch's method (pwelch if
%      available from Signal Processing Toolbox, otherwise FFT-based)
%   3. Identify peaks in known physiological bands:
%      - Cardiac: 0.5-2.5 Hz (expect ~1 Hz)
%      - Respiratory: 0.1-0.5 Hz (expect ~0.25 Hz)
%      - Mayer wave: 0.05-0.15 Hz (expect ~0.1 Hz)
%   4. Compute cardiac peak SNR: peak power / median power in band
%
% Example:
%   data = pf2_base.tests.synthetic.generateFNIRS('addHeartbeat', true);
%   result = pf2.qc.powerSpectrum(data, 'Signal', 'raw');
%   fprintf('Cardiac detected in %d/%d channels\n', ...
%       sum(result.cardiac.detected), numel(result.channels));
%
% References:
%   Welch, P. D. (1967). The use of fast Fourier transform for the
%   estimation of power spectra: a method based on time averaging over
%   short, modified periodograms. IEEE Transactions on Audio and
%   Electroacoustics, 15(2), 70-73. DOI: 10.1109/TAU.1967.1161901
%
%   Scholkmann, F., Kleiser, S., Metz, A. J., et al. (2014). A review on
%   continuous wave functional near-infrared spectroscopy and imaging
%   instrumentation and methodology. NeuroImage, 85, 6-27.
%   DOI: 10.1016/j.neuroimage.2013.05.004
%
% See also: pf2.qc.sci, pf2.qc.plotQuality, pwelch

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
data = pf2_base.args.check(data, '', 'struct', {}, 'Invalid argument at position 1.');
opts = pf2_base.args.parse('powerSpectrum', varargin, {}, {
    'Signal',       ('auto'), '', '', {}
    'Channels',     ([]), '', '', {@mustBeNumeric}
    'WindowLength', (10), '1,1', '', {@mustBeNumeric, @mustBePositive}
    'Overlap',      (0.5), '1,1', '', {@mustBeNumeric}
    'FreqRange',    ([0, 5]), '', '', {@mustBeNumeric}
    'DetectPeaks',  (true), '1,1', 'logical', {}
    });

%% Validate and resolve signal
assert(isfield(data, 'fs'), 'pf2:qc:powerSpectrum:noFs', ...
    'Data struct must contain a .fs field.');

fs = data.fs;
signalType = resolveSignal(data, opts.Signal);
sigData = getSignalData(data, signalType);

%% Resolve channels
if isempty(opts.Channels)
    nCh = size(sigData, 2);
    % For raw data with 2 wavelengths per channel, use fchMask to determine channel count
    if strcmp(signalType, 'raw') && isfield(data, 'fchMask')
        nCh = numel(data.fchMask);
        channels = find(data.fchMask);
    elseif isfield(data, 'fchMask')
        channels = find(data.fchMask);
    else
        channels = 1:nCh;
    end
else
    channels = opts.Channels;
end

%% Select columns from signal data
if strcmp(signalType, 'raw')
    % For raw data, resolve the first wavelength column of each channel
    nRawCols = size(sigData, 2);
    if isfield(data, 'device') && isa(data.device, 'pf2.Device')
        % Device layout: skip dark columns (wavelength 0) and handle
        % non-interleaved column orders. Channel k is the k-th entry of
        % the device channel list (as in processFNIRS2), so non-contiguous
        % numbering such as merged probes still maps by position.
        chNums = data.device.channelNumbers();
        wlVec = data.device.wavelengths();
        chList = data.device.channelList();
        colIndices = nan(1, numel(channels));
        for k = 1:numel(channels)
            if channels(k) < 1 || channels(k) > numel(chList)
                continue;
            end
            c = find(chNums == chList(channels(k)) & wlVec > 0, 1);
            if ~isempty(c) && c <= nRawCols
                colIndices(k) = c;
            end
        end
    else
        if isfield(data, 'info') && isfield(data.info, 'synthetic') ...
                && isfield(data.info.synthetic, 'wavelengths')
            nWl = numel(data.info.synthetic.wavelengths);
        else
            nWl = 2;  % Default: 2 interleaved wavelengths
        end
        colIndices = (channels - 1) * nWl + 1;
        colIndices(colIndices > nRawCols) = NaN;
    end
    keep = ~isnan(colIndices);
    channels = channels(keep);
    sigMatrix = sigData(:, colIndices(keep));
else
    % HbO, HbR, OD — columns map directly to channels
    validCh = channels(channels <= size(sigData, 2));
    channels = validCh;
    sigMatrix = sigData(:, channels);
end

nChannels = numel(channels);

%% Cap frequency range at Nyquist
nyquist = fs / 2;
freqRange = opts.FreqRange;
freqRange(2) = min(freqRange(2), nyquist);

%% Compute PSD using Welch's method
% Clamp the window to [3, recording length]: pwelch rejects windows longer
% than the signal, and the welchPSD Hann window has zero power under 3
nSamples = size(sigMatrix, 1);
windowSamples = min(max(round(opts.WindowLength * fs), 3), nSamples);
overlapSamples = min(round(windowSamples * opts.Overlap), windowSamples - 1);
nfft = max(256, 2^nextpow2(windowSamples));

if nChannels == 0 || nSamples < 3
    % Nothing to analyze (e.g. every channel masked bad): return empty
    % per-channel results instead of indexing into an empty matrix
    f = (0:nfft/2)' * fs / nfft;
    f = f(f >= freqRange(1) & f <= freqRange(2));
    result.psd = zeros(numel(f), nChannels);
    result.freqs = f;
    result.channels = channels;
    result.signal = signalType;
    result.fs = fs;
    if opts.DetectPeaks
        result = detectAllBands(result, nSamples / fs);
    end
    return;
end

% Check for pwelch availability
hasPwelch = ~isempty(which('pwelch'));

if hasPwelch
    % Use Signal Processing Toolbox pwelch
    % pwelch does not accept NaN — replace with zeros for affected channels
    sigClean = sigMatrix;
    nanChannels = any(isnan(sigMatrix), 1);
    for ch = find(nanChannels)
        col = sigClean(:, ch);
        col(isnan(col)) = 0;
        sigClean(:, ch) = col;
    end

    [pxx, f] = pwelch(sigClean(:,1), windowSamples, overlapSamples, nfft, fs);
    psdMatrix = zeros(numel(f), nChannels);
    psdMatrix(:, 1) = pxx;
    for ch = 2:nChannels
        psdMatrix(:, ch) = pwelch(sigClean(:, ch), windowSamples, overlapSamples, nfft, fs);
    end
else
    % FFT-based PSD (manual Welch implementation)
    [psdMatrix, f] = welchPSD(sigMatrix, windowSamples, overlapSamples, nfft, fs);
end

%% Trim to requested frequency range
freqMask = f >= freqRange(1) & f <= freqRange(2);
f = f(freqMask);
psdMatrix = psdMatrix(freqMask, :);

%% Build output
result.psd = psdMatrix;
result.freqs = f;
result.channels = channels;
result.signal = signalType;
result.fs = fs;

%% Detect physiological peaks
if opts.DetectPeaks
    result = detectAllBands(result, nSamples / fs);
end

end


%% Local functions

function signalType = resolveSignal(data, requested)
% RESOLVESIGNAL Determine which signal field to use

requested = char(requested);

if strcmpi(requested, 'auto')
    if isfield(data, 'raw')
        signalType = 'raw';
    elseif isfield(data, 'HbO')
        signalType = 'HbO';
    else
        error('pf2:qc:powerSpectrum:noSignal', ...
            'Data contains no recognized signal field (raw, HbO, HbR, OD).');
    end
else
    signalType = requested;
end

% Validate field exists
fieldName = signalType;
if strcmpi(signalType, 'OD')
    fieldName = 'OD';
end

assert(isfield(data, fieldName), 'pf2:qc:powerSpectrum:missingField', ...
    'Data struct does not contain .%s field.', fieldName);
end


function sigData = getSignalData(data, signalType)
% GETSIGNALDATA Extract the signal matrix from the data struct

switch signalType
    case 'raw'
        sigData = data.raw;
    case 'HbO'
        sigData = data.HbO;
    case 'HbR'
        sigData = data.HbR;
    case 'OD'
        sigData = data.OD;
    otherwise
        error('pf2:qc:powerSpectrum:unknownSignal', ...
            'Unknown signal type: %s', signalType);
end
end


function [psdMatrix, f] = welchPSD(sigMatrix, windowSamples, overlapSamples, nfft, fs)
% WELCHPSD Manual Welch PSD estimation using FFT
%
% Implements Welch's method without Signal Processing Toolbox.

[nSamples, nChannels] = size(sigMatrix);
stepSize = windowSamples - overlapSamples;
nWindows = floor((nSamples - windowSamples) / stepSize) + 1;

if nWindows < 1
    % Data shorter than window — use entire signal
    nWindows = 1;
    windowSamples = nSamples;
end

% Hanning window
w = 0.5 * (1 - cos(2 * pi * (0:windowSamples-1)' / (windowSamples - 1)));
winPower = sum(w.^2);

% Frequency vector
f = (0:nfft/2)' * fs / nfft;

psdMatrix = zeros(numel(f), nChannels);

for ch = 1:nChannels
    psdAccum = zeros(nfft/2 + 1, 1);

    for win = 1:nWindows
        startIdx = (win - 1) * stepSize + 1;
        endIdx = startIdx + windowSamples - 1;
        if endIdx > nSamples
            break;
        end

        segment = sigMatrix(startIdx:endIdx, ch);
        segment = segment - mean(segment);  % Remove DC
        segment = segment .* w;

        fftResult = fft(segment, nfft);
        pxx = (1 / (fs * winPower)) * abs(fftResult(1:nfft/2+1)).^2;
        % Double non-DC and non-Nyquist bins
        pxx(2:end-1) = 2 * pxx(2:end-1);

        psdAccum = psdAccum + pxx;
    end

    psdMatrix(:, ch) = psdAccum / nWindows;
end

end


function result = detectAllBands(result, durationSec)
% DETECTALLBANDS Run peak detection for each physiological band
%
% A band needs the recording to span at least minCycles cycles of its
% lower edge; shorter recordings cannot resolve a peak there, so the band
% is reported as skipped rather than as a spurious detection or miss.

minCycles = 5;
bandDefs = {'cardiac', [0.5, 2.5]; 'respiratory', [0.1, 0.5]; 'mayer', [0.05, 0.15]};

for b = 1:size(bandDefs, 1)
    name = bandDefs{b, 1};
    limits = bandDefs{b, 2};
    minDuration = minCycles / limits(1);
    if durationSec < minDuration
        bandResult = detectBandPeak(result.freqs, zeros(size(result.psd)), limits, name);
        bandResult.skipped = true;
        bandResult.skipReason = sprintf( ...
            'Recording too short (%.1f s < %.0f s) for %s band [%.2f, %.2f] Hz', ...
            durationSec, minDuration, name, limits(1), limits(2));
    else
        bandResult = detectBandPeak(result.freqs, result.psd, limits, name);
        bandResult.skipped = false;
        bandResult.skipReason = '';
    end
    result.(name) = bandResult;
end

end


function bandResult = detectBandPeak(freqs, psdMatrix, bandLimits, bandName)
% DETECTBANDPEAK Find peak in a physiological frequency band
%
% Inputs:
%   freqs      - [F x 1] frequency vector
%   psdMatrix  - [F x C] PSD matrix
%   bandLimits - [1 x 2] frequency band limits [low, high]
%   bandName   - Name of the band (for output)
%
% Outputs:
%   bandResult - struct with .freq, .power, .detected, and optionally .snr

nChannels = size(psdMatrix, 2);

bandResult.freq = nan(1, nChannels);
bandResult.power = nan(1, nChannels);
bandResult.detected = false(1, nChannels);

if strcmp(bandName, 'cardiac')
    bandResult.snr = nan(1, nChannels);
end

% Find indices within band
bandMask = freqs >= bandLimits(1) & freqs <= bandLimits(2);
if ~any(bandMask)
    return;
end

bandFreqs = freqs(bandMask);
bandPsd = psdMatrix(bandMask, :);

for ch = 1:nChannels
    chPsd = bandPsd(:, ch);

    if all(isnan(chPsd)) || all(chPsd == 0)
        continue;
    end

    % Find local maxima (findpeaks requires >= 3 samples)
    if numel(chPsd) >= 3
        [peakPowers, peakLocs] = findpeaks(chPsd);
    else
        peakPowers = [];
        peakLocs = [];
    end

    if isempty(peakPowers)
        % No local peak — use maximum
        [maxPow, maxIdx] = max(chPsd);
        % Check if it stands out above median (at least 2x)
        medPow = median(chPsd);
        if maxPow > 2 * medPow && medPow > 0
            bandResult.freq(ch) = bandFreqs(maxIdx);
            bandResult.power(ch) = maxPow;
            bandResult.detected(ch) = true;

            if strcmp(bandName, 'cardiac')
                bandResult.snr(ch) = maxPow / medPow;
            end
        end
    else
        % Use the largest peak
        [maxPeakPow, bestIdx] = max(peakPowers);
        peakFreq = bandFreqs(peakLocs(bestIdx));
        medPow = median(chPsd);

        % Peak must be at least 2x the median to be considered detected
        if maxPeakPow > 2 * medPow && medPow > 0
            bandResult.freq(ch) = peakFreq;
            bandResult.power(ch) = maxPeakPow;
            bandResult.detected(ch) = true;

            if strcmp(bandName, 'cardiac')
                bandResult.snr(ch) = maxPeakPow / medPow;
            end
        end
    end
end

end
