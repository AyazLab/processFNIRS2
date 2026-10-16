function result = sci(data, varargin)
% SCI Scalp Coupling Index for fNIRS channel quality assessment
%
% Measures optode-scalp contact quality by cross-correlating cardiac
% pulsations across the two wavelengths at each channel. Good coupling
% means both wavelengths see the same heartbeat, yielding a high
% cross-correlation value.
%
% Reference:
%   Pollonini, L., Olds, C., Abaya, H., Bortfeld, H., Beauchamp, M. S.,
%   & Oghalai, J. S. (2014). Auditory cortex activation to natural speech
%   and simulated cochlear implant speech measured with functional
%   near-infrared spectroscopy. Hearing Research, 309, 84-93.
%   DOI: 10.1016/j.heares.2013.11.007
%
% Syntax:
%   result = pf2.qc.sci(data)
%   result = pf2.qc.sci(data, 'CardiacBand', [0.5, 2.5])
%   result = pf2.qc.sci(data, 'Threshold', 0.8)
%   result = pf2.qc.sci(data, 'Wavelengths', wl, 'ChannelNumbers', ch)
%
% Name-Value Parameters:
%   'CardiacBand'    - [1x2] Bandpass range for cardiac extraction in Hz
%                      (default: [0.5, 2.5])
%   'FilterOrder'    - Butterworth filter order (default: 4)
%   'Wavelengths'    - [1 x C_raw] wavelength per raw column (nm).
%                      Values > 0 = wavelength in nm, 0 = dark, NaN = skip.
%                      Override for when automatic detection fails.
%   'ChannelNumbers' - [1 x C_raw] optode/channel number per raw column.
%                      Must be same length as Wavelengths.
%   'Threshold'      - SCI threshold for good/bad classification
%                      (default: 0.75)
%
% Inputs:
%   data - fNIRS data struct with at minimum:
%          .raw  - [T x C_raw] raw light intensity
%          .fs   - Sampling frequency (Hz)
%          Wavelength layout resolved from (in order):
%            1. data.device (pf2.Device); channel i is the i-th entry of
%               the device channel list
%            2. Explicit Wavelengths/ChannelNumbers parameters
%            3. data.probeinfo.Probe{1}.TableCh
%            4. data.info.synthetic.wavelengths (alternating ch1_wl1, ch1_wl2, ...)
%
% Outputs:
%   result - Struct with fields:
%            .sci       - [1 x nChannels] SCI values (0 to 1)
%            .isGood    - [1 x nChannels] logical (sci >= threshold)
%            .channels  - [1 x nChannels] channel indices
%            .threshold - Threshold used
%            .cardiacBand - [low, high] Hz
%            .fs        - Sampling rate
%            .skipped   - true when SCI could not be computed (sampling
%                         rate below the cardiac band, or a recording
%                         shorter than 5 cycles of CardiacBand(1), i.e.
%                         10 s for the default band); .sci is then NaN and
%                         .isGood true so channels are not penalized
%            .skipReason - Reason for the skip (only when skipped)
%
% Algorithm:
%   1. Resolve wavelength layout from data or explicit parameters
%   2. For each channel, extract the two raw wavelength signals
%   3. Bandpass filter both to the cardiac band using bpf()
%   4. Compute zero-lag normalized cross-correlation
%   5. SCI = abs(cross-correlation value), range 0 to 1
%
% Example:
%   data = pf2.import.importNIR('subject01.nir');
%   result = pf2.qc.sci(data);
%   fprintf('Good channels: %d/%d\n', sum(result.isGood), numel(result.channels));
%
%   % With explicit wavelength layout
%   wl = repmat([730, 850], 1, 18);  % 18 channels, 2 wavelengths each
%   ch = repelem(1:18, 2);
%   result = pf2.qc.sci(data, 'Wavelengths', wl, 'ChannelNumbers', ch);
%
% See also: pf2.qc.powerSpectrum, pf2.qc.plotQuality, bpf

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
data = pf2_base.args.check(data, '', 'struct', {}, 'Invalid argument at position 1.');
opts = pf2_base.args.parse('sci', varargin, {}, {
    'CardiacBand',    ([0.5, 2.5]), '', '', {@mustBeNumeric}
    'FilterOrder',    (4), '1,1', '', {@mustBeNumeric, @mustBePositive}
    'Wavelengths',    ([]), '', '', {@mustBeNumeric}
    'ChannelNumbers', ([]), '', '', {@mustBeNumeric}
    'Threshold',      (0.75), '1,1', '', {@mustBeNumeric}
    });

%% Validate required fields
assert(isfield(data, 'raw'), 'pf2:qc:sci:noRaw', ...
    'Data struct must contain a .raw field with intensity data.');
