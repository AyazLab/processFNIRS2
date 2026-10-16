function [feat, info] = respFeatures(x, fs, varargin)
% RESPFEATURES Derive respiration rate and RVT from a respiration waveform
%
% Detects breaths in a respiration signal (belt / RIP / derived) and returns
% the instantaneous respiration rate (breaths per minute) and the respiration
% volume per time (RVT), both interpolated onto the input sample times. RVT is
% a standard low-frequency physiological nuisance regressor; respiration is the
% preferred conditioning signal for LFO/Mayer-band confound control.
%
% Reference:
%   Birn, R. M., Diamond, J. B., Smith, M. A., & Bandettini, P. A. (2006).
%   Separating respiratory-variation-related fluctuations from
%   neuronal-activity-related fluctuations in fMRI. NeuroImage, 31(4),
%   1536-1548. DOI: 10.1016/j.neuroimage.2006.02.048
%
% Syntax:
%   [feat, info] = pf2.data.aux.respFeatures(x, fs)
%   [feat, info] = pf2.data.aux.respFeatures(x, fs, 'Name', Value)
%
% Inputs:
%   x  - Respiration waveform [T x 1].
%   fs - Sampling rate in Hz [scalar].
%
% Name-Value Parameters:
%   'Band'    - Respiration band-pass [loHz hiHz] (default: [0.1 0.5]).
%   'MinRate' - Lowest plausible rate (breaths/min) (default: 5).
%   'MaxRate' - Highest plausible rate; sets the breath refractory period
%               (default: 60).
%
% Outputs:
%   feat - Struct with fields:
%          .rate - [T x 1] instantaneous respiration rate (breaths/min),
%                  NaN-free (edges held at the nearest estimate).
%          .rvt  - [T x 1] respiration volume per time: peak-to-trough
%                  amplitude divided by breath period, per breath, interpolated.
%   info - Struct with: peakIdx, troughIdx, peakTimes (s), meanRate, nBreaths,
%          band.
%
% Algorithm:
%   1. Zero-phase band-pass to the respiration band (FFT brick-wall).
%   2. Peak (inhalation) and trough (exhalation) detection with a refractory
%      period from MaxRate.
%   3. rate = 60 / breath-interval; RVT = (peak-trough)/period; both placed at
%      breath times and linearly interpolated onto the input grid.
%
% Notes:
%   - Self-contained (no Signal Processing Toolbox dependency).
%   - The FFT brick-wall band-pass can ring near transients/edges; treat the
%     first/last breath as less reliable.
%
% Example:
%   [feat, info] = pf2.data.aux.respFeatures(proc.Aux.resp.data, proc.Aux.resp.fs);
%
% See also: pf2.data.aux.heartRateFrom, pf2_base.auxSignalType, pf2.data.auxOnGrid

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
x = pf2_base.args.check(x, '', '', {@mustBeNumeric}, 'Invalid argument at position 1.');
fs = pf2_base.args.check(fs, '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}, 'Invalid argument at position 2.');
opts = pf2_base.args.parse('respFeatures', varargin, {}, {
    'Band',    ([0.1 0.5]), '', '', {@mustBeNumeric}
    'MinRate', (5), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}
    'MaxRate', (60), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}
    });
band = opts.Band;
maxRate = opts.MaxRate;

x = x(:);
T = numel(x);
t = (0:T-1)' / fs;

xf = bandpassFFT(x, fs, band(1), band(2));

minDist = max(1, round(fs * 60 / maxRate));        % refractory in samples
pThr = median(xf) + 0.3 * std(xf);
peakIdx = pickPeaks(xf, minDist, pThr);
troughIdx = pickPeaks(-xf, minDist, -median(xf) + 0.3 * std(xf));

info = struct('peakIdx', peakIdx(:), 'troughIdx', troughIdx(:), ...
    'peakTimes', t(peakIdx), 'meanRate', NaN, 'nBreaths', numel(peakIdx), ...
    'band', band);

feat = struct('rate', nan(T, 1), 'rvt', nan(T, 1));

if numel(peakIdx) < 2
    feat.rate = repmat(60 * numel(peakIdx) / max(t(end), eps), T, 1);
    feat.rvt = zeros(T, 1);
    return;
end

pkTimes = t(peakIdx);
ibi = diff(pkTimes);
instRate = 60 ./ ibi;
midTimes = pkTimes(1:end-1) + ibi / 2;

% --- Respiration rate onto the grid --------------------------------------
if numel(midTimes) == 1
    feat.rate = repmat(instRate, T, 1);
else
    feat.rate = fillEnds(interp1(midTimes, instRate, t, 'linear'));
end
info.meanRate = mean(instRate);

% --- RVT (Birn-style): within-cycle excursion / breath period ------------
% For breath cycle k (peak_k -> peak_{k+1}), amplitude is the peak-to-deepest-
% exhalation-trough excursion within that same cycle, divided by the cycle
% period, so amplitude and period are drawn from the same breath.
rvtVals = zeros(numel(peakIdx) - 1, 1);
for k = 1:numel(peakIdx) - 1
    pkA = peakIdx(k);
    pkB = peakIdx(k + 1);
    inCycle = troughIdx(troughIdx > pkA & troughIdx < pkB);
    if isempty(inCycle)
        trVal = min(xf(pkA:pkB));
    else
        trVal = min(xf(inCycle));
    end
    period = pkTimes(k + 1) - pkTimes(k);
    rvtVals(k) = abs(xf(pkA) - trVal) / max(period, eps);
end
if numel(midTimes) == 1
    feat.rvt = repmat(rvtVals(1), T, 1);
else
    feat.rvt = fillEnds(interp1(midTimes, rvtVals, t, 'linear'));
end

end

%%_Subfunctions_________________________________________________________

function y = bandpassFFT(x, fs, lo, hi)
% BANDPASSFFT Zero-phase brick-wall band-pass via FFT masking
N = numel(x);
xm = x - mean(x);
X = fft(xm);
f = (0:N-1)' * (fs / N);
fpos = min(f, fs - f);
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
            pk(end) = i;
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
