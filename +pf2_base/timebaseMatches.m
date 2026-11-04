function tf = timebaseMatches(data, time)
% TIMEBASEMATCHES True when data.info.timebase still describes this time vector
%
% A COBI .nir counter time base (pf2_base.nirCounterTimebase) stores the
% sampling rate fitted from the counter tick. That rate applies only to the
% time vector it was computed for: after resampling, cutting or splicing,
% the sample count or the median step no longer match and the rate must be
% taken from the time vector instead.
%
% Syntax:
%   tf = pf2_base.timebaseMatches(data, time)
%
% Inputs:
%   data - fNIRS data struct, possibly with .info.timebase
%   time - Time vector to check [N x 1]
%
% Outputs:
%   tf - true when data.info.timebase has fs and a time signature (sample
%        count, span time(end)-time(1), median step) that the time vector
%        still matches (relative tolerance 1e-9). The signature does not
%        change when the time is shifted (setT0), but resampling or cutting
%        changes it, including a resample to the same length on a regular
%        grid.
%
% See also: pf2_base.nirCounterTimebase, pf2.import.importNIR

tf = false;
if ~isstruct(data) || ~isfield(data, 'info') || ~isstruct(data.info) ...
        || ~isfield(data.info, 'timebase') || ~isstruct(data.info.timebase)
    return;
end
tb = data.info.timebase;
if ~isfield(tb, 'fs') || isempty(time) || numel(time) < 2
    return;
end
time = double(time(:));
sig = [numel(time), time(end) - time(1), median(diff(time))];
if isfield(tb, 'timeSignature') && numel(tb.timeSignature) == 3
    ref = tb.timeSignature(:)';
elseif all(isfield(tb, {'nSamples', 'medianStep'}))
    ref = [tb.nSamples, NaN, tb.medianStep];   % older QC without a span
else
    return;
end
ok = abs(sig - ref) <= 1e-9 * max(abs(ref), 1);
ok(isnan(ref)) = true;
tf = all(ok);
end