assert(isfield(data, 'fs'), 'pf2:qc:sci:noFs', ...
    'Data struct must contain a .fs field with sampling frequency.');

fs = data.fs;

%% Resolve wavelength layout (needed to determine nChannels for early return)
[channelMap, nChannels] = resolveWavelengthLayout(data, opts);

%% Check Nyquist constraint — graceful degradation for low sampling rates
nyquist = fs / 2;
cardiacBand = opts.CardiacBand;

if cardiacBand(2) >= nyquist
    % Auto-clamp upper band to 80% of Nyquist (filter rolloff margin)
    clampedHigh = nyquist * 0.8;
    bandwidth = clampedHigh - cardiacBand(1);

    if bandwidth < 0.5 || clampedHigh < 1.0
        % Band too narrow or can't reach typical cardiac frequency (~1 Hz)
        warning('pf2:qc:sci:lowFs', ...
            ['Sampling rate (%.1f Hz) is too low for SCI computation. ' ...
             'Cardiac band [%.1f, %.1f] Hz requires Nyquist > %.1f Hz. ' ...
             'Returning NaN (channels not penalized).'], ...
            fs, cardiacBand(1), cardiacBand(2), cardiacBand(2));

        result.sci = nan(1, nChannels);
        result.isGood = true(1, nChannels);
        result.channels = 1:nChannels;
        result.threshold = opts.Threshold;
        result.cardiacBand = opts.CardiacBand;
        result.fs = fs;
        result.skipped = true;
        result.skipReason = sprintf(...
            'Sampling rate (%.1f Hz) too low for cardiac band [%.1f, %.1f] Hz', ...
            fs, cardiacBand(1), cardiacBand(2));
        return;
    end

    warning('pf2:qc:sci:bandClamped', ...
        'Cardiac band clamped from [%.1f, %.1f] to [%.1f, %.1f] Hz (Nyquist=%.1f Hz).', ...
        cardiacBand(1), cardiacBand(2), cardiacBand(1), clampedHigh, nyquist);
    cardiacBand(2) = clampedHigh;
end

