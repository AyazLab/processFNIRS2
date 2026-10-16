function [vals, info] = auxOnGrid(data, name, varargin)
% AUXONGRID Resample a named auxiliary signal onto a target time base
%
% Returns an auxiliary signal aligned to an arbitrary time grid (the fNIRS
% time vector by default) so it can be used as a regressor, covariate, or
% overlay. Handles anti-aliasing when downsampling, clock offset between
% devices, NaN gaps (not interpolated across), and out-of-range samples
% (set to NaN rather than extrapolated). This is the single alignment
% primitive that the Aux modeling and correction functions build on.
%
% Syntax:
%   [vals, info] = pf2.data.auxOnGrid(data, name)
%   vals = pf2.data.auxOnGrid(data, name, 'Name', Value)
%
% Inputs:
%   data - fNIRS data struct with a .Aux container and a .time vector.
%   name - Auxiliary signal name [char|string], a field of data.Aux
%          (e.g. 'heartRate', 'accelerometer').
%
% Name-Value Parameters:
%   'Time'      - Target time grid [N x 1] in seconds (default: data.time).
%   'Channels'  - Channel subset: indices [1 x K] or names (cellstr/string)
%                 matched against the signal's varNames (default: all).
%   'Method'    - interp1 method for alignment (default: 'linear').
%   'Offset'    - Clock offset in seconds added to the Aux time base before
%                 alignment, to correct device skew (default: 0).
%   'AntiAlias' - Low-pass filter the source before downsampling (default:
%                 true). Ignored when upsampling.
%   'MaxGap'    - Source-time gaps (or NaN runs) wider than this many seconds
%                 are not interpolated across; target points inside such a gap
%                 are returned as NaN (default: Inf, i.e. interpolate freely).
%
% Outputs:
%   vals - [N x K] signal sampled on the target grid (NaN where unavailable).
%   info - Struct with fields: signal, channels, srcFs, tgtFs, offset,
%          antiAliased (logical), nInterp (in-range target samples), nNaN.
%
% Notes:
%   - The signal is read through pf2_base.normalizeAux, so any reasonable Aux
%     shape (struct/table/numeric, missing varNames, etc.) is accepted.
%   - Anti-aliasing uses a zero-phase Hann-windowed moving average sized to
%     the target sample period; it requires no Signal Processing Toolbox.
%   - With the default grid equal to the source time base, the output equals
%     the input (identity), aside from NaN handling.
%
% Example:
%   hr  = pf2.data.auxOnGrid(proc, 'heartRate');             % onto proc.time
%   acc = pf2.data.auxOnGrid(proc, 'accelerometer', 'Channels', {'X','Y'});
%   eda = pf2.data.auxOnGrid(proc, 'gsr', 'Offset', 0.25, 'MaxGap', 2);
%
% See also: pf2_base.normalizeAux, pf2_base.auxSignalType, pf2.data.resample

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
data = pf2_base.args.check(data, '', '', {@(v) mustBeA(v, 'struct')}, 'Invalid argument at position 1.');
name = pf2_base.args.check(name, '', '', {@mustBeText}, 'Invalid argument at position 2.');
opts = pf2_base.args.parse('auxOnGrid', varargin, {}, {
    'Time',      ([]), '', '', {@mustBeNumeric}
    'Channels',  ([]), '', '', {}
    'Method',    ('linear'), '', '', {}
    'Offset',    (0), '1,1', '', {@mustBeNumeric}
    'AntiAlias', (true), '1,1', 'logical', {}
    'MaxGap',    (Inf), '1,1', '', {@mustBeNumeric, @mustBePositive}
    });

name = char(string(name));
method = char(string(opts.Method));
offset = opts.Offset;
antiAlias = opts.AntiAlias;
maxGap = opts.MaxGap;

% --- Locate and normalize the requested signal ---------------------------
if ~isfield(data, 'Aux') || isempty(data.Aux) || ~isstruct(data.Aux)
    error('pf2:auxOnGrid:noAux', 'Data has no .Aux container.');
end
try
    [sig, sigName] = pf2_base.resolveAux(data.Aux, name);
catch ME
    if strcmp(ME.identifier, 'pf2:resolveAux:notFound')
        error('pf2:auxOnGrid:notFound', '%s', ME.message);
    else
        rethrow(ME);
    end
end

srcTime = sig.time(:) + offset;
srcData = sig.data;
if isrow(srcData), srcData = srcData(:); end

% --- Channel subset -------------------------------------------------------
nCh = size(srcData, 2);
chans = opts.Channels;
if isempty(chans)
    chanIdx = 1:nCh;
elseif isnumeric(chans)
    chanIdx = chans(:)';
