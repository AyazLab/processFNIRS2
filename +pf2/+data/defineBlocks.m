function blocks = defineBlocks(data, varargin)
% DEFINEBLOCKS Create block definition struct array from event markers
%
% Parses fNIRS markers into a block definition array describing time
% windows for epoching, GLM design matrices, or connectivity analysis.
% Supports simple positional syntax for common cases and name-value
% parameters for advanced configuration.
%
% Syntax:
%   blocks = pf2.data.defineBlocks(data, markerCodes)
%   blocks = pf2.data.defineBlocks(data, markerCodes, duration)
%   blocks = pf2.data.defineBlocks(data, markerCodes, 'EndMarker', endCode)
%   blocks = pf2.data.defineBlocks(data, 'MarkerCode', code, 'Duration', dur)
%   blocks = pf2.data.defineBlocks(data, 'MarkerCode', code, 'EndMarker', endCode)
%   blocks = pf2.data.defineBlocks(data, 'StartMarker', s, 'EndMarker', e)
%   data   = pf2.data.defineBlocks(data, ..., 'Embed', true)
%   allData = pf2.data.defineBlocks(allData, ..., 'Embed', true) % cell array
%   blocks = pf2.data.defineBlocks(data, ..., 'Name', Value)
%
% Inputs:
%   data         - fNIRS data structure with .markers field, or a cell
%                  array of fNIRS structs (requires 'Embed', true)
%                  Markers are a canonical table with variables .Time,
%                  .Code, .Duration, .Amplitude (+ optional extra columns)
%   markerCodes  - (Optional positional) Marker code(s) to find [numeric]
%                  Scalar or vector; all codes are treated as separate block types.
%   duration     - (Optional positional) Fixed block duration in seconds [scalar]
%                  If omitted and markers have nonzero .Duration values,
%                  those durations are used automatically.
%
% Name-Value Parameters:
%   'MarkerCode'   - Marker code(s) to define blocks [scalar or vector]
%   'Duration'     - Fixed duration in seconds for each block (default: 0)
%                    If 0 and markers have nonzero .Duration values, those
%                    are used. Otherwise blocks have zero duration.
%   'UseDuration'  - Force use of duration from markers .Duration (default: false)
%   'StartMarker'  - Start marker code(s) for paired extraction [scalar or column vector]
%   'EndMarker'    - End marker code(s) for paired extraction [scalar or column vector]
%                    Can be used with StartMarker or MarkerCode.
%                    Must match StartMarker/MarkerCode length or be scalar.
%   'ConditionMap' - Cell array mapping marker codes to labels (default: {})
%                    Two-column: {code1, 'Label1'; code2, 'Label2'}
%                    Multi-column: {code1, 'Easy', 'Stroop'; code2, 'Hard', 'Stroop'}
%                    Extra columns map to extra fields via ConditionField.
%                    When omitted and data.info.eventTypes exists (from BIDS
%                    events.tsv), the mapping is auto-populated for requested codes.
%   'ConditionField' - Field name(s) for ConditionMap labels (default: 'Condition')
%                      Char for single field, cell array for multiple:
%                      {'Condition', 'Task'} maps columns 2, 3 of ConditionMap.
%   'InfoTable'    - Table with one row per block (default: [])
%                    Column names become .info fields for each block.
%   'InfoFields'   - Struct of constant fields applied to all blocks (default: struct())
%   'MinDuration'  - Reject blocks shorter than this in seconds (default: 0)
%   'MaxDuration'  - Reject blocks longer than this in seconds (default: Inf)
%   'SortByTime'   - Sort blocks chronologically (default: true)
%   'PrePad'       - Seconds to include before block start (default: 0)
%                    Shifts startTime earlier by this amount.
%   'PostPad'      - Seconds to include after block end (default: 0)
%                    Shifts endTime later by this amount.
%   'MarkerWindow' - Which block window attributes marker rows to a block for
%                    auto-promotion of per-trial extra columns (default 'core'):
%                    'core'   - the original PRE-PAD block window, so PrePad/
%                               PostPad cannot pull a neighbouring block's onset
%                               marker into this block (the safe default).
%                    'padded' - the widened (post-pad) window, to deliberately
%                               attribute markers that fall in the pad region.
%   'Embed'        - Store blocks on data.blocks and return the data struct
%                    instead of the blocks array (default: true).
%                    Set false to return just the blocks struct array.
%
% Outputs:
%   blocks - Struct array [1 x N] (or data struct if Embed=true) with fields:
%            .startTime   - Block start time in seconds (absolute)
%            .endTime     - Block end time in seconds
%            .duration    - endTime - startTime in seconds
%            .markerCode  - Marker code that triggered this block
%            .markerIndex - Row index into data.markers
%            .amplitude   - Marker amplitude from .Amplitude (default 1)
%            .info        - Struct with block-level metadata:
%                           .BlockNumber - Sequential 1, 2, 3...
%                           .(ConditionField) - From ConditionMap (default 'Condition')
%                           .(extraColumn) - Any marker EXTRA column (e.g. RT)
%                              that resolves to a single value for the block is
%                              auto-promoted here for Experiment groupby/plots,
%                              but only for fields not already set by an
%                              explicit source (ConditionMap/InfoTable/
%                              InfoFields), which take precedence.
%                           ... any user fields from InfoTable/InfoFields
%
% Algorithm:
%   1. Normalize markers to the canonical table (.Time, .Code, .Duration,
%      .Amplitude) and read out the numeric values needed below
%   2. Select mode: MarkerCode (fixed duration), MarkerCode+EndMarker
%      (pair start codes with terminating marker), or StartMarker+EndMarker
%   3. For MarkerCode: duration from fixed > marker .Duration > zero
%      For MarkerCode+EndMarker or StartMarker+EndMarker: pair each start
%      with the next available end marker to determine duration
%   4. Build struct array with startTime, endTime, duration, markerCode, markerIndex
%   5. Apply PrePad/PostPad to extend block boundaries
%   6. Auto-populate ConditionMap from data.info.eventTypes if not provided
%   7. Apply ConditionMap, InfoTable, InfoFields to .info (explicit sources)
%   8. Auto-promote single-valued marker EXTRA columns into any block .info
%      field those explicit sources left unset (explicit sources take
%      precedence over promotion)
%   9. Filter by MinDuration/MaxDuration, sort by time
%
%   A near-duplicate onset check warns (pf2:defineBlocks:nearDuplicateOnsets)
%   when two consecutive same-code markers fall within 0.05 s. The check is
%   limited to the codes being extracted (markerCode/startMarker) so a bounce
%   on an un-extracted code does not raise a false alarm; clean flagged codes
%   with pf2.data.dedupeMarkers.
%
%   An empty result is always reported rather than returned silently, each
%   with its own identifier so batch scripts can turn it off:
%     pf2:defineBlocks:noMarkers         - data.markers has no rows
%     pf2:defineBlocks:codesNotFound     - none of the requested marker (or
%                                          end marker) codes occur; lists the
%                                          codes present, and notes non-integer
%                                          codes, which usually mean the marker
%                                          columns are out of order
%     pf2:defineBlocks:noPairedBlocks    - start codes occur but no end marker
%                                          follows them
%     pf2:defineBlocks:allBlocksFiltered - every block falls outside
%                                          MinDuration/MaxDuration
%   Messages name the recording (info.filename or info.SubjectID) when set.
%
% Example:
%   % Simple: marker codes + fixed duration
%   blocks = pf2.data.defineBlocks(data, [49, 50], 30);
%
%   % Auto-detect duration from marker .Duration
%   blocks = pf2.data.defineBlocks(data, 49);
%
%   % Marker code + end marker (duration from terminating marker)
%   blocks = pf2.data.defineBlocks(data, [49, 50], 'EndMarker', 51);
%
%   % Per-code end markers: 49->59, 48->58
%   blocks = pf2.data.defineBlocks(data, [49, 48], 'EndMarker', [59, 58]);
%
%   % Start/end pairs with condition mapping
%   blocks = pf2.data.defineBlocks(data, ...
%       'StartMarker', [50; 51], 'EndMarker', [52; 53], ...
%       'ConditionMap', {50, 'Natural'; 51, 'Synthetic'});
%
%   % With pre/post padding and metadata
%   blocks = pf2.data.defineBlocks(data, 49, 30, ...
%       'PrePad', 5, 'PostPad', 2, ...
%       'ConditionMap', {49, 'Stroop'});
%
%   % Embed blocks on the data struct (returns data, not blocks)
%   data = pf2.data.defineBlocks(data, [49,50], 30, 'Embed', true);
%   segments = pf2.data.extractBlocks(data);  % uses data.blocks
%
%   % Cell array: embed blocks on every subject in one call
%   allData = pf2.data.defineBlocks(allData, [49,50], 30, ...
%       'ConditionMap', {49,'Easy';50,'Hard'}, 'Embed', true);
%   segments = pf2.data.extractBlocks(allData);
%
%   % BIDS auto-labeling: when data has .info.eventTypes from events.tsv,
%   % ConditionMap is auto-populated (no manual mapping needed)
%   data = pf2.import.importSNIRF('sub-01_nirs.snirf');
%   blocks = pf2.data.defineBlocks(data, [1, 2, 3]);  % auto-labeled
%
% See also: pf2.data.extractBlocks, pf2.data.getMarkers, pf2.data.split, ...
%           pf2.data.dedupeMarkers, pf2.data.removeMarkers

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
[markerCodes, duration, opts] = pf2_base.args.parse('defineBlocks', varargin, {
    'markerCodes', ([]), '', '', {@mustBeNumeric}
    'duration',    ([]), '', '', {@mustBeNumeric, @mustBeScalarOrEmpty}
    }, {
    'MarkerCode',     ([]), '', '', {@mustBeNumeric}
    'Duration',       (0), '1,1', '', {@mustBeNumeric, @mustBeNonnegative}
    'UseDuration',    (false), '1,1', 'logical', {}
    'StartMarker',    ([]), '', '', {@mustBeNumeric}
    'EndMarker',      ([]), '', '', {@mustBeNumeric}
    'ConditionMap',   ([]), '', '', {}
    'ConditionField', ('Condition'), '', '', {}
    'InfoTable',      ([]), '', '', {}
    'InfoFields',     (struct()), '1,1', 'struct', {}
    'MinDuration',    (0), '1,1', '', {@mustBeNumeric}
    'MaxDuration',    (Inf), '1,1', '', {@mustBeNumeric}
    'SortByTime',     (true), '1,1', 'logical', {}
    'PrePad',         (0), '1,1', '', {@mustBeNumeric, @mustBeNonnegative}
    'PostPad',        (0), '1,1', '', {@mustBeNumeric, @mustBeNonnegative}
    'MarkerWindow',   ('core'), '', '', {}
    'Embed',          (true), '1,1', 'logical', {}
    });

