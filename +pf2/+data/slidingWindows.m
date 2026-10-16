function blocks = slidingWindows(data, varargin)
% SLIDINGWINDOWS Define fixed-length sliding-window blocks over a recording
%
% Tiles a continuous recording with fixed-length time windows at a regular
% step, producing a block definition array in the same format as
% pf2.data.defineBlocks. Unlike defineBlocks (which is event-locked to
% markers), this covers the whole recording on a regular grid - the layer
% needed for dynamic functional connectivity, resting-state analysis,
% windowed quality control, and fixed-length model input. The returned
% blocks feed straight into pf2.data.extractBlocks.
%
% Reference:
%   Leonardi, N., & Van De Ville, D. (2015). On spurious and real fluctuations
%   of dynamic functional connectivity during rest. NeuroImage, 104, 430-436.
%   DOI: 10.1016/j.neuroimage.2014.09.007
%
% Syntax:
%   blocks = pf2.data.slidingWindows(data, 'Length', 10)
%   blocks = pf2.data.slidingWindows(data, 'Length', 10, 'Step', 5)
%   blocks = pf2.data.slidingWindows(data, 'Length', 10, 'Overlap', 0.5)
%   blocks = pf2.data.slidingWindows(data, 'Length', 10, 'Start', 30, 'End', 300)
%   data    = pf2.data.slidingWindows(data, 'Length', 10, 'Embed', true)
%   allData = pf2.data.slidingWindows(allData, 'Length', 10, 'Embed', true)
%
% Inputs:
%   data        - fNIRS data struct with a .time field, or a cell array of
%                 such structs (each tiled independently; requires 'Embed').
%
% Name-Value Parameters:
%   'Length'    - Window length in seconds (required, > 0).
%   'Step'      - Step between consecutive window starts in seconds
%                 (default: Length, i.e. contiguous non-overlapping windows).
%                 Mutually exclusive with 'Overlap'.
%   'Overlap'   - Fractional overlap in [0, 1); sets Step = Length*(1-Overlap)
%                 (default: []). Mutually exclusive with 'Step'.
%   'Start'     - First window start time in seconds (default: min(data.time)).
%   'End'       - Last allowed window end time in seconds (default: max(data.time)).
%   'Partial'   - Keep a trailing window shorter than Length when the grid
%                 does not divide evenly (default: false).
%   'Condition' - Label stored in each window's info.(ConditionField)
%                 (default: '', no label).
%   'ConditionField' - Field name for the Condition label (default: 'Condition').
%   'Embed'     - Store the blocks on data.blocks and return the data struct
%                 instead of the blocks array (default: true). Set false to
%                 return just the blocks struct array.
%
% Outputs:
%   blocks - Struct array [1 x N] (or the data struct if Embed=true) with the
%            same fields as pf2.data.defineBlocks:
%              .startTime   - Window start in seconds (absolute)
%              .endTime     - Window end in seconds
%              .duration    - endTime - startTime
%              .markerCode  - NaN (not marker-driven)
%              .markerIndex - NaN
%              .amplitude   - 1
%              .info        - Struct with:
%                             .BlockNumber  - Sequential 1, 2, 3...
%                             .WindowNumber - Same as BlockNumber
%                             .WindowOnset  - startTime (seconds)
%                             .(ConditionField) - label if 'Condition' given
%
% Algorithm:
%   1. Resolve the time span [Start, End] and the step from Step/Overlap
%   2. Generate window starts Start, Start+Step, ... until a window would
%      exceed End (or, with Partial, until the start passes End)
%   3. Build a defineBlocks-compatible struct array, one entry per window
%   4. Optionally embed the blocks on the data struct
%
% Example:
%   % 10 s windows, 50% overlap, for dynamic connectivity
%   data    = pf2.import.sampleData();
%   proc    = processFNIRS2(data);
%   blocks  = pf2.data.slidingWindows(proc, 'Length', 10, 'Overlap', 0.5, 'Embed', false);
%   windows = pf2.data.extractBlocks(proc, blocks, 'PreTime', 0, 'PostTime', 0);
%
%   % Contiguous 30 s windows embedded on the struct
%   proc    = pf2.data.slidingWindows(proc, 'Length', 30);   % Embed defaults true
%   windows = pf2.data.extractBlocks(proc, 'PreTime', 0, 'PostTime', 0);
%
% Notes:
%   - Set 'PreTime', 0 and 'PostTime', 0 in extractBlocks so each segment is
%     exactly the window (extractBlocks otherwise pads by 120 s by default).
%   - For dynamic functional connectivity, the window must be long enough to
%     resolve the lowest frequency of interest: 'Length' >= 1/f_low. fNIRS
%     hemodynamic/neural fluctuations sit near 0.01-0.04 Hz, implying windows
%     of ~30-100 s; a 10 s window mostly captures Mayer-wave/systemic activity,
%     not neural co-fluctuation (Leonardi & Van De Ville, 2015, NeuroImage).
%   - Overlapping windows are not statistically independent; high overlap
%     inflates the effective sample size for downstream tests.
%   - Windowed estimates assume approximate stationarity within each window
%     and grow noisier as windows shrink (a bias-variance trade-off).
%   - For event-related/task designs, use pf2.data.defineBlocks (marker-locked)
%     instead; sliding windows are for resting-state/continuous recordings.
%
% See also: pf2.data.defineBlocks, pf2.data.extractBlocks, pf2.data.split

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
opts = pf2_base.args.parse('slidingWindows', varargin, {}, {
    'Length',         ([]), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}
    'Step',           ([]), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}
    'Overlap',        ([]), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBeNonnegative, @(v) mustBeLessThan(v, 1)}
    'Start',          ([]), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty}
    'End',            ([]), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty}
    'Partial',        (false), '1,1', 'logical', {}
    'Condition',      (''), '', '', {@mustBeText}
    'ConditionField', ('Condition'), '', '', {@mustBeText}
    'Embed',          (true), '1,1', 'logical', {}
    });

