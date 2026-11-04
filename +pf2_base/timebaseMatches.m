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
%   tf - true when data.info.timebase has fs, nSamples and medianStep, the
%        sample count equals nSamples and the median step of time equals
%        medianStep (relative tolerance 1e-9)
%
% See also: pf2_base.nirCounterTimebase, pf2.import.importNIR

tf = false;
if ~isstruct(data) || ~isfield(data, 'info') || ~isstruct(data.info) ...
        || ~isfield(data.info, 'timebase') || ~isstruct(data.info.timebase)
    return;
end
tb = data.info.timebase;
if ~all(isfield(tb, {'fs', 'nSamples', 'medianStep'})) || isempty(time) || numel(time) < 2
    return;
end
step = median(diff(time(:)));
tf = numel(time) == tb.nSamples && abs(step - tb.medianStep) <= 1e-9 * abs(tb.medianStep);
end
