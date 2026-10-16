function out = removeMarkers(data, varargin)
% REMOVEMARKERS Remove marker rows by code, time window, or row index
%
% Drops rows from the event marker table selected by marker Code, by a time
% window, by explicit row indices, or any combination of these. Useful for
% stripping spurious device markers, trimming events outside an analysis
% window, or surgically removing known-bad triggers before epoching. Extra
% (user) columns and the canonical table class are preserved on the survivors.
%
% Reference:
%   Internal pf2 implementation.
%
% Syntax:
%   data    = pf2.data.removeMarkers(data, codes)
%   data    = pf2.data.removeMarkers(data, codes, 'Time', [t1 t2])
%   data    = pf2.data.removeMarkers(data, 'Time', [t1 t2])
%   data    = pf2.data.removeMarkers(data, 'Indices', idx)
%   markers = pf2.data.removeMarkers(markerTable, ...)
%   ...     = pf2.data.removeMarkers(..., 'Name', Value)
%
% Inputs:
%   data  - fNIRS data struct with a .markers table, or a marker table/matrix
%           directly. A struct returns a struct (with .markers filtered); a
%           table/matrix returns the filtered canonical table.
%   codes - (Optional positional) Marker code or vector of codes to remove
%           [numeric]. Rows whose Code matches any listed code are dropped.
%
% Name-Value Parameters:
%   'Time'    - Time window [t1 t2] in seconds; rows with t1 <= Time <= t2 are
%               removed (default: [] = off).
%   'Indices' - Row indices into the (normalized) marker table to remove
%               (default: [] = off). Logical or numeric.
%   'Verbose' - Print the number of markers removed (default: true).
%
% Outputs:
%   out - Same form as input (struct or table) with the selected marker rows
%         removed. A row is removed if it matches ANY of the active selectors
%         (codes OR Time window OR Indices).
%
% Algorithm:
%   1. Normalize markers to the canonical table so matrix/table inputs work.
%   2. Build a removal mask: union of code matches, in-window times, and the
%      requested row indices. At least one selector must be supplied.
%   3. Keep the complementary rows, preserving order and extra columns.
%
% Example:
%   % Remove all device markers with code 0
%   data = pf2.data.removeMarkers(data, 0);
%
%   % Remove markers in the first 10 seconds, and any code-99 marker
%   data = pf2.data.removeMarkers(data, 99, 'Time', [0 10]);
%
%   % Remove specific rows from a marker table directly
%   m = pf2.data.removeMarkers(data.markers, 'Indices', [2 5]);
%
% Notes:
%   - Selectors combine by UNION (OR): a row is removed if it matches ANY of
%     the supplied code / 'Time' / 'Indices' selectors, not all of them.
%   - At least one selector is required; calling with none errors
%     (pf2:removeMarkers:noSelector).
%   - The 'Time' window is inclusive on both ends (t1 <= Time <= t2).
%   - 'Indices' refer to rows of the NORMALIZED marker table (row order is
%     preserved by normalizeMarkers); out-of-range indices are ignored.
%
% See also: pf2.data.dedupeMarkers, pf2.data.getMarkers, ...
%           pf2.data.defineBlocks, pf2_base.normalizeMarkers

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
[codes, opts] = pf2_base.args.parse('removeMarkers', varargin, {
    'codes', ([]), '', '', {@mustBeNumeric}
    }, {
    'Time',    ([]), '', '', {@mustBeNumeric}
    'Indices', ([]), '', '', {}
    'Verbose', (true), '1,1', 'logical', {}
    });

% --- Cell array input: apply to each element ---
if iscell(data)
    fwd = namedargs2cell(opts);
    out = data;
    for ci = 1:numel(data)
        out{ci} = pf2.data.removeMarkers(data{ci}, codes, fwd{:});
    end
    return;
end

timeWin = opts.Time;
indices = opts.Indices;
verbose = opts.Verbose;

if isempty(codes) && isempty(timeWin) && isempty(indices)
    error('pf2:removeMarkers:noSelector', ...
        ['Specify at least one selector: a code (or code vector), ', ...
         '''Time'', [t1 t2], or ''Indices'', idx.']);
end

% --- Resolve the marker table from the input form ---
isStructInput = isstruct(data) && isfield(data, 'markers');
if isStructInput
    mt = pf2_base.normalizeMarkers(data.markers);
elseif istable(data) || isnumeric(data)
    mt = pf2_base.normalizeMarkers(data);
else
    error('pf2:removeMarkers:badInput', ...
        ['First argument must be an fNIRS struct with .markers, a marker ', ...
         'table/matrix, or a cell array.']);
end

nBefore = height(mt);
removeMask = false(nBefore, 1);

if nBefore > 0
    % Code selector
    if ~isempty(codes)
        removeMask = removeMask | ismember(mt.Code, codes(:));
    end
    % Time-window selector
    if ~isempty(timeWin)
        lo = min(timeWin);
        hi = max(timeWin);
        removeMask = removeMask | (mt.Time >= lo & mt.Time <= hi);
    end
    % Index selector
    if ~isempty(indices)
        if islogical(indices)
            idxMask = false(nBefore, 1);
            n = min(numel(indices), nBefore);
            idxMask(1:n) = indices(1:n);
        else
            idx = indices(indices >= 1 & indices <= nBefore);
            idxMask = false(nBefore, 1);
            idxMask(round(idx)) = true;
        end
        removeMask = removeMask | idxMask;
    end
end

mtOut = mt(~removeMask, :);
nRemoved = nBefore - height(mtOut);

if verbose
    fprintf('pf2.data.removeMarkers: removed %d of %d markers.\n', nRemoved, nBefore);
end

if isStructInput
    data.markers = mtOut;
    out = data;
else
    out = mtOut;
end

end
