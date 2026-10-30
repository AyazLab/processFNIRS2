function [hrv, info] = hrvFeatures(x, varargin)
% HRVFEATURES Heart-rate variability metrics from a waveform or beat series
%
% Computes standard time- and frequency-domain HRV metrics, which serve as
% autonomic/arousal covariates. Input may be a PPG/EKG waveform (beats are
% detected internally), a vector of beat times, or a vector of inter-beat (NN)
% intervals. The returned metrics are scalars (one summary per record/epoch).
%
% Reference:
%   Task Force of the European Society of Cardiology and the North American
%   Society of Pacing and Electrophysiology (1996). Heart rate variability:
%   standards of measurement, physiological interpretation, and clinical use.
%   Circulation, 93(5), 1043-1065. DOI: 10.1161/01.CIR.93.5.1043
%
% Syntax:
%   [hrv, info] = pf2.data.aux.hrvFeatures(x, fs)
%   [hrv, info] = pf2.data.aux.hrvFeatures(ibiSeries, [], 'Input', 'ibi')
%   [hrv, info] = pf2.data.aux.hrvFeatures(x, fs, 'Name', Value)
%
% Inputs:
%   x  - One of: a PPG/EKG waveform [T x 1] (default); beat times in seconds
%        ('Input','beats'); or NN/RR intervals ('Input','ibi').
%   fs - Sampling rate in Hz (required for 'waveform'; ignored otherwise, pass
%        [] ).
%
% Name-Value Parameters:
%   'Input'      - 'waveform' (default) | 'beats' | 'ibi'.
%   'IBIUnit'    - Unit of an 'ibi' input: 'ms' (default) or 's'.
%   'Band'       - Cardiac band for waveform beat detection (default: [0.5 5]).
%   'LFBand'     - Low-frequency band, Hz (default: [0.04 0.15]).
%   'HFBand'     - High-frequency band, Hz (default: [0.15 0.40]).
%   'ResampleFs' - Tachogram resampling rate for spectral HRV (default: 4 Hz).
%
% Outputs:
%   hrv  - Struct of scalar metrics:
%          .meanHR  - mean heart rate (bpm)
%          .meanNN  - mean NN interval (ms)
%          .SDNN    - standard deviation of NN intervals (ms)
%          .RMSSD   - root mean square of successive differences (ms)
%          .pNN50   - % of successive NN differences > 50 ms
%          .LF      - low-frequency power (ms^2), NaN if too few beats
%          .HF      - high-frequency power (ms^2), NaN if too few beats
%          .LFHF    - LF/HF ratio, NaN if HF is 0 or undefined
%   info - Struct with: nBeats, beatTimes (s), source ('waveform'|'beats'|'ibi').
%
% Notes:
%   - Self-contained (no Signal Processing Toolbox dependency).
%   - Frequency-domain metrics require a usable number of beats (>= ~20) and a
%     recording long enough to resolve the LF band; otherwise LF/HF are NaN.
%   - HRV from a smoothed HR *series* is not equivalent to beat-to-beat NN
%     intervals; pass a waveform or NN intervals for valid SDNN/RMSSD.
%
% Example:
%   hrv = pf2.data.aux.hrvFeatures(proc.Aux.ppg.data, proc.Aux.ppg.fs);
%
% See also: pf2.data.aux.heartRateFrom, pf2_base.auxSignalType

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
x = pf2_base.args.check(x, '', '', {@mustBeNumeric}, 'Invalid argument at position 1.');
[fs, opts] = pf2_base.args.parse('hrvFeatures', varargin, {
    'fs', ([]), '', '', {@mustBeNumeric}
    }, {
    'Input',      ('waveform'), '', '', {}
    'IBIUnit',    ('ms'), '', '', {}
    'Band',       ([0.5 5]), '', '', {@mustBeNumeric}
    'LFBand',     ([0.04 0.15]), '', '', {@mustBeNumeric}
    'HFBand',     ([0.15 0.40]), '', '', {@mustBeNumeric}
    'ResampleFs', (4), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}
    });
