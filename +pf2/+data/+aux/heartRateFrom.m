function [hr, info] = heartRateFrom(x, fs, varargin)
% HEARTRATEFROM Derive a heart-rate (bpm) series from a PPG or EKG waveform
%
% Detects cardiac beats in a pulsatile waveform (photoplethysmography or
% electrocardiogram) and returns an instantaneous heart-rate series in beats
% per minute, interpolated onto the input sample times. This turns a raw
% cardiac WAVEFORM aux signal into an HR FEATURE series usable as a covariate
% or for quality control.
%
% Syntax:
%   [hr, info] = pf2.data.aux.heartRateFrom(x, fs)
%   [hr, info] = pf2.data.aux.heartRateFrom(x, fs, 'Name', Value)
%
% Inputs:
%   x  - Cardiac waveform [T x 1] (PPG or single-lead EKG).
%   fs - Sampling rate in Hz [scalar].
%
% Name-Value Parameters:
%   'Band'   - Cardiac band-pass [loHz hiHz] for beat enhancement
%              (default: [0.5 5]).
%   'MinBPM' - Lowest plausible rate; sets the search ceiling (default: 30).
%   'MaxBPM' - Highest plausible rate; sets the beat refractory period
%              (default: 220).
%
% Outputs:
%   hr   - Instantaneous heart rate [T x 1] in bpm on the input time base
%          (NaN-free; ends held at the nearest estimate).
%   info - Struct with: peakIdx, peakTimes (s), meanBPM, nBeats, band.
%
% Algorithm:
%   1. Zero-phase band-pass to the cardiac band (FFT brick-wall).
%   2. Adaptive-threshold local-maxima peak picking with a refractory period
%      derived from MaxBPM.
%   3. Instantaneous bpm = 60 / inter-beat-interval, placed at beat midpoints
%      and linearly interpolated onto the input grid.
%
% Notes:
%   - Self-contained (no Signal Processing Toolbox dependency).
%   - For noisy data, prefer PPG over EKG unless R-peaks are clean.
%   - The band-pass is an FFT brick-wall filter; it can introduce mild Gibbs
%     ringing near sharp beats and at the record edges, so the first/last
%     beat estimates may be less reliable.
%
% Example:
%   ppg = proc.Aux.ppg.data;  fs = proc.Aux.ppg.fs;
%   [hr, info] = pf2.data.aux.heartRateFrom(ppg, fs);
%
% See also: pf2_base.auxSignalType, pf2.data.auxOnGrid, pf2.data.aux.edaDecompose

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
x = pf2_base.args.check(x, '', '', {@mustBeNumeric}, 'Invalid argument at position 1.');
fs = pf2_base.args.check(fs, '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}, 'Invalid argument at position 2.');
opts = pf2_base.args.parse('heartRateFrom', varargin, {}, {
    'Band',   ([0.5 5]), '', '', {@mustBeNumeric}
    'MinBPM', (30), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}
    'MaxBPM', (220), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}
    });
band = opts.Band;
maxBPM = opts.MaxBPM;

x = x(:);
T = numel(x);
t = (0:T-1)' / fs;

% --- 1. Band-pass to the cardiac band ------------------------------------
xf = bandpassFFT(x, fs, band(1), band(2));

% --- 2. Peak detection ----------------------------------------------------
minDist = max(1, round(fs * 60 / maxBPM));      % refractory in samples
thr = median(xf) + 0.5 * std(xf);                % adaptive amplitude threshold
peakIdx = pickPeaks(xf, minDist, thr);

info = struct('peakIdx', peakIdx(:), 'peakTimes', t(peakIdx), ...
    'meanBPM', NaN, 'nBeats', numel(peakIdx), 'band', band);

if numel(peakIdx) < 2
    % Not enough beats: fall back to a flat NaN-free series at the global rate
    hr = repmat(60 * numel(peakIdx) / max(t(end), eps), T, 1);
    return;
end

% --- 3. Instantaneous bpm via inter-beat intervals -----------------------
pkTimes = t(peakIdx);
ibi = diff(pkTimes);
instBPM = 60 ./ ibi;
midTimes = pkTimes(1:end-1) + ibi / 2;

if numel(midTimes) == 1
    hr = repmat(instBPM, T, 1);
else
    hr = interp1(midTimes, instBPM, t, 'linear');
    hr = fillEnds(hr);   % hold first/last valid estimate at the edges
end

info.meanBPM = mean(instBPM);

end

%%_Subfunctions_________________________________________________________

function y = bandpassFFT(x, fs, lo, hi)
% BANDPASSFFT Zero-phase brick-wall band-pass via FFT masking
N = numel(x);
xm = x - mean(x);
X = fft(xm);
f = (0:N-1)' * (fs / N);
fpos = min(f, fs - f);                 % fold to one-sided frequency
mask = (fpos >= lo) & (fpos <= hi);
y = real(ifft(X .* mask));
end

function pk = pickPeaks(x, minDist, thr)
% PICKPEAKS Local maxima above threshold with a refractory distance
n = numel(x);
pk = [];
last = -inf;
for i = 2:n-1
    if x(i) > x(i-1) && x(i) >= x(i+1) && x(i) > thr
        if i - last >= minDist
            pk(end+1) = i; %#ok<AGROW>
            last = i;
        elseif ~isempty(pk) && x(i) > x(pk(end))
            pk(end) = i;     % keep the taller peak within the refractory window
            last = i;
        end
    end
end
end

function y = fillEnds(y)
% FILLENDS Replace leading/trailing NaNs with the nearest valid value
valid = find(~isnan(y));
if isempty(valid)
    return;
end
y(1:valid(1)-1) = y(valid(1));
y(valid(end)+1:end) = y(valid(end));
end
