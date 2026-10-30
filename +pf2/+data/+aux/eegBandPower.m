function [bandPower, info] = eegBandPower(x, fs, varargin)
% EEGBANDPOWER Extract canonical EEG band-power feature series
%
% Converts a raw EEG waveform (one or more channels) into per-band power
% envelopes over the canonical clinical bands (delta, theta, alpha, beta,
% gamma). EEG is treated as its own signal family in processFNIRS2: high
% sampling rate, multichannel, and analyzed by frequency band rather than by
% peak detection or tonic/phasic decomposition. The resulting band-power
% series are time-varying features suitable as covariates or for fNIRS-EEG
% fusion after alignment with pf2.data.auxOnGrid.
%
% Syntax:
%   [bandPower, info] = pf2.data.aux.eegBandPower(x, fs)
%   [bandPower, info] = pf2.data.aux.eegBandPower(x, fs, 'Name', Value)
%
% Inputs:
%   x  - EEG data [T x C] (C channels, microvolts).
%   fs - Sampling rate in Hz [scalar].
%
% Name-Value Parameters:
%   'Bands'     - Struct mapping band name -> [loHz hiHz]
%                 (default: canonical bands from pf2_base.auxSignalType('eeg')).
%   'SmoothWin' - Power-envelope smoothing window in seconds (default: 1).
%
% Outputs:
%   bandPower - Struct with one field per band, each [T x C], holding the
%               smoothed band-limited power envelope.
%   info      - Struct with: bands (used), smoothWin, channels (C).
%
% Algorithm:
%   For each band: zero-phase FFT band-pass, square to instantaneous power,
%   then smooth with a zero-phase moving average of length SmoothWin seconds.
%
% Notes:
%   - Self-contained (no Signal Processing Toolbox dependency).
%   - Canonical bands: delta 1-4, theta 4-8, alpha 8-13, beta 13-30,
%     gamma 30-45 Hz.
%   - The per-band filter is an FFT brick-wall mask; it has edge ringing and
%     sidelobe leakage, so the band-power envelope is a lightweight covariate
%     feature, not a substitute for a dedicated EEG spectral pipeline. Edge
%     samples (~one smoothing window) are unreliable.
%
% Example:
%   bp = pf2.data.aux.eegBandPower(eeg, 256);
%   alphaCz = bp.alpha(:, chCz);
%
% See also: pf2_base.auxSignalType, pf2.data.auxOnGrid

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
x = pf2_base.args.check(x, '', '', {@mustBeNumeric}, 'Invalid argument at position 1.');
fs = pf2_base.args.check(fs, '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}, 'Invalid argument at position 2.');
opts = pf2_base.args.parse('eegBandPower', varargin, {}, {
    'Bands',     ([]), '', '', {}
    'SmoothWin', (1), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}
    });
bands = opts.Bands;
smoothWin = opts.SmoothWin;

if isempty(bands)
    info0 = pf2_base.auxSignalType('eeg');
    bands = info0.bands;
end

if isrow(x)
    x = x(:);
end
[T, C] = size(x);

winSamp = max(3, round(smoothWin * fs));
if mod(winSamp, 2) == 0
    winSamp = winSamp + 1;
end

bandNames = fieldnames(bands);
bandPower = struct();
for b = 1:numel(bandNames)
    nm = bandNames{b};
    rng = bands.(nm);
    P = zeros(T, C);
    for c = 1:C
        xf = bandpassFFT(x(:, c), fs, rng(1), rng(2));
        P(:, c) = movavgSmooth(xf.^2, winSamp);
    end
    bandPower.(nm) = P;
end

info = struct('bands', bands, 'smoothWin', smoothWin, 'channels', C);

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

function y = movavgSmooth(x, win)
% MOVAVGSMOOTH Zero-phase Hann moving-average smoother
k = 0.5 * (1 - cos(2 * pi * (0:win-1)' / (win - 1)));
k = k / sum(k);
half = (win - 1) / 2;
xp = [repmat(x(1), half, 1); x; repmat(x(end), half, 1)];
yc = conv(xp, k, 'same');
y = yc(half + 1 : half + numel(x));
end
