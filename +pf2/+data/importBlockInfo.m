function blocks = importBlockInfo(blocks, source, varargin)
% IMPORTBLOCKINFO Import block-level metadata into block structs
%
% Attaches per-block metadata to a block struct array (from defineBlocks).
% The metadata source can be a CSV/Excel file path, an in-memory MATLAB
% table, or a numeric vector (one value per block). File and table sources
% support positional matching (row order) and key-based matching; filtering
% by MarkerCode or Condition restricts which blocks receive metadata, and
% non-matching blocks pass through unchanged.
%
% Most users already have their per-block factor (e.g. a behavioral score or
% condition label) in memory, so passing a table or numeric vector avoids a
% round-trip through disk. A table behaves identically to a just-read CSV.
%
% Syntax:
%   blocks = pf2.data.importBlockInfo(blocks, filepath)
%   blocks = pf2.data.importBlockInfo(blocks, tbl)
%   blocks = pf2.data.importBlockInfo(blocks, vec, 'Field', 'score')
%   blocks = pf2.data.importBlockInfo(blocks, source, 'MarkerCode', 49)
%   blocks = pf2.data.importBlockInfo(blocks, source, 'Keys', keyCol)
%   blocks = pf2.data.importBlockInfo(blocks, source, ..., 'Name', Value)
%
% Inputs:
%   blocks - Struct array from pf2.data.defineBlocks [1 x N struct]
%            Each element has .markerCode, .info (with .BlockNumber, etc.)
%   source - Metadata source, one of:
%              * Path to a CSV (.csv) or Excel (.xlsx, .xls) file
%                [char|string]. Read via readtable, then treated as a table.
%              * MATLAB table. Columns are merged into block .info using the
%                same key/positional semantics as a just-read CSV.
%              * Numeric vector/column [N x 1] or [1 x N]. One value per
%                block, assigned to the field named by 'Field' (default
%                'value'). Its length must match the number of (filtered)
%                blocks.
%
% Name-Value Parameters:
%   'Field'       - Target .info field name for a numeric vector source
%                   (default: 'value'). Ignored for file/table sources.
%   'Keys'        - Column name(s) for key-based matching [char|string|cellstr]
%                   When specified, uses exact-match semantics (like importInfo).
%                   When omitted, uses positional matching (row order).
%                   Applies to file/table sources only.
%   'MarkerCode'  - Filter: only apply to blocks with this marker code [numeric]
%   'Condition'   - Filter: only apply to blocks with this condition label [char|string]
%   'Sheet'       - Sheet name or index for Excel files (default: 1)
%   'Overwrite'   - Overwrite existing .info fields (default: true)
%   'ReadOptions' - Cell array of extra arguments passed to readtable (default: {})
%
% Outputs:
%   blocks - Same struct array with .info fields updated on matched blocks.
%            Non-matching blocks (filtered out) are returned unchanged.
%
% Algorithm:
%   1. Classify the source (file path -> readtable -> table; table; or
%      numeric vector). Numeric vectors assign one value per filtered block.
%   2. Apply MarkerCode/Condition filter to identify target blocks
%   3a. Positional mode: verify row count == filtered block count, then
%       assign row k to k-th filtered block
%   3b. Key mode: for each filtered block, find matching row (error on 0 or >1)
%   4. Copy columns into block .info (respecting Overwrite setting)
%   5. Warn if any source rows were not matched
%
% Example:
%   % Positional: row 1 -> block 1, row 2 -> block 2
%   blocks = pf2.data.importBlockInfo(blocks, 'trial_data.csv');
%
%   % Only apply to Task blocks (marker 49), skip Rest (marker 50)
%   blocks = pf2.data.importBlockInfo(blocks, 'trial_data.csv', ...
%       'MarkerCode', 49);
%
%   % Filter by condition label
%   blocks = pf2.data.importBlockInfo(blocks, 'trial_data.csv', ...
%       'Condition', 'Task');
%
%   % Key-based matching
%   blocks = pf2.data.importBlockInfo(blocks, 'trial_data.csv', ...
%       'Keys', 'BlockNumber');
%
%   % In-memory table (behaves like a just-read CSV)
%   T = table([85; 90]', 'VariableNames', {'Score'});
%   blocks = pf2.data.importBlockInfo(blocks, T);
%
%   % Numeric per-block vector -> named .info field
%   data    = pf2.import.sampleData.fNIR2000();
%   proc    = processFNIRS2(data);
%   blocks  = pf2.data.defineBlocks(proc, [1 2], 20, 'Embed', false);
%   scores  = (1:numel(blocks))';
%   blocks  = pf2.data.importBlockInfo(blocks, scores, 'Field', 'score');
%   blocks(1).info.score   % -> 1
%
% See also: pf2.data.importInfo, pf2.data.defineBlocks, pf2.data.extractBlocks

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
opts = pf2_base.args.parse('importBlockInfo', varargin, {}, {
    'Field',       (''), '', '', {}
    'Keys',        ({}), '', '', {}
    'MarkerCode',  ([]), '', '', {@mustBeNumeric}
    'Condition',   (''), '', '', {}
    'Sheet',       (1), '', '', {}
    'Overwrite',   (true), '1,1', 'logical', {}
    'ReadOptions', ({}), '', '', {@(v) mustBeA(v, 'cell')}
    });

keys = cellstr(opts.Keys);
if numel(keys) == 1 && isempty(keys{1})
    keys = {};
end
fieldName = char(opts.Field);
markerFilter = opts.MarkerCode;
condFilter = string(opts.Condition);
sheet = opts.Sheet;
overwrite = opts.Overwrite;
readOpts = opts.ReadOptions;

useKeyMode = ~isempty(keys);

% --- Resolve the source into a table (file/table) or numeric vector ---
isNumericSource = false;
numericVals = [];

if ischar(source) || (isstring(source) && isscalar(source))
    % File path -> read into a table
    filepath = char(source);
    if ~isfile(filepath)
        error('pf2:data:importBlockInfo:fileNotFound', ...
            'File not found: %s', filepath);
    end
    readArgs = readOpts;
    [~, ~, ext] = fileparts(filepath);
    if any(strcmpi(ext, {'.xlsx', '.xls'}))
        readArgs = [readArgs, {'Sheet', sheet}];
    end
    tbl = readtable(filepath, readArgs{:});
elseif istable(source)
    % In-memory table -> identical handling to a just-read CSV
    tbl = source;
elseif isnumeric(source) && isvector(source)
    % Per-block numeric vector
    isNumericSource = true;
    numericVals = source(:);
else
    error('pf2:data:importBlockInfo:badSource', ...
        ['Unsupported metadata source. Provide one of: a CSV/XLSX file ', ...
         'path (char/string), a MATLAB table, or a per-block numeric ', ...
         'vector (with the ''Field'' option naming the target .info field).']);
end

if ~isNumericSource
    colNames = tbl.Properties.VariableNames;
end

if ~isNumericSource
    % Validate key columns exist in source
    if useKeyMode
        for k = 1:numel(keys)
            if ~any(strcmp(colNames, keys{k}))
                error('pf2:data:importBlockInfo:keyNotInFile', ...
                    'Key column ''%s'' not found in source. Available columns: %s', ...
                    keys{k}, strjoin(colNames, ', '));
            end
        end
    end

    % Determine columns to copy (all if positional, non-key if key mode)
    if useKeyMode
        copyCols = colNames(~ismember(colNames, keys));
    else
        copyCols = colNames;
    end
end

% Apply filter to find target block indices
nBlocks = numel(blocks);
filterMask = true(1, nBlocks);

if ~isempty(markerFilter)
    for b = 1:nBlocks
        filterMask(b) = filterMask(b) && ismember(blocks(b).markerCode, markerFilter);
    end
end

if strlength(condFilter) > 0
    for b = 1:nBlocks
        if isfield(blocks(b).info, 'Condition')
            filterMask(b) = filterMask(b) && string(blocks(b).info.Condition) == condFilter;
        else
            filterMask(b) = false;
        end
    end
end

targetIdx = find(filterMask);
nTargets = numel(targetIdx);

if isNumericSource
    % --- Per-block numeric vector ---
    if isempty(fieldName)
        fieldName = 'value';
        noteOnce('pf2:data:importBlockInfo:defaultField', ...
            ['importBlockInfo: ''Field'' not specified for a numeric ', ...
             'source; storing values in block .info.value.']);
    end

    if numel(numericVals) ~= nTargets
        error('pf2:data:importBlockInfo:lengthMismatch', ...
            ['Numeric vector length (%d) does not match the number of ', ...
             '%sblocks (%d).'], numel(numericVals), ...
            filterDescription(markerFilter, condFilter), nTargets);
    end

    for t = 1:nTargets
        bidx = targetIdx(t);
        if ~overwrite && isfield(blocks(bidx).info, fieldName)
            continue;
        end
        blocks(bidx).info.(fieldName) = numericVals(t);
    end

    return;
end

if useKeyMode
    % --- Key-based matching ---
    rowUsed = false(height(tbl), 1);

    for t = 1:nTargets
        bidx = targetIdx(t);
        blk = blocks(bidx);

        matchMask = true(height(tbl), 1);
        keyVals = cell(1, numel(keys));

        for k = 1:numel(keys)
            keyName = keys{k};

            % Look for key in block .info first, then top-level block fields
            if isfield(blk.info, keyName)
                infoVal = blk.info.(keyName);
            elseif isfield(blk, keyName)
                infoVal = blk.(keyName);
            else
                error('pf2:data:importBlockInfo:keyNotInBlock', ...
                    'Key field ''%s'' not found in block %d .info or block fields.', ...
                    keyName, bidx);
            end

            tblCol = tbl.(keyName);
            keyVals{k} = infoVal;

            if isnumeric(infoVal)
                if isnumeric(tblCol)
                    matchMask = matchMask & (tblCol == infoVal);
                else
                    matchMask = matchMask & (double(string(tblCol)) == infoVal);
                end
            else
                matchMask = matchMask & (string(tblCol) == string(infoVal));
            end
        end

        matchRows = find(matchMask);

        if isempty(matchRows)
            keyStr = strjoin(cellfun(@(k,v) sprintf('%s=%s', k, string(v)), ...
                keys, keyVals, 'UniformOutput', false), ', ');
            error('pf2:data:importBlockInfo:noMatch', ...
                'No rows match block %d (%s).', bidx, keyStr);
        end

        if numel(matchRows) > 1
            keyStr = strjoin(cellfun(@(k,v) sprintf('%s=%s', k, string(v)), ...
                keys, keyVals, 'UniformOutput', false), ', ');
            error('pf2:data:importBlockInfo:ambiguousMatch', ...
                'Multiple rows (%d) match block %d (%s).', numel(matchRows), bidx, keyStr);
        end

        rowUsed(matchRows) = true;
        blocks(bidx) = applyRow(blocks(bidx), tbl, matchRows, copyCols, overwrite);
    end

    % Warn about unused rows
    if any(~rowUsed)
        warning('pf2:data:importBlockInfo:unusedRows', ...
            '%d source row(s) not matched to any block.', sum(~rowUsed));
    end

else
    % --- Positional matching ---
    nRows = height(tbl);

    if nRows ~= nTargets
        error('pf2:data:importBlockInfo:rowCountMismatch', ...
            'Row count (%d) does not match filtered block count (%d).', nRows, nTargets);
    end

    for t = 1:nTargets
        bidx = targetIdx(t);
        blocks(bidx) = applyRow(blocks(bidx), tbl, t, copyCols, overwrite);
    end
end

end

%%_Subfunctions_________________________________________________________

function noteOnce(id, msg)
% NOTEONCE Emit an informational note at most once per MATLAB session
%
% Used to notify the user of a defaulted option without spamming repeated
% calls (e.g. inside a batch loop).
%
% Inputs:
%   id  - Unique identifier string for this note
%   msg - Message text to display
%
% Outputs:
%   (none)

persistent seen
if isempty(seen)
    seen = {};
end
if ~any(strcmp(seen, id))
    seen{end+1} = id; %#ok<AGROW>
    fprintf('%s\n', msg);
end

end

function desc = filterDescription(markerFilter, condFilter)
% FILTERDESCRIPTION Build a human-readable prefix describing active filters
%
% Inputs:
%   markerFilter - MarkerCode filter value(s) or [] [numeric]
%   condFilter   - Condition filter label or "" [string]
%
% Outputs:
%   desc - Prefix string such as 'filtered (MarkerCode=49) ' or '' when no
%          filter is active. Trailing space included for sentence assembly.

parts = {};
if ~isempty(markerFilter)
    parts{end+1} = sprintf('MarkerCode=%s', mat2str(markerFilter)); %#ok<AGROW>
end
if strlength(condFilter) > 0
    parts{end+1} = sprintf('Condition=%s', condFilter); %#ok<AGROW>
end
if isempty(parts)
    desc = '';
else
    desc = sprintf('filtered (%s) ', strjoin(parts, ', '));
end

end

function blk = applyRow(blk, tbl, rowIdx, copyCols, overwrite)
% APPLYROW Copy table row columns into block .info
%
% Inputs:
%   blk      - Single block struct
%   tbl      - Table read from file
%   rowIdx   - Row index to copy from
%   copyCols - Cell array of column names to copy
%   overwrite - Whether to overwrite existing fields

for c = 1:numel(copyCols)
    colName = copyCols{c};
    if ~overwrite && isfield(blk.info, colName)
        continue;
    end
    val = tbl.(colName)(rowIdx);
    if iscell(val)
        blk.info.(colName) = val{1};
    elseif iscategorical(val)
        blk.info.(colName) = char(val);
    else
        blk.info.(colName) = val;
    end
end

end