% --- Cell array input: apply to each element (requires Embed) ---
if iscell(data)
    fwd = namedargs2cell(opts);
    blocks = data;
    for ci = 1:numel(data)
        blocks{ci} = pf2.data.defineBlocks(data{ci}, markerCodes, duration, fwd{:});
    end
    return;
end

% Merge positional args with name-value (positional takes precedence)
if ~isempty(markerCodes)
    markerCode = markerCodes(:);  % Always treat as column (OR logic)
else
    markerCode = opts.MarkerCode;
end

if ~isempty(duration)
    fixedDuration = duration;
else
    fixedDuration = opts.Duration;
end

useDuration = opts.UseDuration;
startMarker = opts.StartMarker;
endMarker = opts.EndMarker;
conditionMap = opts.ConditionMap;
condMapProvided = iscell(conditionMap);  % [] default = not provided; a cell = provided
conditionField = opts.ConditionField;
if ischar(conditionField) || isstring(conditionField)
    conditionField = {char(conditionField)};
end
infoTable = opts.InfoTable;
infoFields = opts.InfoFields;
minDur = opts.MinDuration;
maxDur = opts.MaxDuration;
sortByTime = opts.SortByTime;
prePad = opts.PrePad;
postPad = opts.PostPad;
markerWindow = lower(char(opts.MarkerWindow));
embedBlocks = opts.Embed;