% --- Cell array input: apply to each element (requires Embed) ---
if iscell(data)
    fwd = namedargs2cell(opts);
    blocks = data;
    for ci = 1:numel(data)
        blocks{ci} = pf2.data.slidingWindows(data{ci}, fwd{:});
    end
    return;
end

winLen = opts.Length;
if isempty(winLen)
    error('pf2:slidingWindows:noLength', ...
        '''Length'' (window length in seconds) is required.');
end

% Validate data
if ~isstruct(data) || ~isfield(data, 'time') || isempty(data.time)
    error('pf2:slidingWindows:noTime', ...
        'First argument must be an fNIRS struct with a non-empty .time field.');
end

% Resolve step from Step / Overlap (mutually exclusive)
if ~isempty(opts.Step) && ~isempty(opts.Overlap)
    error('pf2:slidingWindows:stepAndOverlap', ...
        'Specify only one of ''Step'' or ''Overlap''.');
end
if ~isempty(opts.Overlap)
    step = winLen * (1 - opts.Overlap);
elseif ~isempty(opts.Step)
    step = opts.Step;
else
    step = winLen;   % contiguous, non-overlapping
end

% Resolve time span
tMin = min(data.time);
tMax = max(data.time);
if isempty(opts.Start); winStart0 = tMin; else; winStart0 = opts.Start; end
if isempty(opts.End);   spanEnd   = tMax; else; spanEnd   = opts.End;   end

partial = opts.Partial;
condLabel = char(opts.Condition);
condField = char(opts.ConditionField);

if spanEnd <= winStart0
    error('pf2:slidingWindows:emptySpan', ...
        'Resolved End (%.2f s) must be greater than Start (%.2f s).', spanEnd, winStart0);
end

% --- Generate window start times ---
% Small tolerance so floating-point start grids reach the final full window.
tol = step * 1e-9;
if partial
    starts = winStart0 : step : (spanEnd - tol);
else
    starts = winStart0 : step : (spanEnd - winLen + tol);
end

% Build empty-typed struct array template (matches defineBlocks fields)
emptyBlocks = struct('startTime', {}, 'endTime', {}, 'duration', {}, ...
    'markerCode', {}, 'markerIndex', {}, 'amplitude', {}, 'info', {});

if isempty(starts)
    if winLen > (spanEnd - winStart0)
        warning('pf2:slidingWindows:windowTooLong', ...
            ['Window length (%.2f s) exceeds the span (%.2f s); no full windows. ', ...
             'Pass ''Partial'', true to keep a single short window.'], ...
            winLen, spanEnd - winStart0);
    end
    blocks = emptyBlocks;
    if opts.Embed
        data.blocks = blocks;
        blocks = data;
    end
    return;
end

nWin = numel(starts);
blocks = repmat(struct('startTime', 0, 'endTime', 0, 'duration', 0, ...
    'markerCode', NaN, 'markerIndex', NaN, 'amplitude', 1, 'info', struct()), 1, nWin);

for k = 1:nWin
    st = starts(k);
    et = st + winLen;
    if partial && et > spanEnd
        et = spanEnd;   % clip trailing partial window
    end
    blocks(k).startTime  = st;
    blocks(k).endTime    = et;
    blocks(k).duration   = et - st;
    blocks(k).markerCode = NaN;
    blocks(k).markerIndex = NaN;
    blocks(k).amplitude  = 1;

    info = struct();
    info.BlockNumber  = k;
    info.WindowNumber = k;
    info.WindowOnset  = st;
    if ~isempty(condLabel)
        info.(condField) = condLabel;
    end
    blocks(k).info = info;
end

% --- Embed on the data struct if requested ---
if opts.Embed
    data.blocks = blocks;
    blocks = data;
end

end
