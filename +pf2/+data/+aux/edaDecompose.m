function [tonic, phasic, info] = edaDecompose(x, fs, varargin)
% EDADECOMPOSE Split electrodermal activity into tonic and phasic components
%
% Decomposes a galvanic skin response / electrodermal activity (GSR/EDA)
% signal into its slowly varying tonic level (skin conductance level, SCL)
% and the faster phasic response (skin conductance responses, SCRs). The
% tonic component reflects general arousal; the phasic component reflects
% event-related sympathetic activity.
%
% Syntax:
%   [tonic, phasic, info] = pf2.data.aux.edaDecompose(x, fs)
%   [tonic, phasic, info] = pf2.data.aux.edaDecompose(x, fs, 'Name', Value)
%
% Inputs:
%   x  - EDA/GSR signal [T x 1] (microsiemens).
%   fs - Sampling rate in Hz [scalar].
%
% Name-Value Parameters:
%   'TonicCutoff' - Low-pass cutoff (Hz) separating tonic from phasic
%                   (default: 0.05). Frequencies below this form the tonic
%                   component; the remainder is phasic.
%
% Outputs:
%   tonic  - Tonic level (SCL) [T x 1], the low-pass component.
%   phasic - Phasic activity (SCR) [T x 1] = x - tonic.
%   info   - Struct with: tonicCutoff, tonicMean, phasicStd.
%
% Algorithm:
%   Zero-phase moving-average low-pass at TonicCutoff yields the tonic level;
%   the phasic component is the residual. This is a lightweight alternative to
%   model-based deconvolution (e.g. cvxEDA) suitable for covariate extraction.
%
% Notes:
%   - Self-contained (no Signal Processing Toolbox dependency).
%   - Reference for the tonic/phasic framing: Boucsein, W. (2012).
%     Electrodermal Activity, 2nd ed. Springer. DOI: 10.1007/978-1-4614-1126-0
%
% Example:
%   [scl, scr] = pf2.data.aux.edaDecompose(proc.Aux.gsr.data, proc.Aux.gsr.fs);
%
% See also: pf2_base.auxSignalType, pf2.data.aux.heartRateFrom

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
x = pf2_base.args.check(x, '', '', {@mustBeNumeric}, 'Invalid argument at position 1.');
fs = pf2_base.args.check(fs, '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}, 'Invalid argument at position 2.');
opts = pf2_base.args.parse('edaDecompose', varargin, {}, {
    'TonicCutoff', (0.05), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}
    });
cutoff = opts.TonicCutoff;

x = x(:);

% The tonic low-pass window is ~ fs/cutoff samples (e.g. 20 s at 0.05 Hz). On a
% short recording the window dominates and the tonic collapses to a near-flat
% line, dumping nearly everything into the phasic component.
win = round(fs / cutoff);
if win > numel(x) / 3
    warning('pf2:edaDecompose:shortRecording', ...
        ['Tonic window (~%.0f s) exceeds a third of the recording (%.0f s); ', ...
         'the tonic/phasic split will be unreliable.'], win/fs, numel(x)/fs);
end

tonic = movavgLowpass(x, fs, cutoff);
phasic = x - tonic;

info = struct('tonicCutoff', cutoff, 'tonicMean', mean(tonic), ...
    'phasicStd', std(phasic));

end

%%_Subfunctions_________________________________________________________

function y = movavgLowpass(x, fs, cutoff)
% MOVAVGLOWPASS Zero-phase Hann moving-average low-pass at ~cutoff Hz
win = max(3, round(fs / cutoff));
if mod(win, 2) == 0
    win = win + 1;
end
k = 0.5 * (1 - cos(2 * pi * (0:win-1)' / (win - 1)));
k = k / sum(k);
half = (win - 1) / 2;
xp = [repmat(x(1), half, 1); x; repmat(x(end), half, 1)];
yc = conv(xp, k, 'same');
y = yc(half + 1 : half + numel(x));
end