% Validate input data
if ~isstruct(data) || ~isfield(data, 'markers')
    error('pf2:defineBlocks:badInput', 'First argument must be an fNIRS struct with .markers field.');
end

% Validate mode: MarkerCode, MarkerCode+EndMarker, or StartMarker+EndMarker
hasMarkerCode = ~isempty(markerCode);
hasStartMarker = ~isempty(startMarker);
hasEndMarker = ~isempty(endMarker);

if ~hasMarkerCode && ~hasStartMarker
    error('pf2:defineBlocks:noMode', ...
        'Must specify marker codes or ''StartMarker''.');
end

if hasMarkerCode && hasStartMarker
    error('pf2:defineBlocks:ambiguousMode', ...
        'Cannot specify both marker codes and ''StartMarker''.');
end

if hasStartMarker && ~hasEndMarker
    error('pf2:defineBlocks:missingEndMarker', ...
        '''StartMarker'' requires ''EndMarker''.');
end

% Convert markers to a numeric array [time, value, duration, amplitude]
% for the positional column math in the block builders below. The stored
% data.markers field remains a canonical table.
mrk = pf2_base.markersToArray(data.markers);

% Near-duplicate onset check: two consecutive same-code markers within a small
% time tolerance usually indicate trigger bounce / repeated sends and will
% spawn overlapping near-identical blocks. Warn (do not auto-remove) and point
% the user at pf2.data.dedupeMarkers. The check is restricted to the codes
% actually being extracted by this call (markerCode / startMarker) so a bounce
% on an UN-extracted code (e.g. a device heartbeat) never raises a false alarm
% about overlapping blocks that will not exist. When no explicit code set is
% available, all codes are inspected (current behavior).
nearDupTol = 0.05;
if hasMarkerCode
    extractCodes = markerCode(:);
elseif hasStartMarker
    extractCodes = startMarker(:);
else
    extractCodes = [];
end
if ~isempty(mrk) && size(mrk, 1) > 1
    [srt, ~] = sortrows(mrk(:, [1 2]), 1);  % by Time
    if ~isempty(extractCodes)
        inSet = ismember(srt(:, 2), extractCodes);
    else
        inSet = true(size(srt, 1), 1);  % no code set: inspect everything
    end
    % Only flag a pair when BOTH rows are extracted codes of the same code.
    sameCode = (srt(2:end, 2) == srt(1:end-1, 2)) & inSet(2:end) & inSet(1:end-1);
    closeInTime = (srt(2:end, 1) - srt(1:end-1, 1)) <= nearDupTol;
    nNearDup = sum(sameCode & closeInTime);
    if nNearDup > 0
        warning('pf2:defineBlocks:nearDuplicateOnsets', ...
            ['Found %d near-duplicate marker onset(s) (same code within %g s). ', ...
             'These will create overlapping blocks. Consider cleaning markers ', ...
             'first with pf2.data.dedupeMarkers.'], nNearDup, nearDupTol);
    end
end

if isempty(mrk) || size(mrk, 1) == 0
    warning('pf2:defineBlocks:noMarkers', ...
        'data.markers is empty%s, so no blocks were defined.', recordingLabel(data));
    blocks = struct('startTime', {}, 'endTime', {}, 'duration', {}, ...
        'markerCode', {}, 'markerIndex', {}, 'amplitude', {}, 'info', {});
    if embedBlocks
        data.blocks = blocks;
        blocks = data;
    end
    return;
end

% Requested codes that match nothing return zero blocks; say so, since a
% malformed marker array (e.g. columns out of order) otherwise fails silently.
startCodes = extractCodes;
if hasMarkerCode && hasEndMarker
    startCodes = markerCode(:);
end
startFound = warnIfCodesMissing(mrk, startCodes, 'marker', data);
if hasEndMarker
    warnIfCodesMissing(mrk, endMarker(:), 'end marker', data);
end

% Build blocks based on mode
if hasMarkerCode && hasEndMarker
    % MarkerCode + EndMarker: use start/end pairing with MarkerCode as start
    blocks = buildFromStartEnd(mrk, markerCode, endMarker);
elseif hasMarkerCode
    blocks = buildFromMarkerCode(mrk, markerCode, fixedDuration, useDuration);
else
    blocks = buildFromStartEnd(mrk, startMarker, endMarker);
end

if isempty(blocks)
    if startFound && hasEndMarker
        warning('pf2:defineBlocks:noPairedBlocks', ...
            ['Start marker(s) %s occur%s but no end marker %s follows them, ', ...
             'so no blocks were defined.'], codeList(startCodes), ...
            recordingLabel(data), codeList(endMarker(:)));
    end
    if embedBlocks
        data.blocks = blocks;
        blocks = data;
    end
    return;
end

% Record the CORE (pre-pad) block bounds. Per-trial marker promotion below
% uses these by default (MarkerWindow='core') so that PrePad/PostPad widening
% does not pull a neighbouring block's onset marker into this block's window
% (which would make a per-trial extra column multi-valued and silently drop or
% misattribute it). MarkerWindow='padded' opts into the widened window.
coreStart = [blocks.startTime];
coreEnd   = [blocks.endTime];

% Apply PrePad / PostPad
if prePad > 0 || postPad > 0
    for k = 1:length(blocks)
        blocks(k).startTime = blocks(k).startTime - prePad;
        blocks(k).endTime = blocks(k).endTime + postPad;
        blocks(k).duration = blocks(k).endTime - blocks(k).startTime;
    end
end

% Sort by time (carry the core-bounds arrays along with the reorder)
if sortByTime
    [~, sortIdx] = sort([blocks.startTime]);
    blocks = blocks(sortIdx);
    coreStart = coreStart(sortIdx);
    coreEnd   = coreEnd(sortIdx);
end

% Assign BlockNumber
for k = 1:length(blocks)
    blocks(k).info.BlockNumber = k;
end

% Auto-populate ConditionMap from the dataset's marker dictionary when not
% explicitly provided (markerDict -> eventTypes -> COBI MarkerDict).
if ~condMapProvided && isstruct(data)
    dict = pf2.data.getMarkerDict(data);
    dict = dict(~ismissing(dict.Label), :);
    if ~isempty(dict)
        % Determine which codes are being extracted
        if hasMarkerCode
            allCodes = markerCode(:);
        elseif hasStartMarker
            allCodes = startMarker(:);
        else
            allCodes = [];
        end
        if ~isempty(allCodes)
            keep = ismember(dict.Code, allCodes);
            if any(keep)
                conditionMap = [num2cell(dict.Code(keep)), cellstr(dict.Label(keep))];
            end
        end
    end
end

% Apply ConditionMap
if ~isempty(conditionMap) && size(conditionMap, 2) >= 2
    mapCodes = cell2mat(conditionMap(:, 1));
    nFields = min(length(conditionField), size(conditionMap, 2) - 1);
    for k = 1:length(blocks)
        idx = find(mapCodes == blocks(k).markerCode, 1);
        if ~isempty(idx)
            for f = 1:nFields
                blocks(k).info.(conditionField{f}) = conditionMap{idx, f + 1};
            end
        end
    end
end

% Apply InfoTable (row k -> block k)
if ~isempty(infoTable)
    nRows = height(infoTable);
    nBlocks = length(blocks);
    nApply = min(nRows, nBlocks);
    colNames = infoTable.Properties.VariableNames;
    for k = 1:nApply
        for c = 1:length(colNames)
            val = infoTable.(colNames{c})(k);
            if iscell(val)
                blocks(k).info.(colNames{c}) = val{1};
            else
                blocks(k).info.(colNames{c}) = val;
            end
        end
    end
end

% Apply InfoFields (constant across all blocks)
if ~isempty(fieldnames(infoFields))
    fNames = fieldnames(infoFields);
    for k = 1:length(blocks)
        for f = 1:length(fNames)
            blocks(k).info.(fNames{f}) = infoFields.(fNames{f});
        end
    end
end

% Auto-promote scalar marker extras into block.info. For each block, inspect
% its marker rows (start marker, or all rows spanning the block window) and
% any EXTRA column (beyond Time/Code/Duration/Amplitude) that resolves to a
% single value for that block is copied into block.info.<colname>. This makes
% per-trial factors (e.g. an onset marker's RT, condition label) visible to
% the Experiment class for groupby/plotInfoBar.
%
% Precedence: explicit info sources (ConditionMap, InfoTable, InfoFields) win
% over promotion. This step runs AFTER them and only fills a field that those
% higher-priority sources left unset (empty), so a promoted value never
% overwrites an explicitly provided one. Reserved canonical names are excluded.
mtFull = pf2_base.normalizeMarkers(data.markers);
canonNames = {'Time', 'Code', 'Duration', 'Amplitude'};
extraNames = setdiff(mtFull.Properties.VariableNames, canonNames, 'stable');
if ~isempty(extraNames) && height(mtFull) > 0
    % Window used to attribute marker rows to a block. Default 'core' uses the
    % pre-pad bounds so PrePad/PostPad cannot drag a neighbour's onset marker in;
    % 'padded' uses the widened bounds to deliberately include markers that fall
    % in the pad region.
    if strcmp(markerWindow, 'padded')
        blockTimes = [blocks.startTime];
        blockEnds  = [blocks.endTime];
    else
        blockTimes = coreStart;
        blockEnds  = coreEnd;
    end
    for k = 1:length(blocks)
        % Rows belonging to this block: the triggering marker row plus any
        % rows whose Time falls within [start, end). The end is EXCLUSIVE so
        % a neighbouring block's onset marker (adjacent blocks share an
        % endpoint) is not pulled in, which would make a per-trial column
        % multi-valued and silently drop it.
        rowMask = false(height(mtFull), 1);
        mi = blocks(k).markerIndex;
        if ~isempty(mi) && isscalar(mi) && mi >= 1 && mi <= height(mtFull)
            rowMask(mi) = true;
        end
        rowMask = rowMask | (mtFull.Time >= blockTimes(k) & mtFull.Time < blockEnds(k));
        if ~any(rowMask)
            continue;
        end
        for e = 1:numel(extraNames)
            name = extraNames{e};
            % Only promote a field left unset by the explicit (higher-priority)
            % info sources above. An existing non-empty .info field wins.
            if isfield(blocks(k).info, name) && ~isempty(blocks(k).info.(name))
                continue;
            end
            vals = mtFull.(name)(rowMask, :);
            scalarVal = singleScalarValue(vals);
            if isempty(scalarVal)
                continue;  % column does not resolve to one value for this block
            end
            blocks(k).info.(name) = scalarVal{1};
        end
    end
end

% Filter by duration
if minDur > 0 || isfinite(maxDur)
    keep = arrayfun(@(b) b.duration >= minDur && b.duration <= maxDur, blocks);
    if ~isempty(keep) && ~any(keep)
        warning('pf2:defineBlocks:allBlocksFiltered', ...
            ['All %d block(s)%s fall outside MinDuration/MaxDuration ', ...
             '[%g, %g] s, so none were kept.'], numel(keep), recordingLabel(data), ...
            minDur, maxDur);
    end
    blocks = blocks(keep);
    % Re-number after filtering
    for k = 1:length(blocks)
        blocks(k).info.BlockNumber = k;
    end
end

% Embed: store blocks on data struct and return data instead
if embedBlocks
    data.blocks = blocks;
    blocks = data;
end

end

%%_Subfunctions_________________________________________________________

function val = singleScalarValue(vals)
% SINGLESCALARVALUE Resolve a block's marker-column rows to one scalar value
%
% Returns a 1x1 cell containing the single value of the column for the block,
% or empty ({}) when the column has multiple distinct values (and so cannot be
% promoted to a scalar block.info field).
%
% Inputs:
%   vals - Column slice for the block's marker rows (any type)
%
% Outputs:
%   val  - 1x1 cell with the unique value, or {} if not single-valued

val = {};
if isempty(vals)
    return;
end

% Cell columns: compare by isequal; treat [] / '' entries as missing and drop
% them so a partially-empty column still resolves to its single real value.
if iscell(vals)
    vals = vals(~cellfun(@isempty, vals));
    if isempty(vals)
        return;
    end
    if all(cellfun(@(x) isequal(x, vals{1}), vals))
        val = vals(1);
    end
    return;
end

% Non-cell columns: drop missing entries (NaN / <undefined> / <missing>)
% first, then require exactly one unique remaining value. A missing-only
% column (e.g. an all-NaN extra) does NOT promote - it returns {} so NaN
% never leaks into block.info.
try
    if size(vals, 2) == 1
        vals = vals(~ismissing(vals));
    end
catch
    % Types without a missing concept (e.g. logical) keep all rows.
end
if isempty(vals)
    return;
end
try
    u = unique(vals);
    if numel(u) == 1
        % u is already scalar here; wrap it directly. (categorical/string and
        % numeric all take the same 1x1-cell path.)
        val = {u};
    end
catch
    val = {};
end

end

function blocks = buildFromMarkerCode(mrk, markerCode, fixedDuration, useDuration)
% BUILDFROMMARKERCODE Find markers matching code and build blocks
%
% Inputs:
%   mrk           - Normalized marker array [M x 4]
%   markerCode    - Marker code(s) to match [column vector]
%   fixedDuration - Fixed block duration in seconds (0 = auto from markers)
%   useDuration   - Force use of column 3 duration
%
% Outputs:
%   blocks - Struct array of block definitions

mrkValues = mrk(:, 2);
mrkTimes = mrk(:, 1);
mrkDurations = mrk(:, 3);
mrkAmplitudes = mrk(:, 4);

% Find matching markers
matchIdx = find(ismember(mrkValues, markerCode(:)));

if isempty(matchIdx)
    blocks = struct('startTime', {}, 'endTime', {}, 'duration', {}, ...
        'markerCode', {}, 'markerIndex', {}, 'amplitude', {}, 'info', {});
    return;
end

nBlocks = length(matchIdx);
blocks = repmat(struct('startTime', 0, 'endTime', 0, 'duration', 0, ...
    'markerCode', 0, 'markerIndex', 0, 'amplitude', 1, 'info', struct()), 1, nBlocks);

for k = 1:nBlocks
    idx = matchIdx(k);
    st = mrkTimes(idx);
    code = mrkValues(idx);

    if useDuration
        % Explicitly requested: always use column 3
        dur = mrkDurations(idx);
    elseif fixedDuration > 0
        % Fixed duration provided: use it
        dur = fixedDuration;
    else
        % Auto: if marker has nonzero duration in column 3, use it
        dur = mrkDurations(idx);
    end

    blocks(k).startTime = st;
    blocks(k).endTime = st + dur;
    blocks(k).duration = dur;
    blocks(k).markerCode = code;
    blocks(k).markerIndex = idx;
    blocks(k).amplitude = mrkAmplitudes(idx);
    blocks(k).info = struct();
end

end

function blocks = buildFromStartEnd(mrk, startMarker, endMarker)
% BUILDFROMSTARTEND Pair start/end markers to build blocks
%
% Inputs:
%   mrk         - Normalized marker array [M x 4]
%   startMarker - Start marker code(s) [column vector]
%   endMarker   - End marker code(s) [column vector]
%
% Outputs:
%   blocks - Struct array of block definitions

mrkValues = mrk(:, 2);
mrkTimes = mrk(:, 1);
mrkAmplitudes = mrk(:, 4);

% Ensure column vectors
startMarker = startMarker(:);
endMarker = endMarker(:);

% If scalar endMarker, expand to match startMarker
if isscalar(endMarker) && ~isscalar(startMarker)
    endMarker = repmat(endMarker, size(startMarker));
end
if isscalar(startMarker) && ~isscalar(endMarker)
    startMarker = repmat(startMarker, size(endMarker));
end

if length(startMarker) ~= length(endMarker)
    error('pf2:defineBlocks:markerMismatch', ...
        'StartMarker and EndMarker must have the same number of elements (or one must be scalar).');
end

blockList = [];
for pidx = 1:length(startMarker)
    sCode = startMarker(pidx);
    eCode = endMarker(pidx);

    sIdx = find(mrkValues == sCode);
    eIdx = find(mrkValues == eCode);

    % Pair each start with the next available end
    for s = 1:length(sIdx)
        si = sIdx(s);
        st = mrkTimes(si);
        % Find first end marker after this start
        validEnds = eIdx(mrkTimes(eIdx) > st);
        if isempty(validEnds)
            continue;
        end
        ei = validEnds(1);
        et = mrkTimes(ei);

        entry.startTime = st;
        entry.endTime = et;
        entry.duration = et - st;
        entry.markerCode = sCode;
        entry.markerIndex = si;
        entry.amplitude = mrkAmplitudes(si);
        entry.info = struct();

        if isempty(blockList)
            blockList = entry;
        else
            blockList(end+1) = entry; %#ok<AGROW>
        end

        % Remove this end marker from available pool so it's not reused
        eIdx(eIdx == ei) = [];
    end
end

if isempty(blockList)
    blocks = struct('startTime', {}, 'endTime', {}, 'duration', {}, ...
        'markerCode', {}, 'markerIndex', {}, 'amplitude', {}, 'info', {});
else
    blocks = blockList;
end

end

function found = warnIfCodesMissing(mrk, codes, kind, data)
% WARNIFCODESMISSING Warn when none of the requested codes occur in the markers
%
% Inputs:
%   mrk   - Marker array [M x 4] (Time, Code, Duration, Amplitude)
%   codes - Requested codes (column vector)
%   kind  - Word used in the message ('marker' or 'end marker')
%   data  - fNIRS struct, used to name the recording
%
% Outputs:
%   found - True when at least one requested code occurs

found = true;
if isempty(codes)
    return;
end
present = unique(mrk(:, 2));
found = any(ismember(codes, present));
if found
    return;
end
msg = sprintf('None of the requested %s codes (%s) occur in data.markers%s. Codes present: %s.', ...
    kind, codeList(codes), recordingLabel(data), codeList(present));
finitePresent = present(isfinite(present));
if ~isempty(finitePresent) && any(finitePresent ~= round(finitePresent))
    msg = [msg ' The codes present are not all integers, which usually means the ' ...
        'marker columns are out of order: data.markers should be a table with Time, ' ...
        'Code, Duration and Amplitude columns (see pf2_base.normalizeMarkers).'];
end
warning('pf2:defineBlocks:codesNotFound', '%s', msg);
end

function s = codeList(codes)
% CODELIST Short text list of codes for messages (first 10 shown)
%
% Inputs:
%   codes - Numeric vector
%
% Outputs:
%   s - e.g. '49, 50' or '1, 2, 3, ... (25 codes)'

codes = codes(:)';
if isempty(codes)
    s = 'none';
    return;
end
shown = codes(1:min(10, end));
s = strjoin(arrayfun(@(c) sprintf('%g', c), shown, 'UniformOutput', false), ', ');
if numel(codes) > 10
    s = sprintf('%s, ... (%d codes)', s, numel(codes));
end
end

function s = recordingLabel(data)
% RECORDINGLABEL ' for <name>' from info.filename (file name only) or
% info.SubjectID, else ''
%
% Inputs:
%   data - fNIRS struct
%
% Outputs:
%   s - Text to splice into messages so batch warnings name the recording

s = '';
if ~isfield(data, 'info') || ~isstruct(data.info)
    return;
end
for f = {'filename', 'SubjectID'}
    if isfield(data.info, f{1}) && ~isempty(data.info.(f{1}))
        v = data.info.(f{1});
        if isnumeric(v)
            v = num2str(v);
        end
        v = char(string(v));
        if strcmp(f{1}, 'filename')
            [~, name, ext] = fileparts(v);
            v = [name ext];
        end
        s = sprintf(' for %s', v);
        return;
    end
end
end