%% Check recording length: the cardiac correlation needs several beats
% (at least 5 cycles of the band's lower edge, 10 s for the default band),
% and the bandpass filter needs more samples than its padding length
minCycles = 5;
minDuration = minCycles / cardiacBand(1);
nSamples = size(data.raw, 1);
durationSec = nSamples / fs;
minSamples = 3 * (2 * opts.FilterOrder) + 1;
if durationSec < minDuration || nSamples < minSamples
    result.sci = nan(1, nChannels);
    result.isGood = true(1, nChannels);
    result.channels = 1:nChannels;
    result.threshold = opts.Threshold;
    result.cardiacBand = cardiacBand;
    result.fs = fs;
    result.skipped = true;
    result.skipReason = sprintf( ...
        'Recording too short (%.1f s < %.0f s) for cardiac band [%.1f, %.1f] Hz', ...
        durationSec, minDuration, cardiacBand(1), cardiacBand(2));
    return;
end

%% Compute SCI for each channel
sciValues = zeros(1, nChannels);

for ch = 1:nChannels
    col1 = channelMap(ch, 1);
    col2 = channelMap(ch, 2);

    if col1 == 0 || col2 == 0
        % Could not map this channel
        sciValues(ch) = 0;
        continue;
    end

    wl1 = data.raw(:, col1);
    wl2 = data.raw(:, col2);

    % Skip if either signal is constant (dead channel) or contains all NaN
    if std(wl1, 'omitnan') == 0 || std(wl2, 'omitnan') == 0
        sciValues(ch) = 0;
        continue;
    end

    % Bandpass filter to cardiac band
    wl1_filt = pf2_base.signal.bpf(wl1, opts.FilterOrder, fs, cardiacBand(1), cardiacBand(2));
    wl2_filt = pf2_base.signal.bpf(wl2, opts.FilterOrder, fs, cardiacBand(1), cardiacBand(2));

    % Remove NaN positions (bpf returns NaN for non-finite input spans)
    validMask = ~isnan(wl1_filt) & ~isnan(wl2_filt);
    if sum(validMask) < 10
        sciValues(ch) = 0;
        continue;
    end

    % Compute zero-lag normalized cross-correlation
    xc = xcorr(wl1_filt(validMask), wl2_filt(validMask), 0, 'normalized');
    sciValues(ch) = abs(xc);
end

%% Build output
result.sci = sciValues;
result.isGood = sciValues >= opts.Threshold;
result.channels = 1:nChannels;
result.threshold = opts.Threshold;
result.cardiacBand = cardiacBand;
result.fs = fs;
result.skipped = false;

end


%% Local functions

function [channelMap, nChannels] = resolveWavelengthLayout(data, opts)
% RESOLVEWAVELENGHTLAYOUT Determine which raw columns belong to each channel
%
% Returns channelMap [nChannels x 2] where each row gives the two column
% indices in data.raw for that channel's two wavelengths.

% Method 0: data.device (pf2.Device object)
if isfield(data, 'device') && isa(data.device, 'pf2.Device')
    wl = data.device.wavelengths();
    chNums = data.device.channelNumbers();

    % Channel i is the i-th entry of the device channel list (as in
    % processFNIRS2), which can differ from the unique raw channel numbers
    % on merged probes
    chList = data.device.channelList();
    nChannels = numel(chList);
    channelMap = zeros(nChannels, 2);

    for i = 1:nChannels
        cols = find(chNums == chList(i) & wl > 0 & ~isnan(wl));
        if numel(cols) >= 2
            channelMap(i, :) = cols(1:2);
        end
    end
    return;
end

% Method 1: Explicit parameters
if ~isempty(opts.Wavelengths) && ~isempty(opts.ChannelNumbers)
    wl = opts.Wavelengths;
    chNums = opts.ChannelNumbers;
    assert(numel(wl) == numel(chNums), 'pf2:qc:sci:paramMismatch', ...
        'Wavelengths and ChannelNumbers must have the same length.');

    uniqueCh = unique(chNums(chNums > 0));
    nChannels = numel(uniqueCh);
    channelMap = zeros(nChannels, 2);

    for i = 1:nChannels
        cols = find(chNums == uniqueCh(i) & wl > 0 & ~isnan(wl));
        if numel(cols) >= 2
            channelMap(i, :) = cols(1:2);
        end
    end
    return;
end

% Method 2: probeinfo.Probe{1}.TableCh
if isfield(data, 'probeinfo') && isfield(data.probeinfo, 'Probe') ...
        && iscell(data.probeinfo.Probe) && ~isempty(data.probeinfo.Probe) ...
        && isfield(data.probeinfo.Probe{1}, 'TableCh')
    tableCh = data.probeinfo.Probe{1}.TableCh;
    % SNIRF TableCh is a table with named columns:
    %   ColNumber, OptodeNumber, isTime, isMarker, isCh, Wavelength, isDark, ...
    % Each row = one raw column. OptodeNumber groups two wavelengths per channel.
    if istable(tableCh) && ismember('OptodeNumber', tableCh.Properties.VariableNames) ...
            && ismember('ColNumber', tableCh.Properties.VariableNames)
        colNums = tableCh.ColNumber(:)';
        optNums = tableCh.OptodeNumber(:)';

        % Filter to valid channels only (exclude time, marker, dark)
        if ismember('isCh', tableCh.Properties.VariableNames)
            validMask = tableCh.isCh(:)';
        else
            validMask = optNums > 0 & ~isnan(optNums);
        end

        uniqueCh = unique(optNums(validMask & optNums > 0 & ~isnan(optNums)));
        nChannels = numel(uniqueCh);
        channelMap = zeros(nChannels, 2);

        for i = 1:nChannels
            cols = colNums(optNums == uniqueCh(i) & validMask);
            if numel(cols) >= 2
                channelMap(i, :) = cols(1:2);
            end
        end
        return;

    % Fallback: non-SNIRF table or numeric array with [chNum, wlIdx, ...]
    elseif size(tableCh, 2) >= 2
        if istable(tableCh)
            chNums = tableCh{:, 1}';
            wlIdx = tableCh{:, 2}';
        else
            chNums = tableCh(:, 1)';
            wlIdx = tableCh(:, 2)';
        end

        uniqueCh = unique(chNums(chNums > 0));
        nChannels = numel(uniqueCh);
        channelMap = zeros(nChannels, 2);

        for i = 1:nChannels
            cols = find(chNums == uniqueCh(i));
            if numel(cols) >= 2
                channelMap(i, :) = cols(1:2);
            end
        end
        return;
    end
end

% Method 3: Synthetic data — alternating ch1_wl1, ch1_wl2, ch2_wl1, ch2_wl2, ...
if isfield(data, 'info') && isfield(data.info, 'synthetic') ...
        && isfield(data.info.synthetic, 'wavelengths')
    wls = data.info.synthetic.wavelengths;
    nRawCols = size(data.raw, 2);
    nWl = numel(wls);

    if nWl > 0 && mod(nRawCols, nWl) == 0
        nChannels = nRawCols / nWl;
        channelMap = zeros(nChannels, 2);
        for i = 1:nChannels
            channelMap(i, :) = [(i-1)*nWl + 1, (i-1)*nWl + 2];
        end
        return;
    end
end

% No method worked
error('pf2:qc:sci:noWavelengthLayout', ...
    ['Cannot determine wavelength layout. Pass ''Wavelengths'' and ' ...
     '''ChannelNumbers'' parameters explicitly.']);

end
