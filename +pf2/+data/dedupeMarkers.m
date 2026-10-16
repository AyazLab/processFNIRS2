function out = dedupeMarkers(data, varargin)
% DEDUPEMARKERS Collapse near-duplicate markers firing within a tolerance
%
% Removes near-duplicate event markers, where "near-duplicate" means a row
% that shares the same marker Code as, and falls within a small time tolerance
% of, an earlier KEPT row (the cluster anchor). Such duplicates typically come
% from bouncing trigger lines, repeated serial sends, or a stimulus that
% re-fires the same code in quick succession.
%
% The dedup is anchor-based, not run-collapsing: per Code, the earliest row
% becomes the anchor and any later same-code row within Tolerance of THAT
% anchor is dropped. When a row falls outside the window it is kept and
% becomes the new anchor. So, at Tolerance = 0.05 s, onsets at 0, 0.04, 0.08
% keep BOTH 0 and 0.08 (0.08 is > 0.05 past the 0 anchor) and drop only 0.04 -
% it does NOT collapse the whole run to a single row.
%
% Reference:
%   Internal pf2 implementation.
%
% Syntax:
%   data    = pf2.data.dedupeMarkers(data)
%   data    = pf2.data.dedupeMarkers(data, 'Tolerance', tol)
%   markers = pf2.data.dedupeMarkers(markerTable, ...)
%   ...     = pf2.data.dedupeMarkers(..., 'Name', Value)
%
% Inputs:
%   data - fNIRS data struct with a .markers table, or a marker table/matrix
%          directly. A struct returns a struct (with .markers deduped); a
%          table/matrix returns a deduped canonical table.
%
% Name-Value Parameters:
%   'Tolerance' - Time window in seconds within which two same-code markers
%                 are treated as duplicates (default: 0.05). Markers of the
%                 same Code whose Time falls within this gap of the kept
%                 (earliest) row of the cluster are removed. Larger values
%                 collapse more aggressively.
%   'Verbose'   - Print the number of markers removed (default: true).
%
% Outputs:
%   out - Same form as input (struct or table) with near-duplicate marker
%         rows removed. Surviving rows are returned sorted by ascending Time
%         (chronological), regardless of input order; extra columns are kept.
%
% Algorithm:
%   1. Normalize markers to the canonical table (Time, Code, Duration,
%      Amplitude + extras) so matrix/table inputs both work.
%   2. Sort rows by Time (stable) and walk them per Code, anchoring each
%      cluster on its earliest row.
%   3. Drop any same-code row whose Time is within Tolerance of the cluster
%      anchor (the window is measured from the anchor, so a run is NOT fully
%      collapsed); a row outside the window is kept and becomes the new anchor.
%   4. Return the surviving rows sorted by ascending Time.
%
% Example:
%   % Collapse trigger bounce within 50 ms on the sample data
%   data = pf2.import.sampleData();
%   data = pf2.data.dedupeMarkers(data);
%
%   % Operate on a marker table directly, wider tolerance, quietly
%   m = pf2_base.normalizeMarkers([10 49; 10.02 49; 30 49]);
%   m = pf2.data.dedupeMarkers(m, 'Tolerance', 0.1, 'Verbose', false);
%
% Notes:
%   - Duplicate detection is per Code: same-time markers with DIFFERENT
%     codes are never collapsed.
%   - 'Tolerance' = 0 disables deduplication (nothing is removed).
%   - The window is measured from each cluster's anchor (earliest kept row),
%     so a long run of closely-spaced repeats is thinned, not collapsed to
%     a single row.
%   - Survivors are returned sorted by ascending Time even if the input was
%     unsorted; extra/user marker columns ride along with their rows.
%
% See also: pf2.data.removeMarkers, pf2.data.defineBlocks, ...
%           pf2.data.getMarkers, pf2_base.normalizeMarkers

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
opts = pf2_base.args.parse('dedupeMarkers', varargin, {}, {
    'Tolerance', (0.05), '1,1', '', {@mustBeNumeric, @mustBeNonnegative}
    'Verbose',   (true), '1,1', 'logical', {}
    });

% --- Cell array input: apply to each element ---
if iscell(data)
    fwd = namedargs2cell(opts);
    out = data;
    for ci = 1:numel(data)
        out{ci} = pf2.data.dedupeMarkers(data{ci}, fwd{:});
    end
    return;
end

tol = opts.Tolerance;
verbose = opts.Verbose;

% --- Resolve the marker table from the input form ---
isStructInput = isstruct(data) && isfield(data, 'markers');
if isStructInput
    mt = pf2_base.normalizeMarkers(data.markers);
elseif istable(data) || isnumeric(data)
    mt = pf2_base.normalizeMarkers(data);
else
    error('pf2:dedupeMarkers:badInput', ...
        ['First argument must be an fNIRS struct with .markers, a marker ', ...
         'table/matrix, or a cell array.']);
end

nBefore = height(mt);

% --- Nothing to do for empty or single-row marker sets ---
if nBefore <= 1
    if verbose
        fprintf('pf2.data.dedupeMarkers: removed 0 of %d markers.\n', nBefore);
    end
    out = packResult(data, mt, isStructInput);
    return;
end

% --- Sort chronologically (stable) and find duplicate clusters per code ---
times = mt.Time;
codes = mt.Code;
[~, sortOrd] = sortrows([times, codes], 1);  % stable sort by Time

keepSorted = true(nBefore, 1);
% Walk the time-sorted rows; per Code, hold the time of the current cluster
% ANCHOR (its earliest kept row). Drop a row within Tolerance of that anchor;
% otherwise keep it and make it the new anchor. The window is measured from
% the anchor, not the previous row, so it does not chain indefinitely.
anchorTimeByCode = containers.Map('KeyType', 'double', 'ValueType', 'double');
for r = 1:nBefore
    idx = sortOrd(r);
    c = codes(idx);
    t = times(idx);
    if isKey(anchorTimeByCode, c)
        anchorT = anchorTimeByCode(c);
        if (t - anchorT) <= tol
            keepSorted(idx) = false;   % within tolerance of cluster anchor: drop
            continue;                  % anchor unchanged (window stays on anchor)
        end
    end
    anchorTimeByCode(c) = t;           % start (or advance) this code's anchor
end

% Surviving rows, returned in ascending Time order (chronological). sortrows
% is stable, so same-Time rows keep their relative order and extra/user
% columns ride along with their row.
mtOut = sortrows(mt(keepSorted, :), 'Time');
nRemoved = nBefore - height(mtOut);

if verbose
    fprintf('pf2.data.dedupeMarkers: removed %d of %d markers (Tolerance = %g s).\n', ...
        nRemoved, nBefore, tol);
end

out = packResult(data, mtOut, isStructInput);

end

%%_Subfunctions_________________________________________________________

function out = packResult(data, mt, isStructInput)
% PACKRESULT Return the deduped markers in the same form as the input
%
% Inputs:
%   data          - Original input (struct or table/matrix)
%   mt            - Deduped canonical marker table
%   isStructInput - True if the original input was an fNIRS struct
%
% Outputs:
%   out - Struct (with .markers replaced) or the marker table directly

if isStructInput
    data.markers = mt;
    out = data;
else
    out = mt;
end

end