else
    chans = cellstr(chans);
    chanIdx = zeros(1, numel(chans));
    for c = 1:numel(chans)
        m = find(strcmpi(sig.varNames, chans{c}), 1);
        if isempty(m)
            error('pf2:auxOnGrid:badChannel', ...
                'Channel "%s" not found in signal "%s".', chans{c}, sigName);
        end
        chanIdx(c) = m;
    end
end
srcData = srcData(:, chanIdx);

% --- Target grid ----------------------------------------------------------
tgt = opts.Time;
if isempty(tgt)
    if ~isfield(data, 'time') || isempty(data.time)
        error('pf2:auxOnGrid:noTime', ...
            'No target grid given and data.time is empty.');
    end
    tgt = data.time;
end
tgt = tgt(:);

srcFs = estimateFs(srcTime);
tgtFs = estimateFs(tgt);

% --- Anti-alias before downsampling --------------------------------------
didAA = false;
if antiAlias && isfinite(srcFs) && isfinite(tgtFs) && tgtFs < srcFs
    srcData = antiAliasLowpass(srcData, srcFs, tgtFs / 2);
    didAA = true;
end

% --- Interpolate channel-by-channel onto the grid ------------------------
vals = nan(numel(tgt), size(srcData, 2));
for c = 1:size(srcData, 2)
    x = srcData(:, c);
    valid = ~isnan(x) & ~isnan(srcTime);
    if nnz(valid) < 2
        continue;   % leave NaN
    end
    tv = srcTime(valid);
    xv = x(valid);
    % De-duplicate / sort time for interp1
    [tv, order] = sort(tv);
    xv = xv(order);
    [tv, ia] = unique(tv, 'stable');
    xv = xv(ia);
    vals(:, c) = interp1(tv, xv, tgt, method, NaN);
    % Blank target points that fall inside a source gap wider than MaxGap
    if isfinite(maxGap)
        vals(:, c) = blankWideGaps(vals(:, c), tgt, tv, maxGap);
    end
end

info = struct();
info.signal = sigName;
info.channels = sig.varNames(chanIdx);
info.srcFs = srcFs;
info.tgtFs = tgtFs;
info.offset = offset;
info.antiAliased = didAA;
info.nNaN = nnz(isnan(vals));
info.nInterp = numel(vals) - info.nNaN;

end

%%_Subfunctions_________________________________________________________

function fs = estimateFs(t)
% ESTIMATEFS Robust sampling-rate estimate from a time vector
dt = median(diff(t(:)), 'omitnan');
if isempty(dt) || ~isfinite(dt) || dt <= 0
    fs = NaN;
else
    fs = 1 / dt;
end
end

function y = antiAliasLowpass(x, fs, cutoff)
% ANTIALIASLOWPASS Zero-phase Hann moving-average low-pass (NaN-aware)
%   Cutoff is approximate; window length ~ fs/cutoff samples. No toolbox use.

win = max(3, round(fs / max(cutoff, eps)));
if mod(win, 2) == 0
    win = win + 1;   % odd length keeps it centered
end
k = hann(win);
k = k / sum(k);

y = x;
for c = 1:size(x, 2)
    xc = x(:, c);
    nanMask = isnan(xc);
    if all(nanMask)
        continue;
    end
    % Fill NaNs by nearest for filtering, then restore
    xf = fillNearest(xc, nanMask);
    yc = zeroPhaseConv(xf, k);
    yc(nanMask) = NaN;
    y(:, c) = yc;
end

end

function w = hann(n)
% HANN Hann window of length n (avoids Signal Processing Toolbox dependency)
if n == 1
    w = 1;
    return;
end
w = 0.5 * (1 - cos(2 * pi * (0:n-1)' / (n - 1)));
end

function y = zeroPhaseConv(x, k)
% ZEROPHASECONV Symmetric (forward+reverse) moving-average via centered conv
half = (numel(k) - 1) / 2;
xp = [repmat(x(1), half, 1); x; repmat(x(end), half, 1)];   % edge-pad
yc = conv(xp, k, 'same');
y = yc(half + 1 : half + numel(x));
end

function xf = fillNearest(x, nanMask)
% FILLNEAREST Replace NaNs with nearest valid sample (for filtering only)
idx = find(~nanMask);
if isempty(idx)
    xf = x;
    return;
end
allI = (1:numel(x))';
nn = interp1(idx, idx, allI, 'nearest', 'extrap');
xf = x(nn);
end

function y = blankWideGaps(y, tgt, srcValidTime, maxGap)
% BLANKWIDEGAPS NaN-out target points inside source gaps wider than maxGap
gaps = diff(srcValidTime);
wide = find(gaps > maxGap);
for g = wide(:)'
    lo = srcValidTime(g);
    hi = srcValidTime(g + 1);
    y(tgt > lo & tgt < hi) = NaN;
end
end