inputType = lower(char(opts.Input));
ibiUnit = lower(char(opts.IBIUnit));
lfBand = opts.LFBand;
hfBand = opts.HFBand;
reFs = opts.ResampleFs;

x = x(:);

% --- Resolve NN intervals (ms) and beat times (s) ------------------------
switch inputType
    case 'waveform'
        if isempty(fs)
            error('pf2:hrvFeatures:noFs', 'fs is required for waveform input.');
        end
        [~, hrInfo] = pf2.data.aux.heartRateFrom(x, fs, 'Band', opts.Band);
        beatTimes = hrInfo.peakTimes(:);
        nnMs = diff(beatTimes) * 1000;
    case 'beats'
        beatTimes = x;
        nnMs = diff(beatTimes) * 1000;
    case 'ibi'
        if strcmp(ibiUnit, 's')
            nnMs = x * 1000;
        else
            nnMs = x;
        end
        beatTimes = cumsum([0; nnMs / 1000]);
    otherwise
        error('pf2:hrvFeatures:badInput', ...
            'Input must be one of ''waveform'', ''beats'', or ''ibi'' (got ''%s'').', ...
            inputType);
end

info = struct('nBeats', numel(beatTimes), 'beatTimes', beatTimes, 'source', inputType);

hrv = struct('meanHR', NaN, 'meanNN', NaN, 'SDNN', NaN, 'RMSSD', NaN, ...
    'pNN50', NaN, 'LF', NaN, 'HF', NaN, 'LFHF', NaN);

if numel(nnMs) < 2
    return;
end

% --- Time-domain metrics --------------------------------------------------
hrv.meanNN = mean(nnMs);
hrv.meanHR = 60000 / max(hrv.meanNN, eps);   % guard against zero/degenerate NN
hrv.SDNN = std(nnMs);
dNN = diff(nnMs);
hrv.RMSSD = sqrt(mean(dNN.^2));
hrv.pNN50 = 100 * mean(abs(dNN) > 50);

% --- Frequency-domain metrics (resampled tachogram PSD) ------------------
% Require a tachogram long enough to resolve the LF lower edge: the lowest LF
% frequency (lfBand(1)) needs >= 1/lfBand(1) seconds, i.e. reFs/lfBand(1)
% samples. A shorter record cannot estimate LF, so LF/HF stay NaN.
minTachoSamp = ceil(reFs / lfBand(1));
if numel(nnMs) >= 20
    % Tachogram: NN value at the time of each beat (use beat end times)
    tNN = beatTimes(2:end);
    tNN = tNN - tNN(1);
    tGrid = (0:1/reFs:tNN(end))';
    if numel(tGrid) >= minTachoSamp
        nnGrid = interp1(tNN, nnMs, tGrid, 'linear');
        nnGrid(isnan(nnGrid)) = 0;
        nnGrid = detrend(nnGrid);   % linear detrend (removes mean + slow drift)
        N = numel(nnGrid);
        X = fft(nnGrid);
        psd = (abs(X).^2) / (N * reFs);          % one-sided scaling below
        f = (0:N-1)' * (reFs / N);
        half = f <= reFs/2;
        f = f(half); psd = psd(half);
        psd(2:end) = 2 * psd(2:end);
        hrv.LF = bandPower(f, psd, lfBand);
        hrv.HF = bandPower(f, psd, hfBand);
        if hrv.HF > 0
            hrv.LFHF = hrv.LF / hrv.HF;
        end
    end
end

end

%%_Subfunctions_________________________________________________________

function p = bandPower(f, psd, band)
% BANDPOWER Integrate the PSD over a frequency band (trapezoidal)
%   Returns NaN (not 0) when the band is too sparsely sampled to integrate, so
%   "unresolvable" is distinguishable from "no power".
mask = f >= band(1) & f <= band(2);
if nnz(mask) < 2
    p = NaN;
    return;
end
p = trapz(f(mask), psd(mask));
end
